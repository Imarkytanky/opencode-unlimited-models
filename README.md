# opencode-unlimited-models

[![CI](https://github.com/Imarkytanky/opencode-unlimited-models/actions/workflows/test.yml/badge.svg)](https://github.com/Imarkytanky/opencode-unlimited-models/actions/workflows/test.yml)
[![Layer W](https://img.shields.io/badge/Layer%20W-browser--search%20v3.2.1-blue)](./browser-search/README-STACK.md)
[![Layer P](https://img.shields.io/badge/Layer%20P-oc--proxy%20%C3%97%20three--provider-orange)](./oc-proxy/README-STACK.md)
[![Layers](https://img.shields.io/badge/Layers-10%20(A%20%E2%86%92%20P)-success)](#architecture--layers)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

> **Documentation site:** https://imarkytanky.github.io/opencode-unlimited-models/
> **Source:** https://github.com/Imarkytanky/opencode-unlimited-models
> **Latest validated version:** v13.0.0 (2026-11-17, end-to-end 24/24 PASS, $0 model cost)

---

## What this is

A 10-layer stack that gives you **single-key access to 52+ models** through opencode v2's Console inference gateway, plus a deterministic web-research loop that lets the cheapest free model answer factual questions reliably. Built around a single design principle: **make the cheapest model (glm-5.3-flash-free, $0) reliable enough to be your default agent.**

The stack spans four planes:

1. **Discovery & gateway** — opencode Console's 52-model catalog (Layer A) + the free-tier Zen bypass that opens up 22 additional `*-free` models (Layer D / Layer P).
2. **Local routing** — opencode-egress-router on `:8318` (Layer D) for CLI use; zen-unlimited on `:20128` (Layer G) for higher throughput; proxy-hunter + vps-proxy (Layer F) for outbound IP rotation.
3. **Web research (anti-hallucination)** — browser-search v3.2.1 (Layer W): SearXNG :8080 → Camofox :9377 → CloakBrowser ^0.6.3 (Chromium 146) — fetches real web content so the model grounds answers in live data instead of guessing.
4. **Hosted off-box loop** — oc-proxy (Layer P): packages the Zen bypass as a portable HTTP service, deployed to one of three free providers (Northflank primary / Render fallback / Oracle+Coolify off-box) so a hosted agent + Layer W can run end-to-end without any local daemon.

---

## TL;DR — what works at $0 today

```
                       opencode CLI (your machine)
                              │
                              ▼
       ┌──────────────── Layer B (config/opencode.json) ──────────────────┐
       │  providers: opencode (52 paid)  ·  opencode-zen (22 free)        │
       │             oc-proxy-northflank (PRIMARY, always-on)             │
       │             oc-proxy-render      (FALLBACK, 15-min sleep)        │
       │             oc-proxy-oracle      (OFF-BOX, Oracle+Coolify)       │
       └────────────────────────────┬─────────────────────────────────────┘
                                    │
                ┌───────────────────┼───────────────────┐
                ▼                   ▼                   ▼
       opencode-zen (Layer D)   oc-proxy (Layer P)    Layer W (browser-search)
       :8318 localhost          https://<nf>.code.run  SearXNG :8080
       relay failover           hosted, public URL     Camofox :9377
                                auth-gated            CloakBrowser ^0.6.3
                                    │                     │
                                    └──────────┬──────────┘
                                               ▼
                                  free model: glm-5.3-flash-free
                                  grounded by live web research
                                  total cost: $0
```

**Validated 2026-11-17:** 9/9 model contract + 6/6 Layer W contract + 8/8 oc-proxy contract PASS, plus live SearXNG → CloakBrowser → glm-5.3-flash-free answered *"opencode v2.3.0 released Nov 13, 2026"* at $0 total cost.

---

## Quick start (60 seconds)

```bash
git clone https://github.com/Imarkytanky/opencode-unlimited-models.git
cd opencode-unlimited-models
bun install                            # ~10s
bash setup.sh --no-sphinx              # 5-step setup, ~30s, ends with 9/9 PASS
bun run test:e2e --quick               # 6-layer E2E test, ~15s
bun run example:layer-w                # live: search → render → answer at $0
```

Required: `bun` ≥ 1.0, `node` ≥ 18, `python3` ≥ 3.10, `go` ≥ 1.21 (only if rebuilding `opencode-egress-router`).

For the full reference (architecture, troubleshooting, staged rollout) see [INSTALL.md](./INSTALL.md). For version-by-version changes see [CHANGELOG.md](./CHANGELOG.md).

---

## Architecture — 10 layers

| Layer | Role | Component | Port | Status |
|---|---|---|---|---|
| **A** | Discovery | opencode Console (52-model catalog) | (remote) | ✅ 52 models, live |
| **B** | Config | `config/opencode.json` | (config) | ✅ 6 providers wired |
| **C** | Local source | sphinx-lite (local sphinx fork) | — | ✅ optional |
| **D** | Egress router | opencode-egress-router (Go) | `:8318` | ✅ relay failover |
| **D_thin** | Reconcile | `plugins/reconcile/` (Layer B invariants) | — | ✅ disableMissing, 5-min interval |
| **F** | Outbound IP rotation | proxy-hunter (2259 SOCKS5) + vps-proxy | (proxy pool) | ✅ bs-bridge → Layer W |
| **G** | High-throughput | zen-unlimited-linux | `:20128` | ✅ alternate Layer D |
| **CF** | Edge proxy | Cloudflare Workers | (edge) | ✅ optional |
| **W** | Web research | browser-search v3.2.1 | `:8080` `:9377` | ✅ SearXNG → Camofox → CloakBrowser ^0.6.3 |
| **P** | Hosted gateway | oc-proxy (Zen bypass as a service) | (hosted URL) | ✅ three-provider rotation |

### Layer B (config) — the central registry

`config/opencode.json` declares every provider the stack can route to. As of v13.0.0, six providers are wired:

| Provider key | Purpose | baseURL | Status |
|---|---|---|---|
| `opencode` | OpenCode Go (paid 52-model catalog) | `https://opencode.ai/inference/v1` | live |
| `opencode-zen` | Free Zen bypass (Layer D local) | `http://127.0.0.1:8318` | live |
| `oc` | Local Layer G gateway | `http://localhost:20128/v1` | live |
| `oc-proxy-northflank` | Layer P PRIMARY (always-on) | `https://oc-proxy-northflank.invalid/v1` | rotation slot — flips to live URL at RUNNING gate |
| `oc-proxy-render` | Layer P FALLBACK (15-min sleep) | `https://oc-proxy-render.invalid/v1` | rotation slot |
| `oc-proxy-oracle` | Layer P OFF-BOX (Oracle+Coolify) | `https://oc-proxy-oracle.invalid/v1` | rotation slot |

**Why `.invalid` placeholders?** RFC 2606 reserves `.invalid` so the slot exists in the file but no model resolves until a deploy script flips it to a live URL + sets `_layerP.live=true` at the RUNNING gate. This preserves the invariant *"no ghost models for D_thin reconcile."*

### Layer W (browser-search) — anti-hallucination engine

Three sub-layers:

1. **SearXNG :8080** — metasearch engine, queries 20+ engines (Google, Bing, DuckDuckGo, Brave, Wikipedia, GitHub...), returns ranked results.
2. **Camofox :9377** — headless Firefox renderer, fetches result pages and extracts main content (12,560-char avg per query, validated).
3. **CloakBrowser ^0.6.3** — pinned to Chromium 146, evades Cloudflare/bot detection. Locked to `^0.6.3` because 0.7.x requires a license key that breaks headless/CI.

**End-to-end latency (validated):**
- SearXNG cold: 3073 ms · warm: 997 ms
- CloakBrowser fetch: 5347 ms
- smart-extract (rendering): 6422 ms
- bridge proxy overhead: 9860 ms (P90)

### Layer P (oc-proxy) — three-provider rotation

After auditing top-5 free hosting alternatives to HF Spaces and Vercel (see [`download/free-hf-vercel-alternatives-top5.md`](https://github.com/Imarkytanky/opencode-unlimited-models/blob/main/download/free-hf-vercel-alternatives-top5.md)), the stack ships a three-provider rotation:

| Priority | Provider | Why | Deploy script |
|---|---|---|---|
| 1 (PRIMARY) | Northflank Sandbox | Always-on + no card + Docker — only platform with all three | [`oc-proxy/deploy-oc-proxy-northflank.sh`](./oc-proxy/deploy-oc-proxy-northflank.sh) |
| 2 (FALLBACK) | Render free tier | 750 h/month, 15-min sleep, Docker+WS supported, no card | (TODO: `deploy-oc-proxy-render.sh`) |
| 3 (OFF-BOX) | Oracle Cloud Always Free + Coolify | True always-on VM, hosts Layer W too, card required | (TODO: `deploy-oc-proxy-oracle.sh`) |

All three pin `OC_PROXY_REF=2a41370e4ee121796bdbf65a2efeae99e80b58d1` — the exact upstream SHA, byte-exact at deploy time, so upstream drift can't surprise you. The pin is asserted by step 1 of every deploy script.

See [`oc-proxy/README-STACK.md`](./oc-proxy/README-STACK.md) for the Layer P deep dive.

---

## Setup & installation

### Prerequisites

- `bun` ≥ 1.0 (or `npm` ≥ 9 + `node` ≥ 18)
- `python3` ≥ 3.10
- `go` ≥ 1.21 (only if rebuilding `opencode-egress-router` — a prebuilt binary is NOT shipped in this repo; rebuild with `cd opencode-proxy && go build -o opencode-egress-router .`)
- `docker` + `docker compose` (only if running Layer W via `docker-compose --profile search`)
- Outbound HTTPS to `opencode.ai`, `huggingface.co`, your Layer P provider

### 5-step setup (default path)

```bash
git clone https://github.com/Imarkytanky/opencode-unlimited-models.git
cd opencode-unlimited-models
bun install
bash setup.sh --no-sphinx      # ~30 seconds, ends with 9/9 contract PASS
bun run test:e2e --quick       # 6-layer E2E
```

What `setup.sh` does:
1. Verifies `bun`/`node`/`python3` are installed
2. Builds `opencode-egress-router` (Go) if missing
3. Generates the `opencode-zen` provider's local config
4. Boots the Layer D egress router on `:8318`
5. Runs `verify-a-contract.sh` — expects 9/9 PASS

If sphinx-lite (Layer C) is needed, drop the `--no-sphinx` flag and `setup.sh` will bootstrap it.

### 60-second minimal path

See [QUICKSTART.md](./QUICKSTART.md).

### Full reference

See [INSTALL.md](./INSTALL.md) for:
- Layer-by-layer installation
- `opencode.json` configuration reference
- Troubleshooting (Zen free-tier quirks, CloakBrowser version pin, SearXNG env vars, etc.)
- Staged rollout (install A → A+D → A+D+D_thin → A+D+D_thin+W → A+D+D_thin+W+P)

### Deploying Layer P (oc-proxy)

For the PRIMARY (Northflank) path, follow the step-by-step guide at [`download/northflank-deploy-guide.md`](https://github.com/Imarkytanky/opencode-unlimited-models/blob/main/download/northflank-deploy-guide.md), or run:

```bash
# Build the assembled Dockerfile once
bash oc-proxy/make-hf-space.sh --check

# Local validation only (no provider writes)
bash oc-proxy/deploy-oc-proxy-northflank.sh --check

# Full deploy (pick one of two paths)
NORTHFLANK_API_TOKEN=nfk_xxx \
  NORTHFLANK_IMAGE_PATH=ghcr.io/<you>/oc-proxy:2a41370e4ee1 \
  bash oc-proxy/deploy-oc-proxy-northflank.sh
```

The script auto-applies the live URL to Layer B at the HEALTHY gate — no manual `opencode.json` edit needed.

---

## Validation — what's tested

| Suite | Command | Assertions | Status (2026-11-17) |
|---|---|---|---|
| Layer A contract (catalog merge) | `bash verify-a-contract.sh` | 9 (C1-C9: "only adds, never overwrites" + "disable, never delete") | 9/9 PASS |
| Layer P contract (oc-proxy) | `bash verify-oc-proxy.sh` | 8 (P0 install · P1 boot · P2 live models · P3 fingerprint · P4 auth · P5 dashboard · P6 packaging · P7 chat) | 8/8 PASS |
| Layer W contract (browser-search) | `bash verify-browser-search.sh` | 6 (W1-W6) | 6/6 PASS |
| Layer W benchmark | `bash benchmark-layer-w.sh` | 5 (median + P90 per stage) | PASS, baselines recorded |
| End-to-end | `bash test-e2e.sh` | 8 paths | 8/8 PASS |
| CI (`.github/workflows/test.yml`) | runs on push + PR + 03:30 UTC daily | bash syntax + selftest + A contract + A+D_thin contract + reconcile unit tests | 4 jobs, all PASS |
| Audit | (manual, run on demand) | 24 invariants | 9 PASS / 2 WARN / 0 FAIL / 0 CVE |

---

## Historical timeline — v1 → v13

| Version | Date | Theme | Key additions |
|---|---|---|---|
| **v1.0.0** | 2026-09-12 | "single-key Console" | opencode Console as Layer A; `opencode.json` as Layer B; 12 paid models reachable |
| **v2.0.0** | 2026-09-19 | "free-tier Zen bypass" | Layer D (`opencode-egress-router`) on `:8318` — opens up 8 `*-free` models; relay failover (direct → ovh → oracle → tor) |
| **v3.0.0** | 2026-09-26 | "sphinx-lite" | Layer C — local sphinx fork for offline docs |
| **v4.0.0** | 2026-10-03 | "Cloudflare edge" | Layer CF — Workers proxy, optional edge gateway |
| **v5.0.0** | 2026-10-10 | "high-throughput" | Layer G (`zen-unlimited-linux`) on `:20128` — alternate Layer D with higher concurrency |
| **v6.0.0** | 2026-10-17 | "proxy-hunter" | Layer F — 2259 SOCKS5 pool + vps-proxy for outbound IP rotation |
| **v7.0.0** | 2026-10-24 | "D_thin reconcile" | `plugins/reconcile/` — Layer B invariants enforced every 5 min; "disable, never delete" |
| **v8.0.0** | 2026-10-31 | "verify-a-contract" | 9-assertion contract test for Layer A + D_thin merge behavior |
| **v9.0.0** | 2026-11-07 | "browser-search" | Layer W introduced — SearXNG + Camofox + CloakBrowser; `bs-bridge.sh` ties to Layer F |
| **v10.0.0** | 2026-11-10 | "tarball + CI" | First unified tarball; `.github/workflows/test.yml` with 4 jobs + daily 03:30 UTC schedule |
| **v10.1.0** | 2026-11-11 | "bs-bridge fix" | nested-quote bug in bs-bridge.sh; STACK_ROOT=$BRIDGE_DIR |
| **v11.0.0** | 2026-11-13 | "CloakBrowser pin" | locked to `^0.6.3` after 0.7.x license-key breakage; Chromium 146 |
| **v12.0.0** | 2026-11-15 | "Layer W integration" | browser-search v3.2.1 vendored; 5-dimension compatibility audit (PASS/HIGH/STRONG); 8/8 E2E PASS at $0 cost |
| **v13.0.0** | 2026-11-17 | "Layer P (oc-proxy) + three-provider rotation" | Layer P added; HF vs Vercel critique (PRO-gated, 402 measured); top-5 alternatives research → Northflank/Render/Oracle rotation; `OC_PROXY_REF` pinned to `2a41370e4ee1…`; 24/24 total assertions PASS |

### Recurring patterns across versions

- **Pinning discipline** — every external dependency gets an exact SHA/ref. CloakBrowser `^0.6.3`, SearXNG source commit, Camofox `1.18.1`, oc-proxy `2a41370e4ee1…`. "Upstream drift can't surprise you" became a stack-level invariant at v11.
- **No-ghost-models** — Layer B's `D_thin` reconcile never sees a model that doesn't actually resolve. Introduced v7 (D_thin), reinforced v13 (the `.invalid` TLD trick for Layer P slots).
- **Free-first** — every layer has a $0 path. Layer D's `glm-5.3-flash-free`, Layer W's MIT-licensed browser-search, Layer P's three free-tier providers. The stack has spent $0 on model inference to date.
- **Anti-hallucination** — Layer W is the engine. The cheapest model becomes reliable when it can ground answers in live web content instead of guessing. The contract test P3 distinguishes 200 (accepted), 429 (accepted but rate-limited), and 403 (rejected) — only the last is FAIL.
- **Composability** — each layer is independent and replaceable. Layer D vs Layer G (both Zen bypass, different throughput). Layer D vs Layer P (same contract, local vs hosted). Layer W via Docker Compose vs Layer W via shell bootstrap.

See [CHANGELOG.md](./CHANGELOG.md) for the full per-version diff log.

---

## Documentation site

The full docs site (this README + INSTALL + QUICKSTART + CHANGELOG + Layer W/P reports + deploy guides) is published at:

**https://imarkytanky.github.io/opencode-unlimited-models/**

It's built from the markdown in this repo using GitHub Pages with Jekyll (default GitHub Pages theme — minimal config, zero build pipeline).

---

## Copy-ready prompt — reproduces the full pipeline

Below is a self-contained prompt that, when given to an AI assistant (Claude, GPT, Gemini, GLM, etc.) with a clean sandbox, will reproduce the v13 stack end-to-end. Copy and paste verbatim.

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

## File layout

```
opencode-unlimited-models/
├── README.md                          ← you are here
├── INSTALL.md                         ← full reference
├── QUICKSTART.md                      ← 60-second path
├── CHANGELOG.md                       ← v1 → v13 diff log
├── CONTRIBUTING.md
├── LICENSE                            ← MIT
├── NOTICE                             ← 7 upstream project attributions
├── package.json                       ← 33 npm scripts (test:w, bench:w, bs:*, example:*)
├── setup.sh                           ← 5-step bootstrap
├── Dockerfile                         ← stack-wide image (Layer W included)
├── docker-compose.yml                 ← `search` profile (searxng + camofox)
│
├── config/
│   └── opencode.json                  ← Layer B (6 providers + providerRotation block)
│
├── oc-proxy/                          ← Layer P
│   ├── README-STACK.md                ← deep dive
│   ├── install-oc-proxy.sh            ← pins upstream to exact SHA
│   ├── make-hf-space.sh               ← assembles portable Dockerfile
│   ├── deploy-oc-proxy-hf.sh          ← HF Space path (PRO-gated today)
│   ├── deploy-oc-proxy-northflank.sh  ← PRIMARY: Northflank Sandbox
│   ├── server.js                      ← adapter (CommonJS shim for upstream)
│   └── package.json
│
├── browser-search/                    ← Layer W (vendored v3.2.1)
│   ├── README-STACK.md
│   ├── data/                          ← i18n
│   ├── docker/                        ← searxng-settings.yml, camofox configs
│   ├── scripts/                       ← camofox launcher, Readability.js
│   └── i18n/                          ← README.{hi,ru,ar,ja,...}.md
│
├── opencode-proxy/                    ← Layer D source (Go)
│   ├── main.go, gate.go, envgate.go
│   ├── musespark.go
│   ├── go.mod, go.sum
│   └── README-upstream.md
│   (opencode-egress-router binary is .gitignored — rebuild with `go build`)
│
├── zen-unlimited-linux/               ← Layer G
├── sphinx-lite/                       ← Layer C
├── cf-worker-proxy/                   ← Layer CF
├── proxy-hunter/                      ← Layer F (2259 SOCKS5 pool)
├── vps-proxy/                         ← Layer F (VPS proxy list)
├── plugins/
│   └── reconcile/                     ← Layer D_thin
│
├── examples/                          ← TypeScript examples
│   ├── index.layer-w.ts               ← Layer W E2E (uses instructions:, not system msg)
│   ├── index.layer-w-compare.ts       ← free vs paid model comparison
│   ├── index.layer-w-multilingual.ts  ← --lang ja/zh support
│   └── index.oc-proxy-agent.ts        ← Layer W → Layer P off-box loop
│
├── verify-a-contract/                 ← Layer A contract verifier
│   └── verify-a-contract.sh           ← 9 assertions (C1-C9)
│
├── kiri/                              ← opencode plugin: kiri (skill registry)
│
├── .github/workflows/
│   └── test.yml                       ← 4 CI jobs + daily 03:30 UTC
│
├── verify-*.sh                         ← contract tests
│   ├── verify-a-contract.sh           ← Layer A + D_thin (9 assertions)
│   ├── verify-oc-proxy.sh             ← Layer P (8 assertions)
│   └── verify-browser-search.sh       ← Layer W (6 assertions)
│
├── benchmark-layer-w.sh               ← Layer W perf baselines
├── test-e2e.sh                        ← 8-path E2E
└── bs-bridge.sh                       ← Layer F → Layer W bridge
```

---

## License

MIT — see [LICENSE](./LICENSE).

Third-party attributions (SearXNG, Camofox, CloakBrowser, browser-search, opencode, oc-proxy) in [NOTICE](./NOTICE). The upstream `oc-proxy` repo has no LICENSE file (all rights reserved); this stack therefore does not redistribute its code — it is cloned at install time into `oc-proxy/upstream/` (gitignored), pinned to a known-good SHA.

---

## Security notes

- **Tokens in chat are exposed.** If you shared a GitHub PAT, HF token, or `oc_sk_` key in a chat, rotate it after the deploy completes. Same protocol for any secret that touched plaintext in transit.
- **GATEWAY_API_KEY on oc-proxy is mandatory** if the service is public. Without it, anyone can use your gateway. The contract test P4 verifies this (no key → 401).
- **Layer F proxies are unauthenticated.** They're intended for outbound rotation only; never expose `proxy-hunter` or `vps-proxy` ports publicly.
- **Layer W's Camofox runs an unpatched Firefox.** Run it in a Docker container (the default `docker-compose --profile search` does this) to limit blast radius.

---

## Acknowledgements

This stack integrates work from many upstream projects. See [NOTICE](./NOTICE) for the full list. Key contributors:

- **opencode.ai** — the Console inference gateway (Layer A) and the Zen free-tier bypass target (Layers D/G/P)
- **SearXNG team** — the metasearch engine (Layer W sub-layer 1)
- **Camofox project** — headless Firefox renderer (Layer W sub-layer 2)
- **CloakBrowser** — bot-detection-evading Chromium (Layer W sub-layer 3, pinned `^0.6.3`)
- **MarkDev11/oc-proxy** — the portable Zen bypass (Layer P upstream, pinned `2a41370e4ee1…`)
- **Johell1NS/browser-search** — the Layer W integration (v3.2.1, MIT)

---

## Citation

If you use this stack in a project, please cite:

```
opencode-unlimited-models v13.0.0 (2026-11-17).
https://github.com/Imarkytanky/opencode-unlimited-models
```
