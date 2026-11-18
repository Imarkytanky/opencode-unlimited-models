#!/usr/bin/env bash
# ============================================================================
# benchmark-layer-w.sh — performance benchmark for Layer W (browser-search)
#
# Measures latency and success rate of each Layer W tier, independent of the
# model layer. Useful for:
#   - Tracking performance across CloakBrowser/SearXNG version bumps
#   - Comparing direct vs proxied (Layer F) egress
#   - Right-sizing timeouts in verify-browser-search.sh
#
# Usage:
#   bash benchmark-layer-w.sh              # full benchmark, ~3 min
#   bash benchmark-layer-w.sh --quick      # quick: skip cloudflare + proxy
#   bash benchmark-layer-w.sh --runs N     # override runs per test (default 3)
#
# Prerequisites:
#   - SearXNG engine running on :8080 (or SEARXNG_SRC set for auto-launch)
#   - CloakBrowser Chromium binary installed
#   - Optional: proxy-hunter fleet for proxy comparison
# ============================================================================

set -u
cd "$(dirname "$0")"

BS="browser-search"
LOG="${TMPDIR:-/tmp}/benchmark-layer-w"
mkdir -p "$LOG"

QUICK=0
RUNS=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; shift ;;
    --runs) RUNS="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed -n '1,25p'; exit 0 ;;
    *) echo "unknown: $1"; exit 1 ;;
  esac
done

# Stats array: "name|latency_ms|success"
STATS_FILE="$LOG/stats.tsv"
echo -e "test\trun\tlatency_ms\tsuccess\tchars" > "$STATS_FILE"

run_timed() {
  local name="$1"; shift
  local run="$1"; shift
  local start end rc chars
  start=$(date +%s%N)
  "$@" > "$LOG/last-output.json" 2>/dev/null
  rc=$?
  end=$(date +%s%N)
  local ms=$(( (end - start) / 1000000 ))
  chars=$(python3 -c "
import json
try:
    d = json.load(open('$LOG/last-output.json'))
    if 'results' in d and d['results']:
        print(d['results'][0].get('chars', 0))
    elif 'chars' in d:
        print(d.get('chars', 0))
    elif 'results' in d and isinstance(d['results'], list) and len(d.get('results',[]))>0:
        print(d['results'][0].get('chars', 0))
    else:
        print(0)
except: print(0)
" 2>/dev/null)
  echo -e "${name}\t${run}\t${ms}\t$([[ $rc -eq 0 ]] && echo 1 || echo 0)\t${chars}" >> "$STATS_FILE"
  printf "  %s run %d: %d ms (rc=%d, chars=%s)\n" "$name" "$run" "$ms" "$rc" "$chars"
}

# ---- pre-flight -------------------------------------------------------------
[[ -d "$BS" ]] || { echo "browser-search/ not found"; exit 9; }
[[ -d "$BS/node_modules" ]] || { echo "Layer W deps not installed (cd browser-search && npm install)"; exit 9; }
( cd "$BS" && node -e "import('cloakbrowser').then(()=>0).catch(()=>process.exit(1))" >/dev/null 2>&1 ) \
  || { echo "cloakbrowser not installed"; exit 9; }

# ---- engine launch (if needed) ----------------------------------------------
ENGINE=0
if (( ! QUICK )); then
  if curl -sf --max-time 4 "http://127.0.0.1:8080/healthz" >/dev/null 2>&1; then
    ENGINE=1
  elif [[ -d "${SEARXNG_SRC:-/tmp/searxng-src}" ]]; then
    SRC="${SEARXNG_SRC:-/tmp/searxng-src}"
    PY="${SEARXNG_PYTHON:-}"
    if [[ -z "$PY" ]]; then
      if [[ -x "$HOME/.venv/bin/python" ]] && ( cd "$SRC" && "$HOME/.venv/bin/python" -c "import searx" >/dev/null 2>&1 ); then PY="$HOME/.venv/bin/python"
      elif ( cd "$SRC" && python3 -c "import searx" >/dev/null 2>&1 ); then PY=python3
      fi
    fi
    if [[ -n "$PY" ]]; then
      echo "[info] launching SearXNG from $SRC ($PY) ..."
      ( cd "$SRC" && SEARXNG_SETTINGS_PATH="$OLDPWD/$BS/searxng-settings.yml" \
          SEARXNG_BASE_URL="http://127.0.0.1:8080/" \
          SEARXNG_CONTACT_URL="mailto:admin@example.com" \
          "$PY" -m searx.webapp > "$LOG/engine.log" 2>&1 & echo $! > "$LOG/engine.pid" )
      for _ in $(seq 1 30); do
        curl -sf --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1 && { ENGINE=1; break; }
        sleep 1
      done
    fi
  fi
fi

echo ""
echo "=== Layer W Benchmark ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Runs per test: $RUNS"
echo "Engine: $([[ $ENGINE -eq 1 ]] && echo 'running' || echo 'not running')"
echo ""

# ---- T1: SearXNG search latency ---------------------------------------------
if (( ENGINE )); then
  echo "--- T1: SearXNG search latency ---"
  export SEARXNG_URL=http://127.0.0.1:8080
  for i in $(seq 1 "$RUNS"); do
    run_timed "T1-searxng-search" "$i" \
      node "$BS/scripts/searxng/searxng.mjs" search "opencode model discovery" --lang en
  done
  echo ""
fi

# ---- T2: CloakBrowser fetch (example.com, no challenge) ---------------------
echo "--- T2: CloakBrowser fetch (example.com) ---"
for i in $(seq 1 "$RUNS"); do
  run_timed "T2-cloak-example" "$i" \
    node "$BS/scripts/cloak/cloak-fetch.mjs" "https://example.com"
done
echo ""

# ---- T3: CloakBrowser fetch (cloudflare.com, challenge-hardened) -----------
if (( ! QUICK )); then
  echo "--- T3: CloakBrowser fetch (cloudflare.com, challenge site) ---"
  for i in $(seq 1 "$RUNS"); do
    run_timed "T3-cloak-cloudflare" "$i" \
      node "$BS/scripts/cloak/cloak-fetch.mjs" "https://www.cloudflare.com"
  done
  echo ""
fi

# ---- T4: smart-extract (auto-escalation) ------------------------------------
echo "--- T4: smart-extract (auto-escalation, example.com) ---"
for i in $(seq 1 "$RUNS"); do
  run_timed "T4-smart-extract" "$i" \
    node "$BS/scripts/smart-extract.mjs" --fallback "https://example.com"
done
echo ""

# ---- T5: bridge fetch (Layer F proxy, if available) -------------------------
if [[ -x bs-bridge.sh ]] && [[ -s proxy-hunter/custom-proxies.txt ]] && (( ! QUICK )); then
  PROXY=$(grep -m1 -E '^socks5://' proxy-hunter/custom-proxies.txt 2>/dev/null || true)
  if [[ -n "$PROXY" ]]; then
    echo "--- T5: bridge fetch via Layer F proxy ($PROXY) ---"
    for i in $(seq 1 "$RUNS"); do
      run_timed "T5-bridge-proxy" "$i" \
        env BS_PROXY="$PROXY" bash bs-bridge.sh fetch "https://api.ipify.org?format=json"
    done
    echo ""
  fi
fi

# ---- cleanup ----------------------------------------------------------------
if [[ -f "$LOG/engine.pid" ]]; then kill "$(cat "$LOG/engine.pid")" 2>/dev/null || true; rm -f "$LOG/engine.pid"; fi

# ---- summary ----------------------------------------------------------------
echo "=== Summary ==="
python3 -c "
import csv
with open('$STATS_FILE') as f:
    rows = list(csv.DictReader(f, delimiter='\t'))

from collections import defaultdict
by_test = defaultdict(list)
for r in rows:
    by_test[r['test']].append(r)

print(f'{\"Test\":<24} {\"Runs\":<6} {\"Success\":<10} {\"Med ms\":<10} {\"P90 ms\":<10} {\"Avg chars\":<12}')
print('-' * 80)
for test, rs in sorted(by_test.items()):
    lats = sorted(int(r['latency_ms']) for r in rs)
    succ = sum(1 for r in rs if r['success'] == '1')
    chars = [int(r['chars']) for r in rs if r['success'] == '1' and int(r['chars']) > 0]
    med = lats[len(lats)//2] if lats else 0
    p90 = lats[int(len(lats)*0.9)] if len(lats) > 1 else (lats[0] if lats else 0)
    avg_chars = sum(chars)//len(chars) if chars else 0
    print(f'{test:<24} {len(rs):<6} {succ}/{len(rs):<8} {med:<10} {p90:<10} {avg_chars:<12}')
"

echo ""
echo "Stats file: $STATS_FILE"
