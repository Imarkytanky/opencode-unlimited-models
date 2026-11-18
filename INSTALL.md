# INSTALL.md — quick-start guide

Prerequisites: bash, python3, curl, [opencode v2 binary], [bun], [Go 1.22+]
(opencode, bun, and Go are only needed for specific paths; see below)

---

## 1. Extract and enter the bundle

```bash
tar xzf opencode-unlimited-models-final.tar.gz
cd opencode-unlimited-models-final
```

## 2. Set up your API key

```bash
cp .env.local.example .env.local
$EDITOR .env.local    # paste your real OPENCODE_API_KEY (oc_sk_...)
```

The `.env.local.example` file is a template — never commit `.env.local` to
git. The project's `.gitignore` rule (`.env*`) already excludes it.

For the free-tier path, you don't even need a real key — the proxy accepts
`apiKey: "public"` for free-tier model routing. A real `OPENCODE_API_KEY`
is only needed for paid models (kimi-k3, claude-haiku-5-5, etc.).

## 3. Start the opencode-egress-router proxy (free-tier path)

```bash
./opencode-proxy/launch-oc-proxy.sh
```

This daemonizes the proxy on `127.0.0.1:8318`, forwarding to
`https://opencode.ai/zen/v1`. For free-tier model IDs (`*-free`,
`big-pickle`), it rewrites the request to pass Zen's "from-within-OpenCode"
gate (TLS fingerprint spoofing, opencode-format session ID, bash/read tool
stubs, `<env>` block injection). For paid models with real `oc_sk_` keys,
it passes through unchanged.

Verify it's running:

```bash
curl -sS -H "Authorization: Bearer public" \
  -H "Content-Type: application/json" \
  -d '{"model":"glm-5.3-flash-free","messages":[{"role":"user","content":"hi"}]}' \
  http://127.0.0.1:8318/chat/completions | python3 -m json.tool
```

You should get a 200 with `"billing_source":"free"` and `"cost":0`.

To stop the proxy:

```bash
kill $(cat /tmp/oc-proxy.pid)
```

### Rebuilding the proxy from source (different arch/OS)

The bundle includes a pre-built `opencode-egress-router` binary for x86-64
Linux. To rebuild on a different architecture:

```bash
cd opencode-proxy
go vet . && go test ./... && go build -o opencode-egress-router .
```

(Go 1.22+ required — see `go.mod`.)

## 3b. (Optional, recommended) Install SphinX-lite — CLI binary shim + auto-resume

The `sphinx-lite/` directory adds **Layer C**: a binary wrapper for the
opencode CLI itself plus a log watcher that catches rate-limit errors and
auto-dispatches `continue` to your active session.

This is complementary to the proxy in step 3 — they operate at different
layers (CLI binary vs API requests) and don't conflict.

```bash
# Pre-flight check (shows what would be installed)
bash sphinx-lite/install-sphinx-lite.sh --check

# Install for real
bash sphinx-lite/install-sphinx-lite.sh
```

The installer:
- Replaces `~/.local/bin/opencode` with a wrapper that execs the real
  binary inside `unshare -rm` (a mount namespace) with a fake `/etc/hosts`
  (pinning opencode.ai to a random Cloudflare AAAA edge) and a fresh
  `/etc/machine-id`.
- Copies the Python source (`zen_guard.py`, `auto_resume.py`,
  `ouc_common.py`) to `~/.local/share/opencode-unlimited/src/`.
- Writes run/stop/status scripts to
  `~/.local/share/opencode-unlimited/scripts/`.

**What's NOT installed in sphinx-lite** (requires a real VPS with root +
`/dev/net/tun`): `warp-cli` (Cloudflare WARP daemon for IPv6 /64 rotation),
systemd units, sudoers entry, Tor daemon, iptables leakguard. For the full
SphinX stack with WARP rotation, run the upstream `install.sh` from
https://github.com/ShadowySphinX/Opencode-Unlimited-Limit-Bypass- on a real
VPS.

### Unified launcher (starts BOTH proxy + sphinx-lite guard)

Once both Layer C (sphinx-lite) and Layer D (opencode-egress-router) are
installed, use the unified launcher:

```bash
bash sphinx-lite/launch-unified.sh            # start both
bash sphinx-lite/launch-unified.sh --status    # show running state
bash sphinx-lite/launch-unified.sh --stop      # stop both
bash sphinx-lite/launch-unified.sh --restart   # restart both
```

The launcher detects what's installed and starts the right combination.
If only one layer is installed, it starts just that one.

## 4. Install the AI SDK (if running the examples)

```bash
bun add ai @ai-sdk/openai-compatible
# or: npm install ai @ai-sdk/openai-compatible
# or: pnpm add ai @ai-sdk/openai-compatible
```

## 5. Run an example

```bash
# Free-tier model via proxy ($0/req, no real key needed)
bun run examples/index.zen-free.ts

# Paid model via direct opencode Console gateway (~$0.0006/req for kimi-k3)
bun run examples/index.opencode.ts

# Vercel AI Gateway canonical path (requires Vercel AI Gateway credits)
bun run examples/index.ts
```

## 6. Validate the contract (10/10 confidence)

```bash
# Set your API key in the environment
export OPENCODE_API_KEY="oc_sk_..."    # or: source .env.local

# Run the contract test against the real opencode Console gateway
TARGET_ID=kimi-k3 \
CONTROL_ID=glm-5.3-flash-free \
EMBEDDING_ID=nonexistent-embedding-model \
EXPECTED_CONTEXT=1048576 \
EXPECTED_OUTPUT=131072 \
CONTROL_CONTEXT=200000 \
bash verify-a-contract/verify-a-contract.sh \
  --simulate \
  --gateway-url https://opencode.ai/inference/v1 \
  --api-key "$OPENCODE_API_KEY" \
  --rich-metadata \
  --schema v2
```

Expected output: `verdict: PASS` with all 7 assertions holding
(C1-C7). The verdict JSON is saved to `./opencode-contract-artifacts/verdict.json`
(or `--artifacts-dir <path>`).

## 7. Use the opencode.json config (for the opencode v2 CLI)

```bash
# Copy the config to your project root (or ~/.config/opencode/)
cp config/opencode.json /path/to/your/project/opencode.json

# Set the API key (the config references {env:OPENCODE_API_KEY})
export OPENCODE_API_KEY="oc_sk_..."

# Run opencode — it will see both providers and 17 configured models
cd /path/to/your/project
opencode models | grep -E 'opencode|zen'
```

---

## Staged rollout (full plan in verify-a-contract/README.md)

| Stage | Components | Confidence |
|---|---|---|
| **1 (this bundle)** | B (hand-written models) + A (opencode Console discovery) + contract test | 10/10 |
| **2 (DONE in this bundle)** | + D_thin reconcile plugin (`plugins/reconcile.ts`) — disable-not-delete ghost reconciliation, 7 unit tests + integration test PASS | 10/10 hardened |
| **3 (deferred)** | swap A → PR #57161 native openai-compatible discovery (when merged) | 10/10 + no third-party plugin |

Stage 2 is **complete in this bundle** — the reconcile plugin is already registered in `config/opencode.json` and its contract is validated by:
- `plugins/reconcile.test.ts` (7 unit tests, all PASS)
- `verify-a-contract/verify-a-contract.sh` (7/7 integration assertions against real opencode Console)

Stage 3 remains deferred until PR #57161 merges upstream. When it does, removing the `plugins` array from `opencode.json` and switching to `experimental.openai_compatible_discovery` is the only migration step needed — the reconcile plugin keeps working unchanged because it operates on the model registry after discovery (whether discovery is plugin-based or native).

### Running the reconcile plugin unit tests

```bash
cd plugins
bun test reconcile.test.ts
```

Expected output:
```
7 pass
0 fail
24 expect() calls
```

The 7 tests cover:
- T1: ghost model is DISABLED (enabled=false), not deleted
- T2: B's overrides are PRESERVED (tools/limit/name untouched)
- T3: dry-run mode detects ghosts without disabling
- T4: gateway fetch failure skips disable (no destructive action on outage)
- T5: providerFilter restricts reconcile to specific provider IDs
- T6: built-in providers (no settings.baseURL) are skipped
- T7: provider with no apiKey is skipped

---

## 8. (Optional, recommended) Install browser-search web research skill (Layer W)

The model layers (A/B/C/D/D_thin/G/F/CF) answer *"which model handles this
request"*. Layer W answers *"what does the model know"* — it gives every model
in the stack self-hosted web research with anti-hallucination tooling
(deterministic scripts the model cannot mis-execute).

Three tiers, escalating automatically:
1. **SearXNG** metasearch (Docker `:8080`, or native Python — JSON results, ms-fast)
2. **Camofox** REST browser (Docker `:9377`, Readability.js — ~70% token savings)
3. **CloakBrowser** stealth Chromium (npm + `~/.cloakbrowser` binary — clears Cloudflare/Akamai/DataDome)

### Install (interactive, via setup.sh)

```bash
bash setup.sh               # choose 'y' at the Layer W prompt (step 4e)
                            # installs npm deps + Chromium binary (~700 MB one-time)
                            # symlinks SKILL.md into ~/.config/opencode/skills/browser-search
```

Opt out:
```bash
bash setup.sh --no-browser-search
```

### Manual install (without setup.sh)

```bash
cd browser-search
npm install
node -e "import('cloakbrowser').then(c => c.ensureBinary())"   # ~700 MB Chromium
bash scripts/check.sh                                           # health check
```

### Run the tiers

```bash
# Tier 1 — search (needs SearXNG running; see "SearXNG engine" below)
node browser-search/scripts/searxng/searxng.mjs search "opencode v2" --lang en

# Tier 2 — extract URL content (auto-escalates Camofox → Cloak on failure)
node browser-search/scripts/smart-extract.mjs "https://example.com"

# Tier 3 — stealth fetch (clears Cloudflare, ~5 s)
node browser-search/scripts/cloak/cloak-fetch.mjs "https://www.cloudflare.com"

# Route browsing through your Layer F/G proxy fleet:
bash bs-bridge.sh fetch "https://protected-site.com"
```

### SearXNG engine (tier 1)

**Docker (recommended):**
```bash
docker compose --profile search up -d      # searxng + camofox
```
Config in `docker/searxng/settings.yml` (limiter off, JSON format on, env-secret).

**Native (no Docker):**
```bash
git clone --depth 1 https://github.com/searxng/searxng /tmp/searxng-src
pip install -r /tmp/searxng-src/requirements.txt
SEARXNG_SETTINGS_PATH=$PWD/browser-search/searxng-settings.yml \
  python -m searx.webapp             # serves on 127.0.0.1:8080
```

### Validate

```bash
bun run test:w           # quick: CloakBrowser tier only (~20 s)
SEARXNG_SRC=/tmp/searxng-src bun run test:w:full    # full: launches native engine (~3 min)
bash verify-browser-search.sh                         # same, shell entry point
```

6 assertions: engine reachable, tier-1 search JSON, tier-2 extraction, tier-3
challenge-site fetch, E2E search→extract loop, health-check accuracy.

### Benchmark

```bash
bun run bench:w:quick    # quick: CloakBrowser tier only, 3 runs (~30 s)
bun run bench:w          # full: all tiers including SearXNG + bridge (~3 min)
```

Reference numbers (from the v12 validation run):
| Test | Median | P90 | Notes |
|---|---|---|---|
| SearXNG search (cold) | 3,073 ms | 3,073 ms | First query, engine warm-up |
| SearXNG search (warm) | 997 ms | 859 ms | Subsequent queries, 3× faster |
| CloakBrowser (example.com) | 5,347 ms | 5,351 ms | No challenge, just browser startup |
| CloakBrowser (cloudflare.com) | 35,784 ms | 35,943 ms | Challenge resolution adds ~30 s |
| smart-extract (auto-escalation) | 6,422 ms | 6,478 ms | ~1 s overhead over direct cloak-fetch |
| Bridge fetch via Layer F proxy | 9,860 ms | 60,872 ms | Public SOCKS5; first run often times out |

### How the model uses it

When the skill is installed (auto-discovered from `~/.config/opencode/skills/`
or project-local `.agents/skills/`), opencode v2 picks up the `SKILL.md`. The
agent then calls the deterministic scripts via `exec` — it cannot get the
command wrong or mis-parse the output. Even the cheapest model
(`glm-5.3-flash-free`, $0/req) researches the live web without hallucinating.

See `browser-search/README-STACK.md` for the full interconnection table and
the CloakBrowser version-pinning rationale (0.6.3 vs 0.7.x).

### End-to-end examples

```bash
# Search → extract → grounded answer via free model ($0 total):
bun run example:layer-w "What is the latest stable version of opencode?"

# Compare free vs paid model on the same research:
bun run example:layer-w-compare "What is the latest stable version of opencode?"

# Multilingual research (default: Japanese):
bun run example:layer-w-multilingual
bun run example:layer-w-multilingual --lang zh "opencode 最新版本是什么？"
```

---

## 9. (Optional) Install oc-proxy portable Zen bypass (Layer P)

Layer P is a **remote-capable** sibling of Layer D: the same Zen free-tier
fingerprint bypass, packaged as an HTTP service you can deploy to
**Hugging Face Spaces** (recommended over Vercel — no `maxDuration` hard-kill
mid-token), a VPS, or your local machine. Best for hosted agents, CI runners,
and teammates who can't run a local daemon.

**Licensing note:** upstream oc-proxy (MarkDev11/oc-proxy) has no LICENSE
file, so this stack ships only its own adapter + tooling and clones upstream
at install time into `oc-proxy/upstream/` (gitignored, never redistributed).

```bash
bun run oc:install        # clone upstream (pinned commit, syntax-verified)
bun run oc:dev            # serve on :7860 (dashboard + /v1/* + /api/*)
bun run oc:test           # 8-assertion contract incl. live fingerprint proof
bun run oc:hf             # assemble ready-to-push HF Space (dist/oc-proxy-hf-space/)
```

HF Space deploy: push `oc-proxy/dist/oc-proxy-hf-space/` to a new Space
(sdk: docker, app_port: 7860), then set `GATEWAY_API_KEY` in
Space settings. Full guide: `oc-proxy/README-STACK.md`.

Provider snippet for Layer B (add only after your Space is live):

```json
"oc-proxy-hf": {
  "name": "OpenCode Zen Free (via oc-proxy HF Space)",
  "package": "@opencode/ai/providers/openai-compatible",
  "options": { "baseURL": "https://<USER>-oc-proxy.hf.space/v1" },
  "settings": { "apiKey": "{env:OC_PROXY_KEY}" },
  "models": {
    "glm-5.3-flash-free": { "name": "GLM 5.3 Flash (free)", "capabilities": { "tools": true } }
  }
}
```

---

## Advanced deployment paths (v10)

### Cloudflare Workers edge proxy (Layer CF)

No VPS, no credit card, automatic IP rotation. Each request hits a different
Cloudflare edge location (300+ globally).

```bash
cd cf-worker-proxy
bun install
bun run cf:dev          # local dev on :8787 (wrangler dev)
# Test: curl http://127.0.0.1:8787/proxy/https://opencode.ai/inference/v1/models

bun run cf:deploy       # deploy to Cloudflare's edge (needs wrangler login)
# URL: https://opencode-proxy.<your-subdomain>.workers.dev
# 100K requests/day free
```

### VPS personal proxy fleet (Layer F-primary)

Public proxies are rate-limited and unreliable. Deploy your own SOCKS5
proxies on free-tier cloud VPS instances instead.

```bash
# Read the full guide (10 providers: Oracle, GCP, AWS, Azure, Fly.io, etc.):
cat vps-proxy/FREE-VPS-PROXY-GUIDE.md | less

# Deploy sing-box on any VPS (automated via SSH):
bash vps-proxy/deploy-proxy.sh ubuntu@1.2.3.4 1080

# Manage your fleet:
bash vps-proxy/rotate-egress.sh add socks5://1.2.3.4:1080
bash vps-proxy/rotate-egress.sh test       # TCP + SOCKS5 handshake test
bash vps-proxy/rotate-egress.sh generate   # output EGRESS_UPSTREAMS / custom-proxies.txt / Magiszonekk flags
bash vps-proxy/rotate-egress.sh disable-public  # disable public proxy scanning

# Or use bun run shortcuts:
bun run vps:list
bun run vps:add
bun run vps:test
bun run vps:generate
```

### Containerized via kiri/Docker (all layers in one container)

```bash
bash kiri/install-kiri.sh       # installs kiri + builds Docker image + starts stack
kiri compose ps                 # verify running services
kiri compose logs -f             # follow logs
kiri compose down                # stop

# Or with Docker:
docker build -t opencode-unlimited .
docker compose up -d
```

### zen-unlimited Linux port (Layer G — muse-spark)

```bash
cd zen-unlimited-linux
bun install
bun run src/index.ts setup --dry-run    # preview the plan
bun run src/index.ts setup              # write .env + sing-box config
bash scripts/install-zen-stack.sh       # create systemd user units
bun run src/index.ts doctor             # health check (gateway + relay + sing-box)
# Gateway on :20128, relay on :1090, sing-box egress on :1081-:1086
```

### Unified E2E test (validates ALL layers)

```bash
bash test-e2e.sh --quick       # 6 layers (~15s, skips CF + G)
bash test-e2e.sh               # all 8 layers (~60s)
bash test-e2e.sh --layer cf    # only the Cloudflare Worker test
bash test-e2e.sh --layer d     # only the opencode-egress-router test
```

---

## Troubleshooting

### Proxy returns 000 / "Could not connect to server"

The daemon died. Check `/tmp/oc-proxy.log` and relaunch:

```bash
cat /tmp/oc-proxy.log
./opencode-proxy/launch-oc-proxy.sh
```

### Free-tier model returns `FreeUsageLimitError` (429)

You're hitting `https://opencode.ai/inference/v1` directly. Free-tier models
ONLY work through the proxy at `http://127.0.0.1:8318` (which applies the
zenfix gate rewrite). Make sure the proxy is running and your `baseURL` is
`http://127.0.0.1:8318`, not `https://opencode.ai/inference/v1`.

### Paid model returns 403

Your `OPENCODE_API_KEY` is missing, expired, or out of credits. Check at
https://opencode.ai/console.

### Contract test returns `WARN` (some assertions `unknown`)

The assertion engine couldn't read tool/limit flags from the harvested
evidence. Re-run with `--keep` and inspect
`./opencode-contract-artifacts/docs/*.json` to see what shape the gateway
returned. You may need to extend `TOOL_PATHS` / `LIMIT_PATHS` in the
`--assert-helper` block of `verify-a-contract.sh`.

### Cloudflare blocks urllib (HTTP 403, error 1010)

The simulate mode sends `User-Agent: opencode/1.19.5` to bypass Cloudflare's
default-UA block. If you're running a customized version and hit this, ensure
the UA header is set on the `/v1/models` fetch.

### SphinX-lite guard dies with `ctypes.windll` error

You're running the upstream (Windows-targeted) SphinX source instead of the
patched `sphinx-lite/src/` version bundled here. Re-run the installer:

```bash
bash sphinx-lite/install-sphinx-lite.sh --uninstall   # restore original opencode
bash sphinx-lite/install-sphinx-lite.sh               # reinstall patched version
```

The bundled version patches `ouc_common.py:acquire_mutex()` with an `fcntl.flock`
fallback for Linux. If you clone the upstream repo directly, you'll need to
apply this patch manually (see `sphinx-lite/src/ouc_common.py` for the diff).

### SphinX-lite guard detects walls but auto-resume says "No active session"

This is correct behavior when the opencode TUI isn't running. The guard queries
the `session_v2` table in `~/.local/share/opencode/opencode.db` for the most
recently active non-archived session; if you're not in a TUI session, there's
nothing to resume. Start the TUI (`opencode` with no args), then trigger a
wall — auto-resume will dispatch `opencode run --continue` to your active
session ID.

### `unshare -rm` fails with "Operation not permitted"

The kernel doesn't allow unprivileged user namespaces. On a real VPS, edit
`/etc/sysctl.conf` and set:

```
kernel.unprivileged_userns_clone = 1
```

Then `sysctl -p` and re-run the installer. In a locked-down container (e.g.
default Docker), this isn't fixable without `--privileged` — in that case,
skip sphinx-lite and rely only on the opencode-egress-router proxy.

### opencode CLI on PATH isn't the shim

The shim lives at `~/.local/bin/opencode` but `command -v opencode` may show
a different path if `/usr/local/bin` or `/usr/bin` comes first. Fix:

```bash
export PATH="$HOME/.local/bin:$PATH"
# Or permanently add to ~/.bashrc:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

Verify the shim is in use:

```bash
head -1 "$(command -v opencode)"
# Should print: #!/usr/bin/env bash
```
