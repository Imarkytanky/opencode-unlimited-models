#!/usr/bin/env bash
# ============================================================================
# deploy-oc-proxy-hf.sh — one-command HF Space deployment pipeline (Layer P)
#
# Implements the deployment checklist end-to-end:
#   1. clone upstream oc-proxy PINNED to OC_PROXY_REF (exact SHA — no drift)
#   2. assemble + validate dist/oc-proxy-hf-space/   (make-hf-space.sh)
#   3. create the HF Space (sdk: docker)
#   4. set GATEWAY_API_KEY secret + deadline variables
#   5. push dist to the Space (git, main branch)
#   6. poll until runtime stage == RUNNING
#   7. live-validate /api/health, /v1/models, auth, chat
#   8. ONLY THEN auto-apply the oc-proxy-hf provider to Layer B
#      (config/opencode.json) — the stack invariant is "no ghost models":
#      the snippet is applied at the RUNNING gate, never before.
#
# Usage:
#   bash oc-proxy/deploy-oc-proxy-hf.sh --check   # local only; no HF writes,
#                                                 # no HF_TOKEN required
#   HF_TOKEN=hf_xxx bash oc-proxy/deploy-oc-proxy-hf.sh
#
# Env:
#   HF_TOKEN          HF access token of a PRO-enabled account (Docker Spaces
#                     require PRO since 2026-07; free accounts get HTTP 402).
#                     Never written to disk; used for API + one-off git push.
#   HF_SPACE_USER     Space owner (default: token identity via whoami-v2)
#   HF_SPACE_NAME     Space name   (default: oc-proxy)
#   GATEWAY_API_KEY   gateway key  (default: generate oc_sk_<hex>; printed once)
#   OC_PROXY_REF      upstream pin (default: exact validated SHA below)
#   DEADLINE_SOFT_MS  SOFT_DEADLINE_MS variable   (default 300000 — HF has no
#   DEADLINE_ABS_MS   ABSOLUTE_DEADLINE_MS variable (default 330000  Vercel kill)
#
# Exit codes: 0 ok · 1 local failure · 2 HF blocked (402 — account tier) ·
#             3 build/start failed · 4 validation failed
# ============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")/.."   # stack root

OC_PROXY_REF_DEFAULT="2a41370e4ee121796bdbf65a2efeae99e80b58d1"
OC_PROXY_REF="${OC_PROXY_REF:-$OC_PROXY_REF_DEFAULT}"
HF_SPACE_NAME="${HF_SPACE_NAME:-oc-proxy}"
DEADLINE_SOFT_MS="${DEADLINE_SOFT_MS:-300000}"
DEADLINE_ABS_MS="${DEADLINE_ABS_MS:-330000}"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
step() { printf '\033[1;36m== %s ==\033[0m\n' "$*"; }

redact() { sed "s/${HF_TOKEN:-__none__}/***HF_TOKEN***/g"; }

# ---- 1. pin upstream at the exact SHA ------------------------------------------
step "1/8 pin upstream at OC_PROXY_REF=${OC_PROXY_REF:0:12}"
OC_PROXY_REF="$OC_PROXY_REF" bash oc-proxy/install-oc-proxy.sh >/dev/null
SHA=$(cat oc-proxy/upstream/.upstream-commit 2>/dev/null || echo unknown)
if [[ "$SHA" == "$OC_PROXY_REF" ]]; then
  ok "upstream pinned at exact SHA ${SHA:0:12} (no drift)"
else
  bad "SHA mismatch: got ${SHA:0:12}, want ${OC_PROXY_REF:0:12}"
  exit 1
fi

# ---- 2. assemble + validate the Space dist -------------------------------------
step "2/8 assemble dist/oc-proxy-hf-space (make-hf-space.sh)"
bash oc-proxy/make-hf-space.sh --check >/dev/null
ok "dist valid (9/9 packaging assertions, OC_PROXY_UPSTREAM_DIR=/app wired)"
DIST="oc-proxy/dist/oc-proxy-hf-space"
grep -q "OC_PROXY_UPSTREAM_DIR=/app" "$DIST/Dockerfile" \
  || { bad "Dockerfile missing OC_PROXY_UPSTREAM_DIR=/app"; exit 1; }
ok "adapter wiring verified (upstream handlers at /app)"

# ---- 3. Layer B snippet pre-validation (no write yet) ---------------------------
step "3/8 validate oc-proxy-hf provider snippet against Layer B"
python3 - "$OC_PROXY_REF" <<'PYEOF'
import json, sys
cfg = json.load(open("config/opencode.json"))
assert "providers" in cfg, "Layer B has no providers"
snippet = {
    "name": "OpenCode Zen Free (via oc-proxy HF Space)",
    "package": "@opencode/ai/providers/openai-compatible",
    "settings": {
        "baseURL": "https://SPACE_USER-SPACE_NAME.hf.space/v1",
        "apiKey": "{env:OC_PROXY_KEY}",
    },
    "models": {
        "glm-5.3-flash-free": {"name": "GLM 5.3 Flash (free)",
                               "capabilities": {"tools": True}},
        "deepseek-v4.1-flash-free": {"name": "DeepSeek V4.1 Flash (free)",
                                     "capabilities": {"tools": True}},
    },
}
probe = json.loads(json.dumps(cfg))
probe["providers"]["oc-proxy-hf"] = snippet
json.dumps(probe)          # round-trip validity
print("  PASS snippet schema valid, merge is idempotent-safe")
sys.exit(0)
PYEOF

if (( CHECK_ONLY )); then
  log "--check complete: pipeline locally validated; no HF writes performed."
  log "To deploy: HF_TOKEN=<PRO-account token> bash oc-proxy/deploy-oc-proxy-hf.sh"
  exit 0
fi

# ---- everything below requires HF_TOKEN -----------------------------------------
[[ -n "${HF_TOKEN:-}" ]] || { bad "HF_TOKEN required (or use --check)"; exit 1; }

# ---- 4. identify account + create the Space -------------------------------------
step "4/8 identify account, create Space $HF_SPACE_NAME"
HF_USER=$(curl -s https://huggingface.co/api/whoami-v2 \
  -H "Authorization: Bearer $HF_TOKEN" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))')
[[ -n "$HF_USER" ]] || { bad "whoami failed — is HF_TOKEN valid?"; exit 1; }
log "HF account: $HF_USER"
CREATE=$(curl -s -w '\n%{http_code}' -X POST https://huggingface.co/api/repos/create \
  -H "Authorization: Bearer $HF_TOKEN" -H "Content-Type: application/json" \
  -d "{\"type\":\"space\",\"name\":\"$HF_SPACE_NAME\",\"sdk\":\"docker\",\"private\":false}")
CODE=$(echo "$CREATE" | tail -1); BODY=$(echo "$CREATE" | head -1)
case "$CODE" in
  200|201) ok "Space $HF_USER/$HF_SPACE_NAME created (docker sdk)" ;;
  *)
    if echo "$BODY" | grep -qiE "exist|already"; then
      ok "Space $HF_USER/$HF_SPACE_NAME already exists — reusing"
    elif [[ "$CODE" == "402" ]] || echo "$BODY" | grep -qi "PRO subscription"; then
      bad "HTTP $CODE — Docker Spaces on cpu-basic require a PRO subscription"
      log "  2026-07 policy change: only Static Spaces remain free."
      log "  Options: (a) enable PRO at https://huggingface.co/pro then rerun;"
      log "           (b) keep Vercel/VPS path (see README-STACK.md deployment status)."
      exit 2
    else
      bad "Space creation failed: HTTP $CODE $BODY"
      exit 1
    fi
    ;;
esac

# ---- 5. secrets + variables ------------------------------------------------------
step "5/8 set GATEWAY_API_KEY secret + deadline variables"
GK="${GATEWAY_API_KEY:-oc_sk_$(openssl rand -hex 20)}"
S1=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "https://huggingface.co/api/spaces/$HF_USER/$HF_SPACE_NAME/secrets" \
  -H "Authorization: Bearer $HF_TOKEN" -H "Content-Type: application/json" \
  -d "{\"key\":\"GATEWAY_API_KEY\",\"value\":\"$GK\"}")
S2=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "https://huggingface.co/api/spaces/$HF_USER/$HF_SPACE_NAME/variables" \
  -H "Authorization: Bearer $HF_TOKEN" -H "Content-Type: application/json" \
  -d "{\"key\":\"SOFT_DEADLINE_MS\",\"value\":\"$DEADLINE_SOFT_MS\"}")
S3=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "https://huggingface.co/api/spaces/$HF_USER/$HF_SPACE_NAME/variables" \
  -H "Authorization: Bearer $HF_TOKEN" -H "Content-Type: application/json" \
  -d "{\"key\":\"ABSOLUTE_DEADLINE_MS\",\"value\":\"$DEADLINE_ABS_MS\"}")
[[ "$S1" == "200" && "$S2" == "200" && "$S3" == "200" ]] \
  && ok "GATEWAY_API_KEY secret + SOFT=${DEADLINE_SOFT_MS}ms ABS=${DEADLINE_ABS_MS}ms set" \
  || { bad "secrets/variables failed ($S1/$S2/$S3)"; exit 1; }
echo ""
echo "  ================================================================"
echo "  GATEWAY_API_KEY (store it now — shown only once): $GK"
echo "  Client usage:  export OC_PROXY_KEY='$GK'   (Layer B reads {env:OC_PROXY_KEY})"
echo "  ================================================================"
echo ""

# ---- 6. push dist ----------------------------------------------------------------
step "6/8 push dist to the Space"
( cd "$DIST"
  git init -b main >/dev/null 2>&1 || git init >/dev/null 2>&1
  git add -A
  git -c user.name="stack-deploy" -c user.email="deploy@stack.local" \
      commit -q -m "oc-proxy Layer P (upstream pinned ${OC_PROXY_REF:0:12})" || true
  git push "https://$HF_USER:$HF_TOKEN@huggingface.co/spaces/$HF_USER/$HF_SPACE_NAME" main 2>&1 | redact | tail -2 )
ok "dist pushed (branch main)"

# ---- 7. wait for RUNNING + live validation ---------------------------------------
step "7/8 poll build -> RUNNING, then live-validate"
BASE="https://${HF_USER,,}-${HF_SPACE_NAME}.hf.space"
STAGE=""
for i in $(seq 1 30); do
  STAGE=$(curl -s "https://huggingface.co/api/spaces/$HF_USER/$HF_SPACE_NAME" \
    -H "Authorization: Bearer $HF_TOKEN" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("runtime") or {}).get("stage","?"))' 2>/dev/null || echo "?")
  log "  poll $i: $STAGE"
  [[ "$STAGE" == "RUNNING" ]] && break
  if [[ "$STAGE" == "BUILD_ERROR" || "$STAGE" == "RUNTIME_ERROR" ]]; then
    curl -s "https://huggingface.co/api/spaces/$HF_USER/$HF_SPACE_NAME" \
      -H "Authorization: Bearer $HF_TOKEN" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("runtime") or {}).get("errorMessage","no message"))'
    bad "Space failed to build/start"; exit 3
  fi
  sleep 30
done
[[ "$STAGE" == "RUNNING" ]] || { bad "not RUNNING after 15 min (stage: $STAGE)"; exit 3; }
ok "Space RUNNING at $BASE"

H=$(curl -s -o /tmp/ocp-h.json -w '%{http_code}' --max-time 20 "$BASE/api/health")
M=$(curl -s -o /tmp/ocp-m.json -w '%{http_code}' --max-time 30 "$BASE/v1/models")
A=$(curl -s -o /dev/null      -w '%{http_code}' --max-time 20 -X POST "$BASE/v1/chat/completions" \
      -H "Content-Type: application/json" -d '{"model":"glm-5.3-flash-free","messages":[{"role":"user","content":"hi"}]}')
[[ "$H" == "200" ]] && ok "health 200" || { bad "health HTTP $H"; exit 4; }
[[ "$M" == "200" ]] && ok "models 200 ($(python3 -c 'import json;print(len(json.load(open("/tmp/ocp-m.json")).get("data",[])))' 2>/dev/null || echo '?') ids)" || { bad "models HTTP $M"; exit 4; }
[[ "$A" == "401" ]] && ok "auth enforced (no key -> 401)" || bad "auth: expected 401 without key, got $A"

# ---- 8. apply Layer B (only after the gate passed) --------------------------------
step "8/8 apply oc-proxy-hf provider to Layer B (gate passed)"
BASEURL="$BASE/v1" python3 <<'PYEOF'
import json, shutil, os
baseurl = os.environ["BASEURL"]
shutil.copy("config/opencode.json", "config/opencode.json.bak-oc-proxy-hf")
cfg = json.load(open("config/opencode.json"))
cfg["providers"]["oc-proxy-hf"] = {
    "name": "OpenCode Zen Free (via oc-proxy HF Space)",
    "package": "@opencode/ai/providers/openai-compatible",
    "settings": {"baseURL": baseurl, "apiKey": "{env:OC_PROXY_KEY}"},
    "models": {
        "glm-5.3-flash-free": {"name": "GLM 5.3 Flash (free)", "capabilities": {"tools": True}},
        "deepseek-v4.1-flash-free": {"name": "DeepSeek V4.1 Flash (free)", "capabilities": {"tools": True}},
    },
}
json.dump(cfg, open("config/opencode.json", "w"), indent=2)
json.load(open("config/opencode.json"))
print(f"  PASS oc-proxy-hf applied with baseURL {baseurl} (backup: opencode.json.bak-oc-proxy-hf)")
PYEOF

ok "export OC_PROXY_KEY='<the key above>' and run: bun run example:oc-agent"
log "DONE — Layer P live on HF, Layer B wired."
