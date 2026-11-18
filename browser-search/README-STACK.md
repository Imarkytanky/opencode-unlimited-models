# Layer W — browser-search (web research for the stack)

Layer W adds deterministic web search + browsing to the unlimited-models stack.
It is vendored from [Johell1NS/browser-search](https://github.com/Johell1NS/browser-search)
(v3.2.1, MIT) and adapted to this bundle's layout.

## Why this layer exists

The stack solves *model access* (Layers A/B/D/G/F/CF: which model, which route).
It does nothing about *what the model knows*. Layer W closes that gap:

- **SearXNG** — local metasearch engine, JSON API (:8080). Milliseconds-fast.
- **Camofox** — REST-API browser (:9377, Docker). ~90% token savings via
  accessibility snapshots + Readability.js.
- **CloakBrowser** — stealth Chromium (npm). Last resort for
  Cloudflare / Akamai / DataDome-protected sites.

The synergy with the model layers is direct: the cheapest Console-gateway
models (~$0.0006/req) hallucinate the most. browser-search's deterministic
scripts — the model cannot mis-type a command or mis-parse the output —
cancel that weakness. Anti-hallucination is enforced by tooling, not by
model quality, so the stack's cost advantage survives.

## Interconnection with the other layers

| Interconnect | Mechanism | Notes |
| --- | --- | --- |
| Layer W → Layer F/G/CF (egress) | `node scripts/cloak/cloak-fetch.mjs <url> --proxy socks5://127.0.0.1:20128` | Route protected-site browsing through the same proxy pool used for model traffic — one consistent egress IP |
| Layer W → Layer B (opencode.json) | skill dir `.agents/skills/browser-search/` (project-local) or `~/.config/opencode/skills/browser-search` (global) | opencode v2 picks up SKILL.md automatically |
| Layer W config | `SEARXNG_URL`, `CAMOFOX_API_KEY`, `BROWSER_SEARCH_HOME` | All via env; no config-file conflicts with Layers B/C/D |
| Ports | SearXNG :8080, Camofox :9377 | No overlap with D (:8318), G (:20128), CF (:8787) |

## Install (inside this bundle)

```bash
cd browser-search
npm install                       # cloakbrowser + playwright-core
node -e "import('cloakbrowser').then(c => c.ensureBinary())"   # ~700 MB Chromium, one-time
bash scripts/check.sh             # health check
```

Docker users (recommended, full 3-tier): run the SearXNG + Camofox containers
per `docker/setup.md`. No Docker? Tier 1 can run natively:

```bash
git clone --depth 1 https://github.com/searxng/searxng /tmp/searxng-src
pip install -r /tmp/searxng-src/requirements.txt
SEARXNG_SETTINGS_PATH=browser-search/searxng-settings.yml \
  python -m searx.webapp          # settings file ships with this layer
export SEARXNG_URL=http://127.0.0.1:8080
```

## Contract test

```bash
bash verify-browser-search.sh          # full: engine + extract + escalation
bash verify-browser-search.sh --quick  # no engine needed: CloakBrowser tier only
```

6 assertions: engine up, tier-1 search JSON, tier-2 fallback extraction,
tier-3 challenge-site fetch, E2E search→extract loop, health-check accuracy.

## Version pinning rationale

`package.json` pins `cloakbrowser ^0.6.3`. **Do not bump to 0.7.x without
reading this first.**

| Aspect | 0.6.3 (this stack) | 0.7.x (latest) |
| --- | --- | --- |
| License key | **Not required** — the free binary (Chromium 146) downloads without auth | **Required** — `cloakbrowser login` (GitHub OAuth) is mandatory before `ensureBinary()` will succeed |
| Binary | Chromium 146.0.7680.177.5 (Linux x64) | Chromium 156.x |
| Sandbox/CI suitability | Works in headless CI without credentials | Fails `ensureBinary()` with `CloakBrowserLicenseError` until a key is claimed |
| Stability | Stable since 2026-09; matches upstream SKILL.md's documented "free binary" path | Released 2026-11-03; new features (WebRTC via SOCKS5, real window geometry, macOS persona on Linux) |

The skill prints `[cloakbrowser] Update available: 0.6.3 -> 0.7.2. Run: npm
install cloakbrowser@latest` on every invocation — this is informational, not
a security notice. To upgrade:

1. Run `cloakbrowser login` in an interactive shell (GitHub OAuth)
2. Then `npm install cloakbrowser@latest` in `browser-search/`
3. Re-run `bash verify-browser-search.sh` — the contract must still PASS
4. If the key flow doesn't fit your environment, stay on `^0.6.3` (current pin)

**Stack policy:** the bundled `package.json` stays on `^0.6.3` until upstream
SKILL.md changes its documented "free binary, no license key" path. The pin
is intentional, not stale.
