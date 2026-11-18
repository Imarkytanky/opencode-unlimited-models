# Layer P — oc-proxy (portable Zen gate bypass, HF Spaces-ready)

Layer P vendors the **deployment** of [MarkDev11/oc-proxy](https://github.com/MarkDev11/oc-proxy)
— a thin OpenAI-compatible proxy for the opencode.ai free tier — as a portable
HTTP service for **Hugging Face Spaces** (primary target, per the upstream
README's own advice: *"For long runs, consider an HF Space / VPS instead"*),
plus any VPS or local machine. It is functionally a sibling of **Layer D**
(opencode-egress-router): same upstream contract, different packaging.

## What it does

Reproduces OpenCode v2's client fingerprint so every `*-free` model works from
outside the OpenCode CLI (which returns `403 FreeTierError` otherwise):

- v2 UA `opencode/latest/2.0.26/cli` + session headers (counter-encoded prefix)
- OpenCode's exact `read` + `shell` tool definitions as verbatim decoys
- `x-opencode-request` header absent
- Translates upstream Responses API (muse-spark) / Chat Completions (all other
  `*-free`) back to standard OpenAI `chat.completions` (stream + non-stream)

Endpoints: `/v1/models` (live, 5-min cache), `/v1/chat/completions`,
`/api/health`, `/api/stats`, and a live monitor dashboard at `/`.

## Why this stack includes it

| Aspect | Layer D (egress-router, Go) | Layer P (oc-proxy, Node) |
|---|---|---|
| Runs where | localhost daemon | **HF Space / VPS / local — remote-capable** |
| Best for | opencode CLI on the same machine | hosted agents, CI, shared teams, no local daemon |
| Dashboard | none | live monitor (`/`) + `/api/stats` |
| 429 handling | relay failover (direct→ovh→oracle→tor) | optional pooled-HTTP-proxy fallback (`PROXY_FALLBACK=1`) |
| Long-run cutoffs | none needed (local) | graceful `finish_reason:"length"` deadlines (Vercel-proof; raise on HF) |
| Dependencies | Go binary | **zero npm deps** (Node ≥ 18 native fetch) |

Both layers can coexist: Layer D for the local CLI, Layer P for anything that
needs a URL (phone, CI runner, teammate, second machine).

## What ships vs. what installs

The upstream repo has **no LICENSE file** (all rights reserved by default), so
this stack does **not** redistribute its code. What ships in the tarball:

- `oc-proxy/server.js` — this stack's adapter (CommonJS shim giving the
  upstream Vercel-style handlers a plain-Node http server; HF Space entrypoint)
- `oc-proxy/install-oc-proxy.sh` — clones upstream at install time into
  `oc-proxy/upstream/` (gitignored), pins a known-good commit, verifies syntax
- `oc-proxy/make-hf-space.sh` — assembles `dist/oc-proxy-hf-space/`, a complete
  ready-to-push HF Space (Dockerfile, README frontmatter, upstream code, adapter)
- `oc-proxy/package.json` — CommonJS scope (upstream handlers use `require`)
- `verify-oc-proxy.sh` (stack root) — Layer P contract test (8 assertions)

## Install

```bash
bash oc-proxy/install-oc-proxy.sh          # clone upstream (pinned ref)
node oc-proxy/server.js                    # serve on http://0.0.0.0:7860
bash verify-oc-proxy.sh                    # 8-assertion contract test
```

Pinned provenance: upstream commit is recorded in `upstream/.upstream-provenance`.
Re-pin with `OC_PROXY_REF=<sha> bash oc-proxy/install-oc-proxy.sh`.

## Deploy to Hugging Face Spaces (primary path)

One command (implements the whole checklist: pin → assemble → create →
secrets → push → wait → validate → Layer B auto-apply at the RUNNING gate):

```bash
bash oc-proxy/deploy-oc-proxy-hf.sh --check              # local-only validation, no HF writes
HF_TOKEN=<PRO-account token> bash oc-proxy/deploy-oc-proxy-hf.sh   # full deployment
```

Manual fallback (same steps by hand):

```bash
bash oc-proxy/make-hf-space.sh --check     # assemble + validate dist/oc-proxy-hf-space/
cd oc-proxy/dist/oc-proxy-hf-space
git init && git add -A && git commit -m "oc-proxy Layer P"
git remote add space https://huggingface.co/spaces/<USER>/oc-proxy
git push space main
```

Then in Space **Settings → Variables and secrets**:

| Variable | Required | Notes |
|---|---|---|
| `GATEWAY_API_KEY` | **strongly recommended** | comma-separated keys; open access if unset — never expose publicly without it |
| `SOFT_DEADLINE_MS` / `ABSOLUTE_DEADLINE_MS` | no | HF has no Vercel hard-kill; raise to `300000` / `330000` for long agentic runs |
| `PROXY_FALLBACK` / `PROXY_POOL_URL` | no | opt-in 429 fallback via pooled proxies |
| `UPSTREAM_BASE_URL` | no | default `https://opencode.ai` |

Space URL: `https://<USER>-oc-proxy.hf.space` — base URL for OpenAI-compatible
clients is the root (`/v1/...` routes directly; no rewrite needed, unlike Vercel).

HF Space notes:
- Free CPU-basic hardware is sufficient (zero deps, in-memory stats)
- Free Spaces sleep after 48h inactivity; first request after sleep pays cold start
- In-memory stats reset on restart (upstream design — nothing is stored)
- Outbound network is allowed, so `PROXY_POOL_URL` (jsDelivr pool) works

## Connect to the model layers (Layer B)

After deploying, add a provider to your `opencode.json` (Layer B is
hand-written by design — add this only when your Space is live, so the
D_thin reconcile never sees ghost models):

```json
"oc-proxy-hf": {
  "name": "OpenCode Zen Free (via oc-proxy HF Space)",
  "package": "@opencode/ai/providers/openai-compatible",
  "settings": {
    "baseURL": "https://<USER>-oc-proxy.hf.space/v1",
    "apiKey": "{env:OC_PROXY_KEY}"
  },
  "models": {
    "glm-5.3-flash-free": { "name": "GLM 5.3 Flash (free)", "capabilities": { "tools": true } },
    "deepseek-v4.1-flash-free": { "name": "DeepSeek V4.1 Flash (free)", "capabilities": { "tools": true } }
  }
}
```

(baseURL and apiKey both live in `settings` — same convention as the validated
`opencode` and `opencode-zen` providers in this Layer B.)

Set `OC_PROXY_KEY` to the `GATEWAY_API_KEY` you configured in the Space.

For plain AI SDK code (see `examples/index.layer-w.ts` for the pattern):
`createOpenAICompatible({ baseURL: "https://<USER>-oc-proxy.hf.space/v1", apiKey: process.env.OC_PROXY_KEY })`.

## Contract test

```bash
bash verify-oc-proxy.sh            # full: boots server, live upstream proof
bash verify-oc-proxy.sh --quick    # skips live chat + Space build
```

8 assertions: P0 install/syntax, P1 boot+health, P2 live models (22 `*-free`
ids at validation time), P3 **live fingerprint proof** (PASS on 200; PASS on
429 `FreeUsageLimitError` = fingerprint accepted, quota hit; FAIL on 403
`FreeTierError` = fingerprint rejected), P4 auth (401 without key, pass with
key), P5 dashboard, P6 HF Space packaging validity.

Validated 2026-11-17: **8/8 PASS** — P3 returned 429 `FreeUsageLimitError`
(fingerprint accepted) against the live upstream catalog.

## Known upstream drift (2026-11-17)

- The upstream README still showcases `muse-spark-1.3-contributor-free`, but
  the live catalog has retired muse-spark; current free ids include
  `glm-5.3-flash-free`, `mimo-v2.6-flash-free`, `deepseek-v4.1-flash-free`,
  `longcat-2.5-free`, `iceman-free`, `beam-free`, `flint-40b-free`,
  `nemotron-3.5-*-free`, `hy4-flash-free` (22 with `oc/` aliases). The proxy's
  model allowlist (`*-free` suffix) handles the rotation correctly — only the
  docs are stale. The contract test picks models from the live catalog to
  survive future rotation.
- Upstream free tier rate-limits aggressively from a single IP (429s during
  heavy testing are normal); `PROXY_FALLBACK` or a VPS deployment mitigates.

## Deployment status (2026-11-17) — HF account gating + the Vercel verdict

Measured live with the user-provided token (account `Markywinning`, `isPro:false`):

- **Docker Space creation → HTTP 402**: *"Static Spaces are free for everyone,
  but hosting Gradio and Docker Spaces on free cpu-basic requires a PRO
  subscription."* Policy change rolled out 2026-07 (forum threads 2026-07-08,
  2026-09-16: "only Static Spaces stay free"). HF's pricing page still lists
  cpu-basic as FREE — stale vs runtime enforcement.
- **HF Jobs → HTTP 402**: *"Pre-paid credit balance is insufficient"* (cpu-basic
  $0.0002/min ≈ $7.30/mo; default timeout 30 min, ports exposeable via the Jobs
  proxy).
- Conclusion: **on a free account in 2026-11, HF cannot host oc-proxy at all**;
  with PRO, the HF Docker Space is the strictly best runtime for agentic
  streaming (no maxDuration) and the Vercel path can be dropped. Full matrix,
  claim-by-claim critique and confidence scores:
  `download/oc-proxy-hf-vs-vercel-comparison.md`.
- Therefore Layer B does NOT yet contain `oc-proxy-hf` (no ghost models for the
  D_thin reconcile): `deploy-oc-proxy-hf.sh` applies the snippet automatically
  once the Space reaches RUNNING and passes live validation.
- Strategic compose shipped: `examples/index.oc-proxy-agent.ts` (Layer W web
  research → Layer P hosted gateway — the whole loop off-box).
