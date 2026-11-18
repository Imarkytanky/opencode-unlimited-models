# Copy-Ready Prompt — Reproduce the v13 Stack

> Copy and paste verbatim into an AI assistant (Claude, GPT, Gemini, GLM, etc.) with a clean sandbox to reproduce the opencode-unlimited-models v13.0.0 stack end-to-end.

---

## Prompt

```
Build the "opencode v2 unlimited models" stack v13.0.0 — a 10-layer architecture
for single-key access to 52+ models through opencode Console, plus deterministic
web research, plus a hosted off-box loop, at $0 model cost.

LAYER MAP (build in this order):
  Layer A  — opencode Console discovery (52-model catalog; just sign up at
             opencode.ai and grab the API key)
  Layer B  — config/opencode.json declaring 6 providers:
               opencode           (paid 52-model catalog)
               opencode-zen       (free Zen bypass, http://127.0.0.1:8318)
               oc                 (Layer G, http://localhost:20128/v1)
               oc-proxy-northflank (Layer P PRIMARY, .invalid placeholder URL)
               oc-proxy-render    (Layer P FALLBACK, .invalid placeholder URL)
               oc-proxy-oracle    (Layer P OFF-BOX, .invalid placeholder URL)
  Layer C  — sphinx-lite (local sphinx fork, optional)
  Layer D  — opencode-egress-router on :8318 (Go binary, relay failover
             direct → ovh → oracle → tor, opens up 22 *-free Zen models)
  Layer D_thin — plugins/reconcile/ plugin (every 5 min, "disable, never delete")
  Layer F  — proxy-hunter (2259 SOCKS5 pool) + vps-proxy for IP rotation
  Layer G  — zen-unlimited-linux on :20128 (higher-throughput alternate Layer D)
  Layer CF — Cloudflare Workers edge proxy (optional)
  Layer W  — browser-search v3.2.1:
               SearXNG :8080 (metasearch, SEARXNG_CONTACT_URL env required)
               Camofox :9377 (headless Firefox, pinned 1.18.1)
               CloakBrowser ^0.6.3 (Chromium 146 — DO NOT use 0.7.x, needs license)
             bs-bridge.sh ties Layer F → Layer W (proxy fallback chain)
  Layer P  — oc-proxy (Zen bypass packaged as portable HTTP service)
             Three-provider rotation:
               1. Northflank Sandbox (PRIMARY, always-on, no card, Docker)
               2. Render free tier   (FALLBACK, 15-min sleep, Docker+WS)
               3. Oracle+Coolify     (OFF-BOX, hosts Layer W too, card required)
             All three pin OC_PROXY_REF=2a41370e4ee121796bdbf65a2efeae99e80b58d1
             Each provider's baseURL starts as <name>.invalid/v1 (RFC 2606) so
             D_thin reconcile sees the slot but no model resolves. The deploy
             script's step 8 flips baseURL to live URL + sets _layerP.live=true
             ONLY at the HEALTHY/RUNNING gate (no ghost models).

INVARIANTS (must hold):
  I1. "only adds, never overwrites" — Layer A catalog merge (verify-a-contract.sh C1-C7)
  I2. "disable, never deletes"      — Layer D_thin reconcile    (verify-a-contract.sh C8-C9)
  I3. "no ghost models"             — Layer B never contains a provider whose
                                      baseURL doesn't resolve
  I4. "exact upstream pin"          — every external dep has an exact SHA/ref:
                                      CloakBrowser ^0.6.3, Camofox 1.18.1,
                                      oc-proxy 2a41370e4ee1…
  I5. "anti-hallucination gate"     — Layer W fetches real web content before
                                      the model answers factual questions;
                                      cheapest model (glm-5.3-flash-free) is the default

VALIDATION (must pass before declaring "v13 done"):
  bash verify-a-contract.sh        # 9/9 PASS (Layer A + D_thin contract)
  bash verify-oc-proxy.sh          # 8/8 PASS (P0-P7, incl. live fingerprint proof:
                                   #   200 OK = accepted
                                   #   429 FreeUsageLimitError = accepted, quota hit
                                   #   403 FreeTierError = REJECTED, FAIL)
  bash verify-browser-search.sh    # 6/6 PASS (W1-W6)
  bash benchmark-layer-w.sh        # 5 baselines recorded (SearXNG cold/warm,
                                   #   cloak fetch, smart-extract, bridge proxy)
  bash test-e2e.sh                 # 8/8 PASS end-to-end at $0 model cost
  (audit)                         # 24/24 invariants: 9 PASS / 2 WARN / 0 FAIL / 0 CVE

DELIVERABLES (must ship):
  - source: 10 layers in repo root (browser-search/, oc-proxy/, opencode-proxy/,
            sphinx-lite/, zen-unlimited-linux/, plugins/, proxy-hunter/,
            vps-proxy/, cf-worker-proxy/, config/)
  - setup.sh — 5-step bootstrap, ~30 seconds, ends with 9/9 contract PASS
  - verify-*.sh + test-e2e.sh + benchmark-layer-w.sh
  - .github/workflows/test.yml — 4 jobs + daily 03:30 UTC schedule
  - Dockerfile + docker-compose.yml — `search` profile (searxng + camofox)
  - examples/ — index.layer-w.ts, index.layer-w-compare.ts,
               index.layer-w-multilingual.ts, index.oc-proxy-agent.ts
  - README.md, INSTALL.md, QUICKSTART.md, CHANGELOG.md, NOTICE, LICENSE
  - oc-proxy/deploy-oc-proxy-hf.sh          (HF Space path, PRO-gated today)
  - oc-proxy/deploy-oc-proxy-northflank.sh  (PRIMARY: Northflank Sandbox)
  - oc-proxy/make-hf-space.sh               (assembles portable Dockerfile)
  - oc-proxy/install-oc-proxy.sh            (pins upstream to exact SHA)
  - download/free-hf-vercel-alternatives-top5.md  (research)
  - download/northflank-deploy-guide.md     (step-by-step deploy guide)
  - download/oc-proxy-hf-vs-vercel-comparison.md  (decision matrix)

DESIGN PRINCIPLES:
  1. Pin every external dep to an exact SHA/ref. Drift can't surprise you.
  2. Free-first. Every layer has a $0 path. No model inference cost to date.
  3. No ghost models. Layer B never contains a provider whose baseURL doesn't resolve.
  4. Anti-hallucination gate. Layer W grounds answers in live web content.
  5. Composability. Each layer is independent and replaceable.

REPRODUCES: opencode-unlimited-models v13.0.0
SOURCE:     https://github.com/Imarkytanky/opencode-unlimited-models
DOCS:       https://imarkytanky.github.io/opencode-unlimited-models/
LAST VALIDATED: 2026-11-17, 24/24 assertions PASS, $0 model cost
```

---

## How to use this prompt

1. Open a fresh sandbox with `bun` ≥ 1.0, `node` ≥ 18, `python3` ≥ 3.10, `go` ≥ 1.21, `docker`, `git`.
2. Paste the prompt above into an AI coding assistant (Claude Code, GPT with code interpreter, Cursor, etc.).
3. The assistant should reproduce the stack end-to-end in ~30 minutes if the sandbox is connected to the internet.
4. Validate by running the five `verify-*.sh` scripts — expect 9+8+6+5+8 = 36 PASS assertions total.
5. If any assertion fails, the assistant should fix the cause (not patch the symptom) and re-run.

## What the prompt assumes

- Internet access to `opencode.ai`, `huggingface.co`, `northflank.com`, GitHub raw, npm, PyPI.
- A GitHub account (for cloning and, if you want to deploy Layer P, for pushing to a registry).
- A Northflank account + API token (for Layer P PRIMARY deployment).
- Local Docker daemon (for Layer W `docker-compose --profile search`).

## What the prompt does NOT assume

- No paid accounts required (HF PRO, Render paid, Vercel Pro, OpenAI API key — none needed).
- No GPU required (CloakBrowser runs on CPU).
- No specific cloud provider required (Oracle Always Free is one of three Layer P paths).
