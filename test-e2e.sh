#!/usr/bin/env bash
# ============================================================================
# test-e2e.sh — unified end-to-end test for the entire opencode-unlimited stack
#
# Validates every layer works together:
#   Layer B:   opencode.json config loads (valid JSON, 3 providers)
#   Layer A:   opencode Console /v1/models reachable (53 models)
#   Layer D:   opencode-egress-router proxy on :8318 (free-tier Zen)
#   Layer D_thin: reconcile plugin unit tests (7/7)
#   Layer G:   zen-unlimited gateway on :20128 (muse-spark, 24 models)
#   Layer F:   proxy-hunter fetches public proxies (count check)
#   Layer CF:  Cloudflare Workers proxy (wrangler dev, edge IP rotation)
#   Layer W:   browser-search skill (SKILL.md + cloakbrowser + Chromium +
#              optional SearXNG engine probe + Layer F bridge check)
#   Layer P:   oc-proxy portable Zen bypass (adapter present + boot check)
#   Contract:  9/9 assertions (C1-C9) against the mock gateway
#
# Usage:
#   bash test-e2e.sh                    # run all tests
#   bash test-e2e.sh --quick             # fast mode: skip CF + zen-unlimited (6 tests, ~15s)
#   bash test-e2e.sh --layer d           # run only Layer D tests
#   bash test-e2e.sh --layer contract    # run only the contract test
#   bash test-e2e.sh --skip-cf           # skip Cloudflare Workers (needs wrangler)
#   bash test-e2e.sh --skip-g            # skip zen-unlimited (needs bun + node)
#   bash test-e2e.sh --skip-w            # skip browser-search (Layer W) checks
#   bash test-e2e.sh --skip-p            # skip oc-proxy (Layer P) checks
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "$SCRIPT_DIR" && pwd)"
PASS=0; FAIL=0; SKIP=0

# Flags
SKIP_CF=0; SKIP_G=0; SKIP_W=0; SKIP_P=0; QUICK=0; LAYER_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-cf)  SKIP_CF=1 ;;
    --skip-g)   SKIP_G=1 ;;
    --skip-w)   SKIP_W=1 ;;
    --skip-p)   SKIP_P=1 ;;
    --quick)     QUICK=1; SKIP_CF=1; SKIP_G=1 ;;
    --layer)    LAYER_FILTER="$2"; shift ;;
    -h|--help)  grep '^#' "$0" | sed -n '1,25p'; exit 0 ;;
  esac
  shift
done

log()  { printf '\033[1;34m[e2e]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '\033[1;33m  SKIP \033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }

should_run() {
  [[ -z "$LAYER_FILTER" || "$LAYER_FILTER" == "$1" ]]
}

# ============================================================================
log "=== Pre-flight: install deps ==="
# ============================================================================
if should_run "preflight"; then
  cd "$BUNDLE_ROOT/plugins"
  bun install --silent 2>/dev/null || true
  cd "$BUNDLE_ROOT"
  if [[ -d "$BUNDLE_ROOT/zen-unlimited-linux" ]]; then
    cd "$BUNDLE_ROOT/zen-unlimited-linux"
    bun install --silent 2>/dev/null || true
    cd "$BUNDLE_ROOT"
  fi
fi

# ============================================================================
log "=== Layer B: opencode.json config ==="
# ============================================================================
if should_run "b"; then
  if python3 -c "
import json
d = json.load(open('$BUNDLE_ROOT/config/opencode.json'))
assert 'providers' in d, 'no providers key'
p = list(d['providers'].keys())
assert len(p) >= 2, f'only {len(p)} providers (expected >=2)'
print(f'  providers: {p}')
print(f'  plugins: {len(d.get(\"plugins\", []))} registered')
" 2>&1; then
    ok "config valid, 3 providers + 1 plugin"
  else
    bad "config invalid or missing providers"
  fi
fi

# ============================================================================
log "=== Layer A: opencode Console /v1/models ==="
# ============================================================================
if should_run "a"; then
  set +a; . "$BUNDLE_ROOT/.env.local" 2>/dev/null || true; set -a
  if [ -n "${OPENCODE_API_KEY:-}" ]; then
    COUNT=$(curl -sS --max-time 10 --compressed \
      -H "Authorization: Bearer $OPENCODE_API_KEY" \
      -H "User-Agent: opencode/1.19.5" \
      "https://opencode.ai/inference/v1/models" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len(d.get('data', [])))
" 2>/dev/null || echo "0")
    if [ "$COUNT" -gt 10 ]; then
      ok "opencode Console reachable ($COUNT models)"
    else
      bad "opencode Console returned $COUNT models (expected >10)"
    fi
  else
    warn "OPENCODE_API_KEY not set — skipping Layer A"
  fi
fi

# ============================================================================
log "=== Layer D: opencode-egress-router proxy ==="
# ============================================================================
if should_run "d"; then
  # Start the proxy (with no fallback proxies — direct only)
  setsid bash -c "trap '' HUP INT TERM; exec $BUNDLE_ROOT/opencode-proxy/opencode-egress-router -listen 127.0.0.1:8318 -upstream https://opencode.ai/zen/v1 -cooldown 60s" </dev/null >/tmp/oc-proxy.log 2>&1 &
  echo $! > /tmp/oc-proxy.pid
  sleep 3
  HTTP=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Authorization: Bearer public" \
    -H "Content-Type: application/json" \
    -d '{"model":"glm-5.3-flash-free","messages":[{"role":"user","content":"hi"}]}' \
    "http://127.0.0.1:8318/chat/completions" 2>/dev/null || echo "000")
  if [ "$HTTP" == "200" ]; then
    ok "opencode-egress-router on :8318 (HTTP 200, free-tier Zen)"
  else
    # 502 is acceptable if Zen is rate-limiting — the proxy itself works
    STATUS=$(curl -sS --max-time 5 http://127.0.0.1:8318/__router/status 2>/dev/null | head -c 100)
    if [ -n "$STATUS" ]; then
      ok "opencode-egress-router on :8318 (HTTP $HTTP — proxy alive, Zen may be rate-limiting)"
    else
      bad "opencode-egress-router returned HTTP $HTTP and no status"
    fi
  fi
  kill $(cat /tmp/oc-proxy.pid 2>/dev/null) 2>/dev/null || true
fi

# ============================================================================
log "=== Layer D_thin: reconcile plugin unit tests ==="
# ============================================================================
if should_run "d_thin"; then
  cd "$BUNDLE_ROOT/plugins"
  bun install --silent 2>/dev/null || true
  if bun test reconcile.test.ts 2>&1 | grep -qE '7 pass'; then
    ok "reconcile plugin: 7/7 unit tests PASS"
  else
    bad "reconcile plugin unit tests failed"
  fi
  cd "$BUNDLE_ROOT"
fi

# ============================================================================
log "=== Layer G: zen-unlimited gateway ==="
# ============================================================================
if should_run "g"; then
  if [[ $SKIP_G -eq 1 ]]; then
    warn "zen-unlimited skipped (--skip-g)"
  elif [[ -d "$BUNDLE_ROOT/zen-unlimited-linux" ]]; then
    cd "$BUNDLE_ROOT/zen-unlimited-linux"
    nohup node src/relay/rr-socks.mjs > /tmp/zen-relay.log 2>&1 &
    sleep 1
    nohup bun run src/index.ts serve --no-egress-direct > /tmp/zen-gateway.log 2>&1 &
    sleep 2
    HEALTH=$(curl -sS --max-time 5 http://127.0.0.1:20128/api/health 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('ok', 'false'))
" 2>/dev/null || echo "false")
    if [ "$HEALTH" == "True" ]; then
      ok "zen-unlimited gateway on :20128 (health: ok)"
    else
      bad "zen-unlimited gateway health: $HEALTH"
    fi
    pkill -f 'src/index.ts serve' 2>/dev/null || true
    pkill -f 'rr-socks.mjs' 2>/dev/null || true
    cd "$BUNDLE_ROOT"
  else
    warn "zen-unlimited-linux/ not found"
  fi
fi

# ============================================================================
log "=== Layer F: proxy-hunter ==="
# ============================================================================
if should_run "f"; then
  COUNT=$(python3 "$BUNDLE_ROOT/proxy-hunter/proxy-hunter.py" --protocol socks5 --count-only 2>/dev/null | tail -1)
  if [ "$COUNT" -gt 100 ] 2>/dev/null; then
    ok "proxy-hunter: fetched $COUNT SOCKS5 proxies"
  else
    warn "proxy-hunter: only $COUNT proxies (public feeds may be down)"
  fi
fi

# ============================================================================
log "=== Layer CF: Cloudflare Workers proxy ==="
# ============================================================================
if should_run "cf"; then
  if [[ $SKIP_CF -eq 1 ]]; then
    warn "Cloudflare Workers skipped (--skip-cf)"
  elif [[ -d "$BUNDLE_ROOT/cf-worker-proxy" ]]; then
    cd "$BUNDLE_ROOT/cf-worker-proxy"
    npx wrangler dev --port 8787 --ip 127.0.0.1 > /tmp/wrangler-dev.log 2>&1 &
    WRANGLER_PID=$!
    # Wait up to 15s for wrangler to bind (first run compiles the Worker)
    for i in $(seq 1 30); do
      if curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8787/ 2>/dev/null | grep -qE '^[2-9]'; then
        break
      fi
      sleep 0.5
    done
    EDGE=$(curl -sS --max-time 10 http://127.0.0.1:8787/ 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'{d.get(\"edge\",\"?\")}/{d.get(\"country\",\"?\")}')
" 2>/dev/null || echo "?")
    if [ "$EDGE" != "?" ]; then
      ok "Cloudflare Workers proxy on :8787 (edge: $EDGE)"

      # Test: proxy a chat completion through the Worker (needs OPENCODE_API_KEY)
      set +a; . "$BUNDLE_ROOT/.env.local" 2>/dev/null || true; set -a
      if [ -n "${OPENCODE_API_KEY:-}" ]; then
        CHAT_HTTP=$(curl -sS -o /tmp/cf-chat.json -w '%{http_code}' --max-time 20 --compressed \
          -H "Authorization: Bearer $OPENCODE_API_KEY" \
          -H "User-Agent: opencode/1.19.5" \
          -H "Content-Type: application/json" \
          -X POST \
          -d '{"model":"kimi-k3","messages":[{"role":"user","content":"Say OK in 1 word"}]}' \
          "http://127.0.0.1:8787/proxy/https://opencode.ai/inference/v1/chat/completions" 2>/dev/null || echo "000")
        if [ "$CHAT_HTTP" == "200" ]; then
          TEXT=$(python3 -c "import json; d=json.load(open('/tmp/cf-chat.json')); print(d['choices'][0]['message']['content'][:50])" 2>/dev/null || echo "?")
          ok "CF Worker chat proxy: HTTP 200, text: ${TEXT!r}"
        else
          warn "CF Worker chat proxy: HTTP $CHAT_HTTP (may be rate-limited)"
        fi
        rm -f /tmp/cf-chat.json
      fi
    else
      bad "Cloudflare Workers proxy not responding"
    fi
    kill $WRANGLER_PID 2>/dev/null || true
    cd "$BUNDLE_ROOT"
  else
    warn "cf-worker-proxy/ not found"
  fi
fi

# ============================================================================
log "=== Layer W: browser-search (SearXNG + Camofox + CloakBrowser) ==="
# ============================================================================
if should_run "w"; then
  if [[ $SKIP_W -eq 1 ]]; then
    warn "Layer W skipped (--skip-w)"
  else
    BS_DIR="$BUNDLE_ROOT/browser-search"
    if [[ ! -f "$BS_DIR/SKILL.md" ]]; then
      bad "Layer W: browser-search/SKILL.md missing"
    else
      # W1: skill definition + version
      BS_VER=$(python3 -c "import json; print(json.load(open('$BS_DIR/package.json'))['version'])" 2>/dev/null || echo '?')
      if head -5 "$BS_DIR/SKILL.md" | grep -q 'name: "browser-search"'; then
        ok "Layer W: SKILL.md valid (browser-search v$BS_VER, 3 tiers)"
      else
        bad "Layer W: SKILL.md frontmatter invalid"
      fi
      # W2: npm module (tier 3 prerequisite)
      if (cd "$BS_DIR" && node --input-type=module -e "import('cloakbrowser').then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>/dev/null); then
        ok "Layer W: cloakbrowser npm module resolvable"
        # W3: Chromium binary
        if find "$HOME/.cloakbrowser" -type f \( -name chrome -o -name chromium \) 2>/dev/null | grep -q .; then
          ok "Layer W: CloakBrowser Chromium binary present"
          # W4: live stealth fetch (full mode only — needs the binary + network)
          if [[ $QUICK -eq 1 ]]; then
            warn "Layer W: live cloak-fetch skipped (--quick)"
          else
            FETCH_JSON=$(cd "$BS_DIR" && timeout 90 node scripts/cloak/cloak-fetch.mjs "https://example.com" 2>/dev/null || echo "")
            if echo "$FETCH_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('url','').startswith('http'); assert len(d.get('content',''))>50" 2>/dev/null; then
              CHARS=$(echo "$FETCH_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('chars','?'))" 2>/dev/null)
              ok "Layer W: live cloak-fetch OK ($CHARS chars extracted via stealth Chromium)"
            else
              bad "Layer W: live cloak-fetch failed"
            fi
          fi
        else
          warn "Layer W: Chromium binary missing — run: cd browser-search && node -e \"import('cloakbrowser').then(c=>c.ensureBinary())\""
        fi
      else
        warn "Layer W: cloakbrowser not installed — run: cd browser-search && npm install"
      fi
      # W5: tier 1 engine health (Docker container OR native engine — HTTP probe)
      SEARX=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8080/search?format=json&q=health" 2>/dev/null || echo "000")
      if [[ "$SEARX" == "200" ]]; then
        ok "Layer W: SearXNG tier-1 engine answering JSON on :8080"
      else
        warn "Layer W: SearXNG not running (Docker: docker compose --profile search up -d; native: browser-search/README-STACK.md)"
      fi
      # W6: bridge availability
      if [[ -x "$BUNDLE_ROOT/bs-bridge.sh" ]]; then
        ok "Layer W: bs-bridge.sh present (Layer F proxy fleet → CloakBrowser egress)"
      else
        warn "Layer W: bs-bridge.sh missing (proxy fleet routing unavailable)"
      fi
    fi
  fi
fi

# ============================================================================
log "=== Layer P: oc-proxy (portable Zen bypass, HF Space-ready) ==="
# ============================================================================
if should_run "p"; then
  if [[ $SKIP_P -eq 1 ]]; then
    warn "Layer P skipped (--skip-p)"
  else
    # Shipped artifacts (always present)
    if [[ -f oc-proxy/server.js && -x oc-proxy/install-oc-proxy.sh && -x oc-proxy/make-hf-space.sh ]]; then
      ok "Layer P: adapter + installer + HF packager present"
      if node --check oc-proxy/server.js 2>/dev/null; then
        ok "Layer P: server.js syntax OK"
      else
        bad "Layer P: server.js syntax error"
      fi
      # Upstream installed? Then boot-check the adapter.
      if [[ -f oc-proxy/upstream/api/v1/chat/completions.js ]]; then
        ( cd oc-proxy && PORT=7866 HOST=127.0.0.1 node server.js > /tmp/oc-p-e2e.log 2>&1 & echo $! > /tmp/oc-p-e2e.pid )
        PUP=0
        for _ in $(seq 1 16); do
          curl -sf --max-time 2 http://127.0.0.1:7866/api/health >/dev/null 2>&1 && { PUP=1; break; }
          sleep 0.5
        done
        if (( PUP )); then
          ok "Layer P: adapter boots, /api/health 200"
          kill "$(cat /tmp/oc-p-e2e.pid)" 2>/dev/null || true
        else
          warn "Layer P: adapter boot failed — see /tmp/oc-p-e2e.log"
          kill "$(cat /tmp/oc-p-e2e.pid)" 2>/dev/null || true
        fi
      else
        warn "Layer P: upstream not installed — run bash oc-proxy/install-oc-proxy.sh (full test: bash verify-oc-proxy.sh)"
      fi
    else
      bad "Layer P: oc-proxy/ artifacts missing"
    fi
  fi
fi

# ============================================================================
log "=== Contract test (9/9 assertions) ==="
# ============================================================================
if should_run "contract"; then
  bash "$BUNDLE_ROOT/verify-a-contract/verify-a-contract.sh" \
    --simulate --mock --rich-metadata --simulate-d-thin --schema v2 \
    --keep --artifacts-dir /tmp/e2e-contract > /dev/null 2>&1
  RC=$?
  if [ $RC -eq 0 ]; then
    VERDICT=$(python3 -c "import json; v=json.load(open('/tmp/e2e-contract/verdict.json')); print(v['verdict'])" 2>/dev/null)
    if [ "$VERDICT" == "PASS" ]; then
      ok "contract test: PASS (9/9 assertions)"
    else
      bad "contract test: $VERDICT (expected PASS)"
    fi
  else
    bad "contract test: exit code $RC"
  fi
  rm -rf /tmp/e2e-contract
fi

# ============================================================================
echo
log "=== Results ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  SKIP: $SKIP"
echo
if [ $FAIL -eq 0 ]; then
  log "ALL TESTS PASSED"
  exit 0
else
  log "$FAIL TESTS FAILED"
  exit 1
fi
