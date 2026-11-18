#!/usr/bin/env bash
# ============================================================================
# verify-browser-search.sh — Layer W contract test
#
# Validates the browser-search integration against 6 assertions:
#   W1  SearXNG engine reachable (skipped in --quick / if engine absent)
#   W2  tier-1 search: searxng.mjs returns JSON results
#   W3  tier-2 extraction: smart-extract.mjs --fallback (CloakBrowser)
#   W4  tier-3: cloak-fetch.mjs on a challenge-hardened site
#   W5  E2E anti-hallucination loop: search -> URL -> content extraction
#   W6  check.sh health report is accurate for the current install state
#
# Usage:
#   bash verify-browser-search.sh           # full (launches SearXNG if found)
#   bash verify-browser-search.sh --quick   # CloakBrowser tier only, ~20 s
#
# Exit code = number of failed assertions.
# ============================================================================
set -u
cd "$(dirname "$0")"

BS="browser-search"
LOG="${TMPDIR:-/tmp}/verify-browser-search"
mkdir -p "$LOG"
PASS=0; FAIL=0; SKIP=0

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

ok()   { PASS=$((PASS+1)); echo "[PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "[FAIL] $1"; }
skip() { SKIP=$((SKIP+1)); echo "[SKIP] $1"; }
jsonv() { python3 -c "
import json,sys
try: d=json.load(open('$1')); print(d$2)
except Exception: print('')"; }

# ---- pre-flight -------------------------------------------------------------
[[ -d "$BS" ]] || { echo "browser-search/ not found — run setup.sh first"; exit 9; }
[[ -d "$BS/node_modules" ]] || { echo "[SKIP] browser-search deps not installed (npm install in browser-search/)"; exit 0; }
( cd "$BS" && node -e "import('cloakbrowser').then(()=>0).catch(()=>process.exit(1))" >/dev/null 2>&1 ) \
  || { echo "[SKIP] cloakbrowser module missing — run: node -e \"import('cloakbrowser').then(c=>c.ensureBinary())\""; exit 0; }

# ---- W1/W2: engine + search (full mode only) --------------------------------
ENGINE=0
if (( ! QUICK )); then
  if curl -sf --max-time 4 "${SEARXNG_URL:-http://127.0.0.1:8080}/healthz" >/dev/null 2>&1; then
    ENGINE=1
  elif [[ -d "${SEARXNG_SRC:-/tmp/searxng-src}" ]]; then
    SRC="${SEARXNG_SRC:-/tmp/searxng-src}"
    PY="${SEARXNG_PYTHON:-}"
    if [[ -z "$PY" ]]; then
      # searx resolves from the repo root (cwd), not site-packages
      if [[ -x "$HOME/.venv/bin/python" ]] && ( cd "$SRC" && "$HOME/.venv/bin/python" -c "import searx" >/dev/null 2>&1 ); then PY="$HOME/.venv/bin/python"
      elif ( cd "$SRC" && python3 -c "import searx" >/dev/null 2>&1 ); then PY=python3
      fi
    fi
    if [[ -n "$PY" ]]; then
      echo "[info] launching native SearXNG from $SRC ($PY) ..."
      ( cd "$SRC" && SEARXNG_SETTINGS_PATH="$OLDPWD/$BS/searxng-settings.yml" \
          SEARXNG_BASE_URL="http://127.0.0.1:8080/" \
          SEARXNG_CONTACT_URL="mailto:admin@example.com" \
          SEARXNG_INSTANCE_NAME="bs-verify" \
          "$PY" -m searx.webapp > "$LOG/engine.log" 2>&1 & echo $! > "$LOG/engine.pid" )
      for _ in $(seq 1 30); do
        curl -sf --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1 && { ENGINE=1; break; }
        sleep 1
      done
      (( ENGINE )) || { echo "[info] engine launch failed — see $LOG/engine.log"; tail -3 "$LOG/engine.log" 2>/dev/null; }
    else
      echo "[info] no python with searx deps found — install per browser-search/README-STACK.md"
    fi
  fi
fi

if (( ENGINE )); then
  ok "W1 SearXNG engine reachable on :8080"
  export SEARXNG_URL=http://127.0.0.1:8080
  timeout 90 node "$BS/scripts/searxng/searxng.mjs" search "opencode model discovery" --lang en \
    > "$LOG/w2.json" 2>/dev/null
  N=$(jsonv "$LOG/w2.json" "['results'].__len__() if 'results' in d else 0")
  OK2=$(jsonv "$LOG/w2.json" ".get('ok', False)")
  if [[ "$OK2" == "True" && "$N" -gt 0 ]] 2>/dev/null; then
    ok "W2 tier-1 search returned $N JSON results"
  else
    bad "W2 tier-1 search failed (see $LOG/w2.json)"
  fi
else
  if (( QUICK )); then skip "W1 engine probe (--quick)"; skip "W2 search (--quick)"; skip "W5 E2E loop (--quick)";
  else skip "W1 SearXNG not installed and SEARXNG_SRC not set"; skip "W2 search (no engine)"; skip "W5 E2E loop (no engine)"; fi
fi

# ---- W3: CloakBrowser extraction --------------------------------------------
timeout 120 node "$BS/scripts/smart-extract.mjs" --fallback "https://example.com" \
  > "$LOG/w3.json" 2>/dev/null
CH=$(jsonv "$LOG/w3.json" "['results'][0]['chars'] if d.get('results') else 0")
OK3=$(jsonv "$LOG/w3.json" "['results'][0]['ok'] if d.get('results') else False")
if [[ "$OK3" == "True" && "$CH" -gt 100 ]] 2>/dev/null; then
  ok "W3 tier-2 extraction via CloakBrowser ($CH chars)"
else
  bad "W3 CloakBrowser extraction failed (see $LOG/w3.json)"
fi

# ---- W4: challenge-hardened site --------------------------------------------
timeout 120 node "$BS/scripts/cloak/cloak-fetch.mjs" "https://www.cloudflare.com" \
  > "$LOG/w4.json" 2>/dev/null
CH4=$(jsonv "$LOG/w4.json" ".get('chars', 0)")
if [[ "$CH4" -gt 500 ]] 2>/dev/null; then
  ok "W4 cloak-fetch cleared cloudflare.com ($CH4 chars)"
else
  bad "W4 cloak-fetch on cloudflare.com returned too little content"
fi

# ---- W5: E2E loop (full mode only, reuses W2 results) ------------------------
if (( ENGINE )); then
  URL=$(python3 -c "
import json
try:
    d=json.load(open('$LOG/w2.json'))
    print(d['results'][0]['url'])
except Exception: print('')")
  if [[ -n "$URL" ]]; then
    timeout 120 node "$BS/scripts/smart-extract.mjs" --fallback "$URL" > "$LOG/w5.json" 2>/dev/null
    CH5=$(jsonv "$LOG/w5.json" "['results'][0]['chars'] if d.get('results') else 0")
    if [[ "$CH5" -gt 100 ]] 2>/dev/null; then
      ok "W5 E2E loop: search -> '$URL' -> $CH5 chars extracted"
    else
      bad "W5 E2E extraction of $URL failed"
    fi
  else
    bad "W5 no URL from search results"
  fi
fi

# ---- W6: health-check accuracy ----------------------------------------------
bash "$BS/scripts/check.sh" > "$LOG/w6.txt" 2>&1 || true
if grep -q "CloakBrowser:" "$LOG/w6.txt" && grep -qE "SearXNG: +(running|stopped/missing)" "$LOG/w6.txt"; then
  ok "W6 check.sh health report accurate"
else
  bad "W6 check.sh output unexpected"
fi

# ---- cleanup ------------------------------------------------------------------
if [[ -f "$LOG/engine.pid" ]]; then kill "$(cat "$LOG/engine.pid")" 2>/dev/null || true; rm -f "$LOG/engine.pid"; fi

echo ""
echo "=== Layer W contract: $PASS PASS / $FAIL FAIL / $SKIP SKIP ==="
exit $FAIL
