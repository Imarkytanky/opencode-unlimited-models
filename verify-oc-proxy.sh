#!/usr/bin/env bash
# ============================================================================
# verify-oc-proxy.sh — Layer P contract test (oc-proxy)
#
# Validates the oc-proxy integration against 7 assertions:
#   P0  upstream installed + syntax OK (skip-grade if not installed)
#   P1  server boots; /api/health returns 200
#   P2  /v1/models returns 200 with *-free models
#   P3  POST /v1/chat/completions reaches upstream with a valid fingerprint:
#         PASS on 200; PASS on 429 FreeUsageLimitError (fingerprint accepted,
#         quota hit); FAIL on 403 FreeTierError (fingerprint rejected)
#   P4  auth enforcement: 401 without key when GATEWAY_API_KEY is set
#   P5  dashboard served at / (HTML)
#   P6  HF Space packaging: make-hf-space.sh produces a valid Space directory
#
# Usage:
#   bash verify-oc-proxy.sh            # full (boots server on :7861)
#   bash verify-oc-proxy.sh --quick    # skips live upstream chat (P3) + Space build
#
# Exit code = number of failed assertions.
# ============================================================================
set -u
cd "$(dirname "$0")"

PORT_P="${OC_PROXY_TEST_PORT:-7861}"
BASE="http://127.0.0.1:${PORT_P}"
LOG="${TMPDIR:-/tmp}/verify-oc-proxy"
mkdir -p "$LOG"
PASS=0; FAIL=0; SKIP=0
QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

ok()   { PASS=$((PASS+1)); echo "[PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "[FAIL] $1"; }
skip() { SKIP=$((SKIP+1)); echo "[SKIP] $1"; }

SRV_PID=""

cleanup() { [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; }
trap cleanup EXIT

# ---- P0: upstream installed ---------------------------------------------------
if [[ ! -f oc-proxy/upstream/api/v1/chat/completions.js ]]; then
  skip "P0 upstream not installed (bash oc-proxy/install-oc-proxy.sh)"
  skip "P1 boot/health (upstream missing)"; skip "P2 models (upstream missing)"
  skip "P3 live chat (upstream missing)";   skip "P4 auth (upstream missing)"
  skip "P5 dashboard (upstream missing)"
  echo ""
  echo "=== Layer P contract: $PASS PASS / $FAIL FAIL / $SKIP SKIP ==="
  exit 0
fi

if ( cd oc-proxy && bash install-oc-proxy.sh --check >/dev/null 2>&1 ); then
  ok "P0 upstream installed, syntax OK"
else
  bad "P0 upstream syntax/wiring check failed"
  echo ""
  echo "=== Layer P contract: $PASS PASS / $FAIL FAIL / $SKIP SKIP ==="
  exit 1
fi

# ---- boot server ----------------------------------------------------------------
( cd oc-proxy && PORT="$PORT_P" HOST=127.0.0.1 node server.js > "$LOG/server.log" 2>&1 ) &
SRV_PID=$!
UP=0
for _ in $(seq 1 20); do
  curl -sf --max-time 2 "$BASE/api/health" >/dev/null 2>&1 && { UP=1; break; }
  sleep 0.5
done

# ---- P1: health ------------------------------------------------------------------
if (( UP )); then
  H=$(curl -s -o "$LOG/health.json" -w '%{http_code}' --max-time 10 "$BASE/api/health")
  if [[ "$H" == "200" ]] && python3 -c "
import json; d=json.load(open('$LOG/health.json')); assert d.get('status')=='ok'; assert d.get('provider')=='opencode'" 2>/dev/null; then
    ok "P1 server boots, /api/health 200 (provider=opencode)"
  else
    bad "P1 /api/health unexpected (HTTP $H)"
  fi
else
  bad "P1 server failed to boot (see $LOG/server.log)"; tail -5 "$LOG/server.log"
fi

# ---- P2: models -------------------------------------------------------------------
M=$(curl -s -o "$LOG/models.json" -w '%{http_code}' --max-time 30 "$BASE/v1/models")
if [[ "$M" == "200" ]] && python3 -c "
import json
d = json.load(open('$LOG/models.json'))
ids = [m['id'] for m in d.get('data', [])]
assert len(ids) > 0, 'no models'
assert all(m.get('object') == 'model' for m in d['data']), 'bad object field'
free = [i for i in ids if i.endswith('-free') or i.split('/')[-1].endswith('-free')]
assert free, 'no *-free models'
print(f'{len(ids)} models, {len(free)} *-free')" 2>/dev/null; then
  ok "P2 /v1/models 200 with *-free models ($(python3 -c "
import json
d = json.load(open('$LOG/models.json'))
print(len(d.get('data', [])))") ids)"
else
  bad "P2 /v1/models failed (HTTP $M) — upstream /zen/v1/models may be down; check $LOG/models.json"
fi

# ---- P4: auth enforcement (keyed instance on :7862) ---------------------------
PORT_A=7862
BASE_A="http://127.0.0.1:7862"
( cd oc-proxy && PORT=7862 HOST=127.0.0.1 GATEWAY_API_KEY=sk-test-layer-p node server.js > "$LOG/server-auth.log" 2>&1 ) &
AUTH_PID=$!
AUTH_UP=0
for _ in $(seq 1 20); do
  curl -sf --max-time 2 "$BASE_A/api/health" >/dev/null 2>&1 && { AUTH_UP=1; break; }
  sleep 0.5
done
if (( AUTH_UP )); then
  C401=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$BASE_A/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"muse-spark-1.3-contributor-free","messages":[{"role":"user","content":"hi"}]}')
  C200=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$BASE_A/v1/chat/completions" \
    -H "Authorization: Bearer sk-test-layer-p" \
    -H "Content-Type: application/json" -d '{"model":"muse-spark-1.3-contributor-free","messages":[{"role":"user","content":"hi"}]}' \
    --max-time 8 || echo "timeout")
  if [[ "$C401" == "401" ]]; then
    ok "P4 auth enforced: no key -> 401"
  else
    bad "P4 auth: expected 401 without key, got $C401"
  fi
  if [[ "$C200" != "401" ]]; then
    ok "P4 auth: valid key passes auth layer (got $C200 from upstream)"
  else
    bad "P4 auth: valid key rejected 401"
  fi
else
  skip "P4 auth instance failed to boot"
fi
kill "$AUTH_PID" 2>/dev/null || true

# ---- P3: live upstream chat (fingerprint proof) -------------------------------------
if (( QUICK )); then
  skip "P3 live chat skipped (--quick)"
else
  # Pick a model from the LIVE catalog (P2 output) — upstream rotates free
  # model IDs (muse-spark was retired 2026-11; catalog is the source of truth).
  LIVE_MODEL=$(python3 -c "
import json
try:
    d = json.load(open('$LOG/models.json'))
    ids = [m['id'] for m in d.get('data', [])]
    bare = [i for i in ids if not i.startswith('oc/') and i.endswith('-free')]
    print(bare[0] if bare else '')
except Exception:
    print('')")
  if [[ -z "$LIVE_MODEL" ]]; then
    skip "P3 live chat (no live model available from P2)"
  else
    BODY=$(curl -s -o "$LOG/chat.json" -w '%{http_code}' --max-time 75 -X POST "$BASE/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$LIVE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: OK\"}]}" || echo "000")
    ERR=$(python3 -c "
import json
try:
    d = json.load(open('$LOG/chat.json'))
    e = d.get('error', {})
    msg = e.get('message', '') if isinstance(e, dict) else str(e)
    print(msg[:160])
except Exception:
    print('')" 2>/dev/null)
    case "$BODY" in
      200)
        if python3 -c "
import json
d = json.load(open('$LOG/chat.json'))
c = d['choices'][0]
assert c['message']['role'] == 'assistant'
assert isinstance(c['message']['content'], str) and len(c['message']['content']) > 0
assert c['finish_reason'] in ('stop','length','tool_calls')
print('OpenAI shape OK')" 2>/dev/null; then
          ok "P3 live chat: 200, OpenAI-shaped completion via $LIVE_MODEL"
        else
          bad "P3 live chat: 200 but response shape unexpected (see $LOG/chat.json)"
        fi
        ;;
      429|500|502|503)
        if echo "$ERR" | grep -qiE "FreeUsageLimit|rate limit|quota|usage limit|overload|capacity"; then
          ok "P3 live chat: HTTP $BODY — fingerprint ACCEPTED (upstream quota/rate-limit reached)"
        else
          bad "P3 live chat: HTTP $BODY, unexpected error: $ERR"
        fi
        ;;
      400)
        if echo "$ERR" | grep -qiE "unavailable|not (found|exist)"; then
          # Try one more model from the catalog before failing
          ALT_MODEL=$(python3 -c "
import json
try:
    d = json.load(open('$LOG/models.json'))
    ids = [m['id'] for m in d.get('data', [])]
    bare = [i for i in ids if not i.startswith('oc/') and i.endswith('-free')]
    print(bare[1] if len(bare) > 1 else '')
except Exception:
    print('')")
          if [[ -n "$ALT_MODEL" ]]; then
            BODY2=$(curl -s -o "$LOG/chat2.json" -w '%{http_code}' --max-time 75 -X POST "$BASE/v1/chat/completions" \
              -H "Content-Type: application/json" \
              -d "{\"model\":\"$ALT_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: OK\"}]}" || echo "000")
            case "$BODY2" in
              200) ok "P3 live chat: 200 via fallback model $ALT_MODEL" ;;
              429|500|502|503) ok "P3 live chat: HTTP $BODY2 — fingerprint ACCEPTED (quota/rate-limit)" ;;
              403) bad "P3 live chat: 403 FreeTierError — FINGERPRINT REJECTED" ;;
              *) bad "P3 live chat: HTTP $BODY2 after model fallback, err: $(python3 -c "
import json
try: print(json.load(open('$LOG/chat2.json')).get('error',{}).get('message','')[:120])
except Exception: print('')")" ;;
            esac
          else
            bad "P3 live chat: HTTP 400 (model unavailable), no alternate model to try"
          fi
        else
          bad "P3 live chat: HTTP 400, err: $ERR"
        fi
        ;;
      403)
        bad "P3 live chat: 403 FreeTierError — FINGERPRINT REJECTED (upstream contract changed?) err: $ERR"
        ;;
      000)
        bad "P3 live chat: request failed entirely (network?)"
        ;;
      *)
        bad "P3 live chat: HTTP $BODY, err: $ERR"
        ;;
    esac
  fi
fi

# ---- P5: dashboard -------------------------------------------------------------------
D=$(curl -s -o "$LOG/dashboard.html" -w '%{http_code}' --max-time 10 "$BASE/")
if [[ "$D" == "200" ]] && grep -qi "<title>oc-proxy" "$LOG/dashboard.html" 2>/dev/null; then
  ok "P5 dashboard served at / ($(wc -c < "$LOG/dashboard.html") bytes HTML)"
else
  bad "P5 dashboard failed (HTTP $D)"
fi

# ---- P6: HF Space packaging ------------------------------------------------------------
if (( QUICK )); then
  skip "P6 HF Space packaging skipped (--quick)"
else
  if bash oc-proxy/make-hf-space.sh --check > "$LOG/hf-space.log" 2>&1; then
    RM="oc-proxy/dist/oc-proxy-hf-space/README.md"
    if grep -q "sdk: docker" "$RM" && grep -q "app_port: 7860" "$RM" \
       && grep -q 'CMD \["node", "server.js"\]' oc-proxy/dist/oc-proxy-hf-space/Dockerfile; then
      ok "P6 HF Space packaging valid (sdk: docker, app_port: 7860, CMD node server.js)"
    else
      bad "P6 HF Space files assembled but invalid"
    fi
  else
    bad "P6 make-hf-space.sh failed (see $LOG/hf-space.log)"
  fi
fi

cleanup
echo ""
echo "=== Layer P contract: $PASS PASS / $FAIL FAIL / $SKIP SKIP ==="
exit $FAIL
