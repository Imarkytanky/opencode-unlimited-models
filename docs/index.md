# Documentation Index

Full documentation for the opencode-unlimited-models v13.0.0 stack. Each link below is a deep dive into one aspect of the stack.

## Getting started

- [Home (README)](../) — what this is, 60-second quick start, architecture overview
- [QUICKSTART.md](../QUICKSTART.md) — minimal path, 60 seconds to first answer
- [INSTALL.md](../INSTALL.md) — full reference, layer-by-layer install, troubleshooting
- [CHANGELOG.md](../CHANGELOG.md) — version-by-version diff log (v1 → v13)
- [CONTRIBUTING.md](../CONTRIBUTING.md) — how to contribute
- [LICENSE](../LICENSE) — MIT
- [NOTICE](../NOTICE) — third-party attributions

## Layer documentation

- [Layer A — opencode Console discovery](https://opencode.ai/docs)
- [Layer B — `config/opencode.json`](../config/opencode.json) — 6 providers + `providerRotation` block
- [Layer C — sphinx-lite](../sphinx-lite/)
- [Layer D — opencode-egress-router](../opencode-proxy/README-upstream.md) — Layer D source (Go)
- [Layer D_thin — reconcile plugin](../plugins/reconcile/)
- [Layer F — proxy-hunter + vps-proxy](../proxy-hunter/) — outbound IP rotation
- [Layer G — zen-unlimited-linux](../zen-unlimited-linux/)
- [Layer CF — Cloudflare Workers proxy](../cf-worker-proxy/)
- [Layer W — browser-search v3.2.1](../browser-search/README-STACK.md) — SearXNG → Camofox → CloakBrowser
- [Layer P — oc-proxy](../oc-proxy/README-STACK.md) — three-provider rotation

## Deploy guides (Layer P)

- [Northflank step-by-step guide](../download/northflank-deploy-guide.md) — PRIMARY path, free Sandbox tier
- [HF vs Vercel comparison](../download/oc-proxy-hf-vs-vercel-comparison.md) — measured HF 402 on free account; PRO-gated today
- [Top 5 free alternatives to HF Spaces and Vercel](../download/free-hf-vercel-alternatives-top5.md) — research with confidence scores

## Validation & testing

- `bash verify-a-contract.sh` — Layer A + D_thin (9 assertions)
- `bash verify-oc-proxy.sh` — Layer P (8 assertions)
- `bash verify-browser-search.sh` — Layer W (6 assertions)
- `bash benchmark-layer-w.sh` — Layer W performance baselines
- `bash test-e2e.sh` — 8-path end-to-end
- [.github/workflows/test.yml](../.github/workflows/test.yml) — CI: 4 jobs + daily 03:30 UTC schedule

## Examples

- [`examples/index.layer-w.ts`](../examples/index.layer-w.ts) — Layer W E2E
- [`examples/index.layer-w-compare.ts`](../examples/index.layer-w-compare.ts) — free vs paid model
- [`examples/index.layer-w-multilingual.ts`](../examples/index.layer-w-multilingual.ts) — `--lang ja/zh`
- [`examples/index.oc-proxy-agent.ts`](../examples/index.oc-proxy-agent.ts) — Layer W → Layer P off-box loop

## Reports

- [`v12-end-to-end-validation-report.md`](../download/v12-end-to-end-validation-report.md) — 8/8 PASS validation
- [`browser-search-integration-report.md`](../download/browser-search-integration-report.md) — 5-dimension compatibility audit

## External

- [Source repository](https://github.com/Imarkytanky/opencode-unlimited-models)
- [Issue tracker](https://github.com/Imarkytanky/opencode-unlimited-models/issues)
- [GitHub Actions CI](https://github.com/Imarkytanky/opencode-unlimited-models/actions)
