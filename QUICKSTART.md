# QUICKSTART — 60-second path to a working setup

> For the full reference (troubleshooting, rebuilds, architecture, staged
> rollout), see [INSTALL.md](./INSTALL.md) and [README.md](./README.md).
> For version history, see [CHANGELOG.md](./CHANGELOG.md).

## Prerequisites

- **Linux x86-64** (the opencode-egress-router binary is pre-built for this arch)
- **Bun** ≥1.3 — install via `curl -fsSL https://bun.sh/install | bash`
- **Python 3.10+** (for the contract test + proxy-hunter + sphinx-lite)
- **Node.js** ≥20.19 (for Layer W / CloakBrowser)
- **curl** (for the smoke test)
- An **`oc_sk_` key** from https://opencode.ai/console (required for paid
  models; free-tier uses `apiKey: "public"` and needs no key)

## 5 commands

```bash
# 1. Extract + install dependencies
tar xzf v12-unified-stack.tar.gz
cd opencode-unlimited-models-final
bun install

# 2. Set your API key
cp .env.local.example .env.local
$EDITOR .env.local    # paste your oc_sk_... key

# 3. One-shot setup (installs proxy + optionally sphinx-lite + Layer W, runs contract test)
bash setup.sh --no-sphinx      # ~30 seconds, ends with 9/9 contract PASS

# 4. Run an example — get text back
bun run examples/index.zen-free.ts        # free-tier Zen, $0/req
bun run examples/index.opencode.ts        # paid (kimi-k3), ~$0.0006/req
bun run examples/index.layer-w.ts "What is the latest opencode version?"  # Layer W research, $0

# 5. Validate the entire stack
bun run test:e2e --quick                 # 7/7 layers, ~15 seconds
```

## E2E test (9 layers validated)

```bash
# Quick mode (~15s): skips Cloudflare Worker + zen-unlimited gateway
bun run test:e2e --quick

# Full mode (~60s): all 9 layers (B, A, D, D_thin, G, F, CF, W, contract)
bash test-e2e.sh

# Individual layer:
bash test-e2e.sh --layer d           # only Layer D (opencode-egress-router)
bash test-e2e.sh --layer w           # only Layer W (browser-search)
bash test-e2e.sh --layer contract    # only the 9/9 contract test
```

## All `bun run` shortcuts

| Command | What it does | Time |
|---|---|---|
| `bun run test:e2e --quick` | 7-layer E2E (skips CF + G) | ~15s |
| `bun run test:e2e` | Full 9-layer E2E | ~60s |
| `bun run test:contract` | Mock 9/9 contract test | ~3s |
| `bun run test:contract-real` | Real gateway 9/9 contract | ~5s |
| `bun run test:plugin` | 7 reconcile plugin unit tests | ~1s |
| `bun run test:w` | Layer W quick contract (CloakBrowser tier) | ~20s |
| `bun run test:w:full` | Layer W full contract (with native SearXNG) | ~3 min |
| `bun run test:e2e:w` | Layer W E2E block only | ~20s |
| `bun run bench:w:quick` | Layer W benchmark (no engine, 3 runs) | ~30s |
| `bun run bench:w` | Layer W full benchmark (all tiers, 3 runs) | ~3 min |
| `bun run test:selftest` | Assertion engine selftest | ~1s |
| `bun run test:smoke` | Mock gateway smoke test | ~3s |
| `bun run test:all` | Selftest + smoke + contract + plugin | ~8s |
| `bun run bs:install` | Install Layer W deps + Chromium binary (~700 MB) | ~3 min |
| `bun run bs:status` | Show Layer F→W proxy bridge status | <1s |
| `bun run bs:fetch <url>` | Fetch a URL via Layer F proxy (or direct) | varies |
| `bun run oc:install` | Clone upstream oc-proxy into oc-proxy/upstream/ | ~5s |
| `bun run oc:dev` | Serve Layer P on :7860 (HF convention) | — |
| `bun run oc:test` | Layer P contract (8 assertions, live upstream) | ~30s |
| `bun run oc:hf` | Assemble ready-to-push HF Space in dist/ | ~2s |
| `bun run example:layer-w` | SearXNG + CloakBrowser + free model answer | ~15s |
| `bun run example:layer-w-compare` | Compare free vs paid model on same research | ~20s |
| `bun run example:layer-w-multilingual` | Non-English research (default: Japanese) | ~15s |
| `bun run update:deps` | Update all dep trees (root + plugins + cf-worker-proxy) | ~5s |
| `bun run cf:dev` | Start Cloudflare Worker locally (:8787) | — |
| `bun run cf:deploy` | Deploy CF Worker to Cloudflare edge | — |
| `bun run launch:proxy` | Start opencode-egress-router (:8318) | — |
| `bun run launch:unified` | Start sphinx-lite + proxy together | — |
| `bun run install:sphinx-lite` | Install the CLI binary shim | — |
| `bun run vps:list` | List your VPS proxy fleet | — |
| `bun run vps:add` | Add a VPS proxy to the fleet | — |
| `bun run vps:test` | Test all VPS proxies (TCP + SOCKS5) | — |
| `bun run vps:generate` | Generate integration configs | — |

## What to expect

| Command | Output | Cost |
|---|---|---|
| `bun run examples/index.zen-free.ts` | Holiday description via `glm-5.3-flash-free` | $0 |
| `bun run examples/index.opencode.ts` | Same prompt, via `kimi-k3` (paid) | ~$0.0006 |
| `bun run examples/index.layer-w.ts "..."` | Grounded answer with source URL | $0 |
| `bun run test:contract` | `verdict: PASS` + 9 assertions | $0 |
| `bun run test:e2e --quick` | 10 PASS, 4 SKIP = ALL PASS | $0 |
| `bun run test:w` | Layer W 3 PASS / 3 SKIP (no engine) | $0 |
| `bun run bench:w` | Latency table (SearXNG, CloakBrowser, bridge) | $0 |

## Advanced deployment paths

### Cloudflare Workers edge proxy (Layer CF — no VPS, no credit card)

```bash
cd cf-worker-proxy
bun install
bun run cf:dev          # local dev on :8787 (wrangler)
bun run cf:deploy       # deploy to Cloudflare's 300+ edge locations
# Each request hits a different edge IP → automatic rotation
# 100K requests/day free
```

### VPS personal proxy fleet (Layer F-primary — replaces public proxies)

```bash
# Read the guide (10 free-tier cloud providers):
cat vps-proxy/FREE-VPS-PROXY-GUIDE.md | less

# Deploy sing-box on a VPS:
bash vps-proxy/deploy-proxy.sh ubuntu@1.2.3.4 1080

# Add to fleet + generate configs:
bash vps-proxy/rotate-egress.sh add socks5://1.2.3.4:1080
bash vps-proxy/rotate-egress.sh test
bash vps-proxy/rotate-egress.sh generate

# Disable public proxy scanning (switch to VPS-only mode):
bash vps-proxy/rotate-egress.sh disable-public
```

### Containerized via kiri/Docker (all layers in one container)

```bash
bash kiri/install-kiri.sh       # installs kiri + builds image + starts stack
kiri compose ps                 # verify running
kiri compose logs -f            # follow logs
kiri compose down               # stop
# Layer W (SearXNG + Camofox) as separate containers:
kiri compose --profile search up -d
```

### zen-unlimited Linux port (Layer G — muse-spark via sing-box egress)

```bash
cd zen-unlimited-linux
bun install
bash scripts/install-zen-stack.sh     # systemd user units
bun run src/index.ts doctor           # health check
# Gateway on :20128, relay on :1090
```

### browser-search web research (Layer W — anti-hallucination tooling)

```bash
# Install (npm deps + Chromium binary, ~700 MB one-time):
bun run bs:install

# Or via setup.sh (interactive, also symlinks into ~/.config/opencode/skills/):
bash setup.sh            # choose 'y' at the Layer W prompt

# Quick contract (CloakBrowser tier only, ~20s, no engine needed):
bun run test:w

# Full contract (launches native SearXNG engine, ~3 min):
SEARXNG_SRC=/tmp/searxng-src bun run test:w:full

# Benchmark (latency measurements, 3 runs per test):
bun run bench:w

# Or run the search + browse tiers directly:
node browser-search/scripts/searxng/searxng.mjs search "opencode v2" --lang en
node browser-search/scripts/cloak/cloak-fetch.mjs "https://example.com"

# Route browsing through the Layer F proxy fleet:
bun run bs:fetch "https://protected-site.com"

# End-to-end example (search → extract → grounded model answer, $0):
bun run example:layer-w "What is the latest stable version of opencode?"
```

### oc-proxy portable Zen bypass (Layer P — HF Spaces instead of Vercel)

```bash
# Install upstream (clones MarkDev11/oc-proxy, zero npm deps):
bun run oc:install

# Serve locally on :7860 (HF Spaces port convention):
bun run oc:dev          # dashboard at http://127.0.0.1:7860/

# 8-assertion contract incl. live fingerprint proof:
bun run oc:test

# Assemble a ready-to-push Hugging Face Space:
bun run oc:hf           # -> oc-proxy/dist/oc-proxy-hf-space/
cd oc-proxy/dist/oc-proxy-hf-space
git init && git add -A && git commit -m "oc-proxy Layer P"
git remote add space https://huggingface.co/spaces/<USER>/oc-proxy
git push space master
# Then set GATEWAY_API_KEY in Space settings -> Variables and secrets.
```

That's it. The full stack is operational: Layers B+A+C+D+D_thin+G+F+CF+W+P, all validated by one command (`test-e2e.sh`).
