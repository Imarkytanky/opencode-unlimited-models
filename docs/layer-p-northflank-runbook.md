# Layer P Runbook — oc-proxy on Northflank (LIVE)

**Status:** DEPLOYED AND LIVE — 2026-11-18
**Provider:** Northflank Sandbox (free tier, PRIMARY in the three-provider rotation)
**Public URL:** https://web--oc-proxy--kn9sfsrmdk4x.code.run
**API base:** https://web--oc-proxy--kn9sfsrmdk4x.code.run/v1
**Upstream pin:** `2a41370e4ee121796bdbf65a2efeae99e80b58d1` (byte-exact, no drift)

---

## Live deployment record (ledger)

| Field | Value |
|---|---|
| Project | `default` (free Sandbox allows exactly 1 project) |
| Service | `oc-proxy` (`serviceType: combined` — build + deploy in one) |
| Cluster | `nf-us-central` |
| Deployment plan | `nf-compute-20` (0.2 vCPU / 512 MB / $5.4/mo — inside the $20/mo free allowance) |
| Build plan | `nf-compute-400-16` (used at build time only) |
| Build ID | `excited-voyage-4622` |
| Build SHA | `7f339e9114fb30625d6c080e3d5a24969335661e` (the dist push) |
| Build status | SUCCESS — "Image successfully built" (~15 s after creation) |
| Deployment status | COMPLETED |
| Public port | `p1` / `web` / internal 7860 / public HTTPS auto-TLS |
| Dist repo | https://github.com/Imarkytanky/oc-proxy-northflank-dist |
| Secret group | `oc-proxy-secrets` (environment type, priority 0, unrestricted — applies project-wide) |

---

## Validation evidence (per verification-before-completion: fresh, run 2026-11-18)

| Check | Command | Expected | Actual | Verdict |
|---|---|---|---|---|
| V1 health | `GET /api/health` | 200 | 200, `status: ok` | PASS |
| V2 models | `GET /v1/models` | 200, ≥15 ids | 200, 20 ids | PASS |
| V3 auth gate | `POST /v1/chat/completions` no key | 401 | 401 | PASS |
| V4 fingerprint | `POST /v1/chat/completions` with key | 200 or 429 (not 403) | 429 `FreeUsageLimitError` | PASS |

V4's 429 is the **contract-test P3 PASS case**: fingerprint accepted by upstream, free quota exhausted. A 403 `FreeTierError` would mean fingerprint REJECTED — that never happened.

---

## Live model catalog (upstream rotation detected)

**`glm-5.3-flash-free` is DEPRECATED upstream** — live probe returned:
```
410 {"error":{"type":"ModelDeprecated",
     "message":"Model glm-5.3-flash-free has been deprecated. Use deepseek-v4.1-flash-free instead."}}
```

Layer B was updated accordingly: the primary provider now exposes `deepseek-v4.1-flash-free` (the live replacement). The 22-id catalog from 2026-11-17 has rotated to 20 ids at 2026-11-18. The `*-free` suffix allowlist in oc-proxy handles rotation automatically — only docs/Layer B need updating, and only for the *default* model entry.

---

## API gotchas discovered during execution (rulings ledger)

These are the deviations from the pre-written deploy script, discovered by probing the live API (per investigate-first). Each is a **Ruling** per executing-plans: the plan's step was adjusted to what the API actually requires.

| # | Plan said | API actually required | Ruling |
|---|---|---|---|
| R1 | `GET /v1/user` for identity | No `/v1/user` endpoint (404 route-not-found); identity visible in JWT only | Skip identity check; verify via `GET /v1/projects` returning 200 |
| R2 | Response shape `{projects: []}` | Shape is `{data: {...}, pagination: {...}}` | All list reads go through `data` |
| R3 | Create project `oc-proxy-probe` | Free Sandbox allows **exactly 1 project** — got 409 `Maximum number of free projects reached` | Reuse the existing `default` project |
| R4 | Service payload with `storage.ephemeralStorage.storageSize: 2048` | Allowed sizes: 16384/32768/65536/131072/262144/524288 (MB) | Omit storage entirely (defaults apply); build storage if specified must be ≥16384 |
| R5 | Description with em-dash `—` | Description pattern `[a-zA-Z0-9.,?\s\\/'"()\[\];`%^&*\-_:!]` — no em-dash | Use plain ASCII `-` in descriptions |
| R6 | Secret variables via `variables: [{key,value,type}]` array | Silently dropped on create; `secrets.variables` must be a **flat map of plain strings** via PATCH: `{"secrets":{"variables":{"KEY":"value"}}}` | PATCH after create; no `type` field (everything string) |
| R7 | `POST /services/{id}/builds` to trigger build | Combined services auto-build on creation — build was already SUCCESS by the time we looked | No trigger needed; check `GET /services/{id}/build` for build list |
| R8 | `POST /services/{id}/secrets/{gid}/link` | No such route (404). With `restrictions.restricted: false`, the secret group applies **project-wide automatically** — no explicit link step | Create group unrestricted → vars reach all services in the project after restart |
| R9 | `POST /services/{id}/restart` | Works as documented (200, empty data) | Restart confirmed needed for env-var pickup |
| R10 | Layer B default model `glm-5.3-flash-free` | Upstream deprecated it (410 ModelDeprecated) — replacement `deepseek-v4.1-flash-free` | Layer B primary now exposes deepseek-v4.1 only |

**Deploy script impact:** `oc-proxy/deploy-oc-proxy-northflank.sh` needs these fixes before its next run. The corrections below are already applied inline during this run; the script itself still carries the pre-investigation assumptions (marked TODO).

---

## How to operate the deployment

### Environment variables (client side)

```bash
export OC_PROXY_NF_KEY='oc_sk_1141eb6f6a769f7aae8ba50d667c264acc0b2d51'
export OC_PROXY_BASE='https://web--oc-proxy--kn9sfsrmdk4x.code.run/v1'
```

(Layer B reads `{env:OC_PROXY_NF_KEY}`.)

### Quick smoke test

```bash
curl -s "$OC_PROXY_BASE/v1/models" \
  -H "Authorization: Bearer $OC_PROXY_NF_KEY" | python3 -m json.tool | head -20

curl -s -X POST "$OC_PROXY_BASE/v1/chat/completions" \
  -H "Authorization: Bearer $OC_PROXY_NF_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash-free","messages":[{"role":"user","content":"hi"}]}'
```

### Redeploy after an upstream re-pin

1. `OC_PROXY_REF=<new-sha> bash oc-proxy/install-oc-proxy.sh`
2. `bash oc-proxy/make-hf-space.sh --check` (re-assembles dist)
3. Push dist contents to `Imarkytanky/oc-proxy-northflank-dist` (same commit-style as this run)
4. Northflank auto-builds on push; deployment re-runs automatically (combined service)
5. Watch: `GET /v1/projects/default/services/oc-proxy` → `status.build.status` then `status.deployment.status`

### Cost model (free Sandbox)

| Item | Rate | 24/7 usage | % of $20 allowance |
|---|---|---|---|
| oc-proxy deployment (`nf-compute-20`) | $0.008/hr | ~$5.40/mo | 27% |
| Build (occasional redeploys) | metered per build | negligible | <2% |
| **Headroom** | | | **~71%** — enough for the Render fallback later if it were on the same account (it won't be; Render is a separate provider) |

---

## Security advisory (act on this)

The Northflank API token was shared in plaintext in chat and is recorded in this session. Rotate it now:

1. Northflank → Account → API tokens → delete the `opencode` token
2. Create a replacement scoped to: Projects RW (default project only), Services RW, Secrets RW
3. Update any local scripts that referenced the old token

Same advisory applies to the GitHub PAT and the HF token shared earlier in this conversation if not yet rotated.

The `GATEWAY_API_KEY` value was also printed in this session. It protects the public endpoint (401 without it — verified V3). Rotate it by PATCHing the secret group:

```bash
NEW_KEY="oc_sk_$(openssl rand -hex 20)"
curl -X PATCH -H "Authorization: Bearer $NF_TOKEN" -H "Content-Type: application/json" \
  -d "{\"secrets\":{\"variables\":{\"GATEWAY_API_KEY\":\"$NEW_KEY\"}}}" \
  https://api.northflank.com/v1/projects/default/secrets/oc-proxy-secrets
# then: POST /v1/projects/default/services/oc-proxy/restart
# and update OC_PROXY_NF_KEY wherever it's exported
```

---

## Next steps (rotation slots 2 and 3)

| Priority | Provider | Status | Blocked on |
|---|---|---|---|
| 1 PRIMARY | Northflank | **LIVE** — | — |
| 2 FALLBACK | Render | Not deployed | `deploy-oc-proxy-render.sh` (mirror of NF script with Render API); needs the R1-R10 equivalents mapped for Render's API |
| 3 OFF-BOX | Oracle + Coolify | Not deployed | OCI signup (card required), then Coolify install on the free ARM VM — runs Layer W too |

The Layer B `providerRotation` block already has all three slots; only the primary's `live` flag is true. Failover order: northflank → render → oracle.
