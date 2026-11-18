# Changelog

All notable changes to this bundle are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [14.0.0] — 2026-11-17

### Added
- **Layer P — oc-proxy portable Zen bypass** (`oc-proxy/`). Integration of
  [MarkDev11/oc-proxy](https://github.com/MarkDev11/oc-proxy) — a thin
  OpenAI-compatible proxy for the opencode.ai free tier — packaged for
  **Hugging Face Spaces** (per upstream README's own recommendation over
  Vercel: no `maxDuration` mid-token hard-kill), plus any VPS/local machine.
  Functionally a remote-capable sibling of Layer D. Validated 8/8 contract
  assertions including **live fingerprint proof** (429 FreeUsageLimitError
  = accepted; 403 FreeTierError would mean rejected).
- **Standalone adapter** (`oc-proxy/server.js`, this stack's code). Gives the
  upstream Vercel-style handlers (`res.status().json()`) a plain-Node http
  server — runs unmodified on HF Spaces (Docker SDK, port 7860), VPS, or
  locally. Routes: `/v1/models`, `/v1/chat/completions` (stream + non-stream),
  `/api/health`, `/api/stats`, monitor dashboard at `/`. Zero npm dependencies.
- **HF Space packager** (`oc-proxy/make-hf-space.sh`). Assembles
  `dist/oc-proxy-hf-space/` — complete ready-to-push Space with Dockerfile
  (node:20-slim, EXPOSE 7860, CMD node server.js), README frontmatter
  (sdk: docker, app_port: 7860), upstream code, adapter, and provenance file.
- **Pinned installer** (`oc-proxy/install-oc-proxy.sh`). Clones upstream at
  install time into `oc-proxy/upstream/` (gitignored), records provenance,
  verifies syntax via upstream's own `npm run check`. Upstream has **no
  LICENSE file** — its code is therefore NOT redistributed in this tarball;
  only this stack's adapter/tooling ships.
- **Layer P contract test** (`verify-oc-proxy.sh`, stack root). 8 assertions:
  install/syntax, boot+health, live models, live fingerprint proof, auth
  enforcement (401 without key), dashboard, HF packaging. Model selection is
  **catalog-driven** (picks from the live /v1/models response) to survive
  upstream model rotation (muse-spark retired 2026-11; catalog now lists 22
  free ids incl. glm-5.3-flash-free, mimo-v2.6-flash-free, deepseek-v4.1-flash-free).
- **CI**: Layer P structural check (per-PR, no upstream clone needed) +
  daily `layer-p-full` job (clone pinned upstream → contract test → HF
  packaging check). Stack now has 5 CI jobs.
- **setup.sh step 4f** — optional oc-proxy install + boot smoke test.
- **bun run shortcuts**: `oc:install`, `oc:dev`, `oc:test`, `oc:test:quick`,
  `oc:hf`. E2E gains `--skip-p` flag and a Layer P block (10 layers total).
- **Layer P docs**: `oc-proxy/README-STACK.md` (Layer D vs P comparison,
  HF deploy guide, Layer B provider snippet), INSTALL.md §9, QUICKSTART
  advanced path, NOTICE entry.

### Fixed
- **CommonJS scope regression**: the stack root's `"type": "module"` made
  `oc-proxy/server.js` load as ESM (`require is not defined`). Fixed with a
  scoped `oc-proxy/package.json` (`"type": "commonjs"`) — verified in CI
  structural check.

### Notes
- Upstream drift observed: the live free catalog no longer includes
  muse-spark (README's example model); the proxy's `*-free` suffix allowlist
  handles rotation correctly — only upstream docs are stale.

## [13.0.0] — 2026-11-17

### Added
- **Performance benchmark** (`benchmark-layer-w.sh`). Measures latency (median +
  P90) and success rate for each Layer W tier: SearXNG search (cold + warm),
  CloakBrowser fetch (example.com + cloudflare.com challenge site), smart-extract
  auto-escalation, and bridge fetch via Layer F proxy. 3 runs per test by default.
  Two `bun run` shortcuts: `bench:w` (full, ~3 min) and `bench:w:quick` (no
  engine, ~30 s). Reference numbers documented in INSTALL.md §8.
- **NOTICE file** — attribution for all vendored/upstream code: browser-search
  (MIT), SearXNG (AGPL-3.0, referenced), Camofox (Docker image, referenced),
  CloakBrowser (npm + proprietary Chromium binary), opencode-egress-router
  (Magiszonekk), zen-unlimited (yuhp), SphinX (adapted). Clarifies what's
  vendored vs. referenced vs. adapted.
- **Two new Layer W examples**:
  - `examples/index.layer-w-compare.ts` — same researched source text fed to two
    models (free `glm-5.3-flash-free` vs paid `kimi-k3`), side-by-side comparison
    of grounded answers. Cost: ~$0.0006 (one paid call).
  - `examples/index.layer-w-multilingual.ts` — non-English research with `--lang`
    flag (default: Japanese). Proves SearXNG's multi-engine language support and
    the model's ability to answer in the user's language. Cost: $0.
- **Layer W in Dockerfile** — `browser-search/` is now COPYed into the container
  image with `npm install --omit=dev` at build time. The CloakBrowser Chromium
  binary (~700 MB) is intentionally NOT pre-downloaded to keep the image small;
  users run `docker exec ... node -e "import('cloakbrowser').then(c=>c.ensureBinary())"`
  after first start, or use `docker compose --profile search up -d` for the
  separate SearXNG + Camofox containers. EXPOSE directives updated to include
  :8080 and :9377.
- **CI structural check expanded** — now verifies 18 invariants (was 11):
  benchmark-layer-w.sh, NOTICE, all 3 Layer W examples, Dockerfile Layer W
  integration, package.json shortcuts (`test:w`, `bench:w`, `bs:install`).
  Still runs in <1s per PR.
- **CI `layer-w-full` job expanded** — now includes a benchmark step
  (`benchmark-layer-w.sh --runs 3`) alongside the contract test and bridge
  smoke test. Benchmark TSV artifacts uploaded for trend tracking.
- **CI badges in README** — Layer W version badge, CI status badge, MIT license
  badge.
- **CloakBrowser version-pinning rationale** documented in
  `browser-search/README-STACK.md`. CloakBrowser 0.7.x requires a license key
  (free, via `cloakbrowser login` GitHub OAuth), which breaks headless/CI
  installs. The stack stays on `^0.6.3` (key-free, stable since 2026-09) until
  upstream SKILL.md changes its documented "free binary" path. The "Update
  available: 0.6.3 → 0.7.2" notice the skill prints is informational, not a
  security issue.

### Security
- **browser-search audit** (`bash browser-search/scripts/audit.sh`): 9 PASS,
  2 WARN, 0 FAIL, 0 high/critical CVEs. Warnings are upstream issues (caret
  ranges in package.json, Docker example binding) — non-blocking.
- **Secret scan**: 0 secrets found across all source files. Only POSIX-mandated
  `mktemp XXXXXX` templates matched the placeholder scan.

## [12.0.0] — 2026-11-17

> Lineage: v11.0.0 (earlier same-day pass) adopted browser-search as **Layer S**
> (`skills/browser-search/`, doc-level verification, tiers 1+2 SKIP without
> Docker). v12.0.0 reconciles and deepens that work: renamed to **Layer W**
> (web research — search + browse + bypass), moved to the stack root
> (`browser-search/`), added **live 6/6 contract validation** including a
> native (no-Docker) SearXNG engine path, and merged v11's Layer F bridge,
> docker profile, and E2E block into this layout. Supersedes
> `docs/browser-search-integration.md` (removed — replaced by the
> `browser-search-integration-report.md` shipped alongside this bundle).

### Added
- **Layer W — browser-search web research skill** (`browser-search/`, vendored
  from [Johell1NS/browser-search](https://github.com/Johell1NS/browser-search)
  v3.2.1, MIT). Three-tier deterministic web access for opencode agents:
  SearXNG metasearch (JSON), smart-extract URL extraction with automatic
  escalation, CloakBrowser stealth Chromium for Cloudflare/Akamai/DataDome-
  protected sites. Anti-hallucination by design: the model cannot mis-type a
  command or mis-parse output, so even the cheapest Console model researches
  the live web reliably. Five-dimension integration analysis completed —
  6/6 contract assertions PASS (see `verify-browser-search.sh`).
- **Layer W contract test** (`verify-browser-search.sh`). 6 assertions:
  W1 engine reachability, W2 tier-1 search JSON, W3 tier-2 CloakBrowser
  extraction, W4 challenge-site fetch, W5 E2E search→extract anti-hallucination
  loop, W6 check.sh health accuracy. `--quick` runs the CloakBrowser tier only
  (~20 s, no engine needed). Full mode auto-launches a native (non-Docker)
  SearXNG from `$SEARXNG_SRC` when no engine is running.
- **Native SearXNG support** (`browser-search/searxng-settings.yml` +
  install recipe in `browser-search/README-STACK.md`). The stack can run
  SearXNG without Docker: `pip install -r` the engine repo's requirements and
  `python -m searx.webapp` with the shipped settings (JSON format enabled,
  limiter off, bound to 127.0.0.1). Validated against searxng master
  (2026-10) — 20 results/query, multi-engine.
- **setup.sh step 4e** — optional interactive Layer W install: npm deps +
  `ensureBinary()` Chromium download (~700 MB one-time) + skill symlink into
  `~/.config/opencode/skills/browser-search` (auto-picked-up by opencode v2).
  Opt out with `--no-browser-search`.
- **Egress interop**: `cloak-fetch.mjs --proxy socks5://127.0.0.1:20128` routes
  protected-site browsing through the same proxy pool as model traffic
  (Layer G sing-box / Layer F VPS fleet / Layer CF Workers). Flag path verified
  end-to-end (graceful `ERR_PROXY_CONNECTION_FAILED` when no proxy is up).
- **Layer F→W bridge** (`bs-bridge.sh`, restored from v11 and adapted to the
  Layer W layout). Routes CloakBrowser through the stack's proxy fleet: source
  order `BS_PROXY` → `vps-proxy/proxies.txt` → `proxy-hunter/custom-proxies.txt`
  → direct fallback. Commands: `status` / `next` / `fetch [--direct] <url>`.
  Verified live: status reporting + direct fallback fetch (917 chars).
- **Layer W docker services** (docker-compose.yml `search` profile, restored
  from v11): `searxng` (:8080, config `docker/searxng/settings.yml` — limiter
  off, JSON format on, `$(env SEARXNG_SECRET)`) and `camofox` (:9377, pinned
  image 1.18.1 with upstream's security flags: 127.0.0.1 bind, tmpfs,
  mem/cpu/pids caps, no-new-privileges, core=0, log rotation).
  `docker compose --profile search up -d`.
- **Unified E2E Layer W block** (test-e2e.sh, merged from v11's Layer S block):
  6 checks — SKILL.md validity, cloakbrowser module, Chromium binary, live
  stealth fetch (full mode), SearXNG tier-1 HTTP probe, bridge presence.
  New `--skip-w` flag; `--layer w` for the Layer W block only.

### Integration verdict (five dimensions)
| Dimension | Result |
| --- | --- |
| Compatibility | Full — MIT + MIT, Node 20.19+ (stack uses 24.x), no port overlap (:8080/:9377 vs :8318/:20128/:8787), zero config-file conflicts |
| Relevance | High — fills the stack's missing capability (live web research); complementary to model layers, no overlap |
| Interoperability | Full — SEARXNG_URL/env config, SOCKS5 egress sharing, skill-dir conventions (project + global), HTTP-probe health check detects Docker AND native engines |
| Interconnected clarity | High — Layer W has one doc (README-STACK.md), one contract test, one setup hook; ports/env/deps documented per layer |
| Synergy | Strong — cheapest-model cost advantage preserved by anti-hallucination tooling; single egress for model + browsing traffic |

## [10.0.0] — 2026-11-15

### Added
- **Layer CF — Cloudflare Workers proxy** (`cf-worker-proxy/`). HTTP forward proxy
  running on Cloudflare's edge (300+ locations). Each request automatically hits
  a different edge IP → automatic IP rotation without any VPS. 100K requests/day
  free. No credit card needed. Deploys in 30 seconds with `npx wrangler deploy`.
  Validated: proxied 53 opencode Console models + kimi-k3 chat completion through
  the CF Hong Kong edge (HKG). `X-Proxy-Edge` header proves edge routing.
- **Unified E2E test** (`test-e2e.sh`). Validates all 8 layers in one command:
  B (config), A (Console), D (proxy), D_thin (plugin), G (zen-unlimited),
  F (proxy-hunter), CF (Workers), and the 9/9 contract test. Supports `--quick`
  (skips CF + G for ~15s CI runs), `--layer <name>`, `--skip-cf`, `--skip-g`.
- **VPS proxy fleet guide** (`vps-proxy/FREE-VPS-PROXY-GUIDE.md`, 10KB). Documents
  10 free-tier cloud VPS providers (Oracle, GCP, AWS, Azure, Fly.io, Koyeb, Render,
  Northflank, GitHub Codespaces, Cloudflare Workers) with step-by-step deployment
  instructions for each. Includes architecture diagram and 3 integration options.
- **VPS proxy automation** (`vps-proxy/deploy-proxy.sh` + `rotate-egress.sh`).
  `deploy-proxy.sh` SSHes into any VPS, installs sing-box, configures SOCKS5,
  starts the service, opens the firewall, detects public IP, prints integration
  instructions. `rotate-egress.sh` manages the fleet: list, add, remove, test
  (TCP + SOCKS5 handshake), generate (outputs for zen-unlimited/ProxyPool/Magiszonekk),
  disable-public (disables public proxy scanning).
- **Proxy-hunter CLI** (`proxy-hunter/proxy-hunter.py` + `feed-proxies.sh`). CLI
  port of the cmalf.github.io/web-tools/proxy-hunter/ browser tool. Fetches from
  5 public feeds (Roosterkid, TheSpeedX, Hookzof), dedupes, outputs TXT/JSON/YAML.
  Fetched 2,733 SOCKS5 proxies in testing.
- **zen-unlimited Linux port** (`zen-unlimited-linux/`). Reverse-engineered the
  Windows-only d1alect-tech/opencode-zen-unlimited using the leanrea REA
  methodology. Patched setup.ts to call the new bash installer on Linux. Created
  systemd user units (oc-singbox/oc-relay/oc-gateway/oc-watchdog) + get-singbox.sh
  for Arch/Omarchy. Boot-tested: gateway returns 24 models (dual-id format),
  contract test 9/9 PASS.
- **kiri integration** (`kiri/` + `Dockerfile` + `docker-compose.yml`). Containerized
  the entire stack via kiri (fast Docker Desktop alternative, 22ms start). Dockerfile
  builds a single image with all layers. supervisord manages 3 daemons.
  docker-compose.yml exposes :8318 + :20128.

### Changed
- Public proxy scanning **disabled by default**. ProxyPool's 422-source scan is
  set to `scanMode: "off"`. The `vps-proxy/rotate-egress.sh disable-public` command
  applies this. Personal VPS proxies are now the primary egress strategy.
- `setup.sh` — added steps 4b (zen-unlimited), 4c (proxy-hunter), 4d (VPS proxy
  fleet). Added `--stop` flag to kill all daemons. Added `--status` flag.
- `package.json` — version 10.0.0. Added `test:e2e`, `cf:dev`, `cf:deploy`,
  `vps:list`, `vps:add`, `vps:test`, `vps:generate` scripts.
- `.gitignore` — added `!.env.local.example` exception (was being excluded by
  the `.env*` glob). Added entries for zen-unlimited, proxy-hunter, vps-proxy,
  kiri, and CF Worker artifacts.
- All hardcoded `/home/z/` paths in sphinx-lite scripts replaced with `$HOME`
  and bundle-relative resolution (6 files fixed).

### Verified (8/8 E2E + 9/9 contract)
- Layer B: config valid, 3 providers + 1 plugin
- Layer A: opencode Console reachable (53 models)
- Layer D: opencode-egress-router :8318 (HTTP 200, free-tier Zen)
- Layer D_thin: reconcile plugin 7/7 unit tests
- Layer G: zen-unlimited gateway :20128 (health: ok, 24 models)
- Layer F: proxy-hunter fetched 2,733 SOCKS5 proxies
- Layer CF: Cloudflare Workers :8787 (edge: HKG/HK, 53 models proxied)
- Contract: 9/9 assertions (C1-C9) PASS

## [4.0.0] — 2026-11-14

### Added
- **Stage 2 (Layer D_thin) — COMPLETE.** New `plugins/reconcile.ts` opencode
  v2 plugin implementing the disable-not-delete ghost reconciliation contract.
  Periodically fetches each provider's `/v1/models` catalog and sets
  `enabled: false` on models absent from the gateway — never deletes them,
  so B's overrides survive gateway outages.
- **2 new contract assertions (C8, C9)** in `verify-a-contract.sh`:
  - C8: ghost model (B-written, NOT in gateway catalog) is `enabled: false`
  - C9: target model (B-written, present in gateway) stays `enabled: true`
  - Activated via new `--simulate-d-thin` flag. Full B+A+D_thin contract
    now 9/9 PASS against both the mock and real opencode Console gateways.
- **GitHub Actions CI workflow** at `.github/workflows/test.yml` — 3 jobs,
  22 steps: bash syntax, selftest, smoke, mock contract (A-only + A+D_thin),
  reconcile plugin unit tests, real-gateway contract (skipped cleanly when
  `OPENCODE_API_KEY` secret isn't set).
- **`package.json`** at the bundle root — pins `ai@^7.0.173`,
  `@ai-sdk/openai-compatible@^3.0.92`, `@opencode/plugin@^2.3.0`. Adds
  `bun run` shortcuts: `test:all`, `test:contract`, `test:plugin`,
  `launch:unified`, `install:sphinx-lite`, etc.
- **`.gitignore`** covering `.env*`, `node_modules`, test artifacts,
  editor files, etc. — prevents accidental secret/key commits.
- **`setup.sh`** — one-shot installer that runs all 5 setup steps
  (bun install, .env.local, launch proxy, install sphinx-lite, run contract
  test). Supports `--yes` (non-interactive) and `--no-sphinx` flags.
- **`QUICKSTART.md`** — 1-page minimal path (60 seconds to a working setup),
  separate from the full INSTALL.md reference.
- **`CHANGELOG.md`** — this file.

### Changed
- `verify-a-contract/README.md` — assertion table expanded from 7 to 9 rows;
  documents the `--simulate-d-thin` flag and the C8/C9 statuses (`disabled` /
  `preserved`).
- `verify-a-contract.sh` — added `--simulate-d-thin` flag, `GHOST_ID` env
  var, `SIMULATE_D_THIN` config. The B-layer config template now includes
  a 3rd "ghost" model entry (in addition to TARGET_ID) so D_thin has
  something to disable. Verdict JSON now includes `ghost_id`,
  `simulate_d_thin`, and `contract` field reads:
  `"A only adds, never overwrites; D_thin disables, never deletes"`.
- Top-level `README.md` — opens with "9/9 contract assertions PASS"
  and a Stage 2 COMPLETE callout. Mentions the CI workflow.
- `INSTALL.md` — staged rollout table updated; Stage 2 marked DONE,
  includes instructions for running the reconcile plugin unit tests
  and the new C8/C9 contract test path.
- `config/opencode.json` — now includes the `plugins` array registering
  `./plugins/reconcile` with options (`intervalMs`, `disableMissing`,
  `userAgent`).

### Verified
- **Selftest**: assertion engine PASS fixture → 0, FAIL fixture → 1
- **Smoke**: mock gateway boots, /health 200, /v1/models auth enforced (401 without Bearer)
- **Mock + A-only**: 7/7 active + 2 skipped (C8/C9 not activated) = 9 total
- **Mock + A+D_thin**: 9/9 PASS
- **Real gateway + A-only**: 7/7 + 2 skipped (52-model catalog)
- **Real gateway + A+D_thin**: 9/9 PASS (kimi-k3 B-explicit + glm-5.3-flash-free control + legacy-removed-model ghost)
- **Reconcile plugin unit tests**: 7/7 PASS, 24 expect() calls, 11ms
- **TypeScript compile**: `bun build --no-bundle reconcile.ts` exits 0
- **All 4 examples**: compile + run, return text (zen-free via proxy = $0, opencode via direct = $0.0006, workaround via Z.AI = $0, gateway expected to fail with FreeTierError)
- **Clean-extraction test**: v4 tarball extracted to /tmp, all tests pass without sandbox-specific state

## [3.0.0] — 2026-11-14

### Added
- **Layer D_thin — `plugins/reconcile.ts`** opencode v2 plugin (~200 lines)
  implementing the disable-not-delete ghost reconciliation contract.
- **`plugins/reconcile.test.ts`** — 7 unit tests (T1-T7) covering the
  contract, dry-run mode, gateway fetch failure, provider filtering, and
  built-in provider skipping.
- **`opencode.json` updated** to register the reconcile plugin via the
  `plugins` array.

### Changed
- `README.md` and `INSTALL.md` updated to document Layer D_thin and the
  staged rollout (Stage 2 now marked as DONE in this bundle).

## [2.0.0] — 2026-11-14

### Added
- **Layer C — sphinx-lite integration.** New `sphinx-lite/` directory
  with a sandbox-aware installer for the SphinX
  (ShadowySphinX/Opencode-Unlimited-Limit-Bypass-) components that work
  without root, `/dev/net/tun`, or `warp-cli`.
- **`launch-unified.sh`** — unified launcher that detects what's installed
  and starts both sphinx-lite guard + opencode-egress-router proxy.
- **Linux patches to SphinX source**: `ouc_common.py:acquire_mutex()`
  patched with an `fcntl.flock` fallback (was `ctypes.windll.kernel32`,
  Windows-only). `zen_guard.py:_rotate()` patched to dispatch auto-resume
  even without `warp-cli`. Path constants patched to use
  `~/.local/share` instead of Windows-style `AppData\Local` when
  `LOCALAPPDATA` is unset.
- **`sphinx-compatibility-plan.md`** — full compatibility analysis of
  the SphinX tool with opencode v2 (file:line evidence that the tool was
  built against V2: `auto_resume.py:49` queries the `session_v2` table
  which is V2-specific).

### Verified
- **End-to-end chain**: shim wraps opencode → guard detects wall in log
  → auto_resume queries session_v2 → returns "No active session" (correct
  in sandbox without a running TUI) → proxy returns text for free-tier
  model — all 4 layers (B+A+D+C) operational.

## [1.0.0] — 2026-11-14

### Added
- **Initial bundle release.** Layers B (config) + A (discovery) + D
  (proxy) operational. Contract test (`verify-a-contract.sh`) validates
  7/7 assertions (C1-C7) against the real opencode Console gateway
  (52-model catalog).
- **`opencode-egress-router`** Go binary (pre-built x86-64 Linux) — the
  Magiszonekk/opencode-proxy that rewrites free-tier Zen requests to pass
  the "from-within-OpenCode" gate (TLS fingerprint spoofing, opencode-format
  session ID, bash/read tool stubs, `<env>` block injection).
- **`verify-a-contract.sh`** — 4-mode contract verifier (selftest / smoke /
  simulate / full) with 7 assertions (C1-C7). Supports `--gateway-url`
  for real gateways, `--rich-metadata` for C6/C7 enrichment assertions,
  `--keep` for artifact preservation, auto schema detection (v1/v2).
- **4 AI SDK examples**: `index.ts` (Vercel AI Gateway), `index.opencode.ts`
  (opencode Console paid), `index.zen-free.ts` (Zen free via proxy),
  `index.workaround.ts` (Z.AI fallback).
- **`config/opencode.json`** — dual-provider config (5 paid + 12 free models).
- **`.env.local.example`** — template (no real keys).
- **`INSTALL.md`** — full reference with 7 numbered steps + troubleshooting.
- **`README.md`** — architectural overview with ASCII diagram.

### Verified
- **Contract**: 7/7 PASS against real opencode Console
  (`https://opencode.ai/inference/v1`, 52-model catalog)
- **Free-tier execution**: `glm-5.3-flash-free` returns text via proxy,
  `billing_source: free`, cost $0
- **Paid execution**: `kimi-k3` returns text via direct gateway,
  `billing_source: balance`, cost ~$0.0006
