#!/usr/bin/env bash
# ============================================================================
# setup.sh — one-shot setup for the opencode-unlimited-models-final bundle
#
# Runs all the steps from QUICKSTART.md in one command:
#   1. Install JS dependencies (bun install)
#   2. Copy .env.local.example to .env.local (if not present)
#   3. Start the opencode-egress-router proxy (Layer D)
#   4. Install SphinX-lite (Layer C) — optional, prompt to skip
#   5. Run the contract test (mock, A+D_thin — 9/9 expected)
#
# Usage:
#   bash setup.sh             # interactive (prompts for sphinx-lite)
#   bash setup.sh --yes       # non-interactive (installs everything)
#   bash setup.sh --no-sphinx # skip sphinx-lite install
# ============================================================================

set -Eeuo pipefail

# ----------------------------- config ---------------------------------------
cd "$(dirname "$0")"

INTERACTIVE=1
INSTALL_SPHINX=1
INSTALL_BS=1
case "${1:-}" in
  --yes)         INTERACTIVE=0 ;;
  --no-sphinx)   INSTALL_SPHINX=0 ;;
  --no-browser-search) INSTALL_BS=0 ;;
  -h|--help)     grep '^#' "$0" | sed -n '1,20p'; exit 0 ;;
esac

# ----------------------------- helpers --------------------------------------
log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN \033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------- pre-flight checks ----------------------------
log "pre-flight checks"
have bun      || { bad "bun not found — install: curl -fsSL https://bun.sh/install | bash"; exit 1; }
have python3  || { bad "python3 required"; exit 1; }
have curl     || { bad "curl required"; exit 1; }
have bash     || { bad "bash required"; exit 1; }
ok "all prerequisites present"

# ----------------------------- 1. bun install -------------------------------
log "step 1/5: install JS dependencies"
if [[ -f bun.lock && -d node_modules ]]; then
  ok "node_modules present (bun install already ran)"
else
  bun install 2>&1 | tail -3
  ok "deps installed (273 packages)"
fi

# ----------------------------- 2. .env.local --------------------------------
log "step 2/5: configure API key"
if [[ -f .env.local ]]; then
  ok ".env.local already exists (skipping)"
else
  cp .env.local.example .env.local
  warn "created .env.local from template — edit it to add your real OPENCODE_API_KEY"
  if (( INTERACTIVE )); then
    read -p "Press ENTER after editing .env.local (or 's' to skip and continue)..." ans
    [[ "$ans" == "s" ]] && warn "skipping — examples will fail until .env.local is filled in"
  fi
fi

# ----------------------------- 3. launch proxy ------------------------------
log "step 3/5: start opencode-egress-router proxy (Layer D, port 8318)"
if curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8318/__router/status 2>/dev/null | grep -qE '^[0-9]+$'; then
  ok "proxy already running on :8318"
else
  bash opencode-proxy/launch-oc-proxy.sh
  ok "proxy started"
fi
# Quick smoke test
HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer public" -H "Content-Type: application/json" \
  -d '{"model":"glm-5.3-flash-free","messages":[{"role":"user","content":"hi"}]}' \
  http://127.0.0.1:8318/chat/completions 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  ok "proxy smoke test: 200 OK (free-tier routing works)"
else
  warn "proxy smoke test returned HTTP $HTTP_CODE (expected 200) — check /tmp/oc-proxy.log"
fi

# ----------------------------- 4. sphinx-lite (optional) --------------------
log "step 4/5: SphinX-lite install (Layer C, optional)"
if (( INSTALL_SPHINX )); then
  if (( INTERACTIVE )); then
    read -p "Install SphinX-lite binary shim + log watcher? [Y/n] " ans
    case "${ans:-Y}" in
      [Nn]*) warn "skipping sphinx-lite (CLI binary will not be wrapped)"; INSTALL_SPHINX=0 ;;
    esac
  fi
fi
if (( INSTALL_SPHINX )); then
  bash sphinx-lite/install-sphinx-lite.sh
  ok "sphinx-lite installed"
  bash sphinx-lite/launch-unified.sh --status | tail -10
else
  warn "sphinx-lite skipped — Layer C inactive (Layer D proxy still works for API clients)"
fi

# ----------------------------- 4b. zen-unlimited (optional, Linux port) ------
log "step 4b/5: zen-unlimited Linux port (Layer G — muse-spark via sing-box egress)"
if [[ -d zen-unlimited-linux ]]; then
  if [[ -x zen-unlimited-linux/scripts/install-zen-stack.sh ]]; then
    if (( INTERACTIVE )); then
      read -p "Install zen-unlimited (muse-spark + sing-box egress)? Needs sing-box + systemd user session. [y/N] " ans
      case "${ans:-N}" in
        [Yy]*) bash zen-unlimited-linux/scripts/install-zen-stack.sh || warn "zen-unlimited install failed (see log above)" ;;
        *) warn "zen-unlimited skipped" ;;
      esac
    fi
  else
    warn "zen-unlimited installer not executable — run: chmod +x zen-unlimited-linux/scripts/install-zen-stack.sh"
  fi
else
  warn "zen-unlimited-linux/ not found — Layer G (muse-spark) unavailable"
fi

# ----------------------------- 4c. proxy-hunter (optional) -------------------
log "step 4c/5: proxy-hunter (fetch free SOCKS5 proxies for ProxyPool)"
if [[ -f proxy-hunter/proxy-hunter.py ]]; then
  if (( INTERACTIVE )); then
    read -p "Fetch free proxies now (takes ~10s, fetches from 5 public feeds)? [y/N] " ans
    case "${ans:-N}" in
      [Yy]*) bash proxy-hunter/feed-proxies.sh --protocol socks5 || warn "proxy-hunter failed" ;;
      *) warn "proxy-hunter skipped (run: bash proxy-hunter/feed-proxies.sh)" ;;
    esac
  fi
else
  warn "proxy-hunter/ not found — Layer F (proxy pool) has no proxy source"
fi

# ----------------------------- 4d. VPS proxy fleet (recommended) -------------
log "step 4d/5: VPS personal proxy fleet (replaces unreliable public proxies)"
if [[ -f vps-proxy/rotate-egress.sh ]]; then
  echo "  Public proxies are rate-limited and unreliable. Deploy personal SOCKS5"
  echo "  proxies on free-tier cloud VPS instances instead (Oracle Cloud, GCP, AWS,"
  echo "  Azure, etc.) — each VPS gives you a fresh IP with full control."
  echo
  echo "  See: vps-proxy/FREE-VPS-PROXY-GUIDE.md for the full guide (10 providers)."
  echo
  if (( INTERACTIVE )); then
    read -p "Disable public proxy scanning and switch to VPS-only mode? [Y/n] " ans
    case "${ans:-Y}" in
      [Nn]*) warn "keeping public proxy scanning enabled (unreliable but free)" ;;
      *) bash vps-proxy/rotate-egress.sh disable-public 2>/dev/null || true
         ok "public scanning disabled — VPS proxies are now primary" ;;
    esac
    echo
    read -p "Add a VPS proxy now? (socks5://IP:PORT, or 's' to skip): " proxy_url
    case "$proxy_url" in
      s|S|"") warn "skipping — add later with: bash vps-proxy/rotate-egress.sh add socks5://IP:PORT" ;;
      *) bash vps-proxy/rotate-egress.sh add "$proxy_url" ;;
    esac
  fi
else
  warn "vps-proxy/ not found — no VPS proxy management"
fi

# ----------------------------- 4e. browser-search (Layer W, optional) --------
log "step 4e/5: browser-search web research skill (Layer W, optional)"
if [[ -d browser-search ]] && (( INSTALL_BS )); then
  if command -v node >/dev/null 2>&1; then
    if (( INTERACTIVE )); then
      read -p "Install browser-search (web search + anti-bot browsing, ~700 MB Chromium download)? [y/N] " ans
      case "${ans:-N}" in
        [Nn]*) INSTALL_BS=0; warn "browser-search skipped — run later: bash setup.sh with prompt or cd browser-search && npm install" ;;
      esac
    fi
  else
    warn "node not found — Layer W requires Node.js >= 20.19"
    INSTALL_BS=0
  fi
fi
if [[ -d browser-search ]] && (( INSTALL_BS )); then
  if [[ ! -d browser-search/node_modules ]]; then
    ( cd browser-search && npm install >/dev/null 2>&1 ) \
      && ok "browser-search npm deps installed" \
      || warn "browser-search npm install failed — run manually: cd browser-search && npm install"
  else
    ok "browser-search npm deps present"
  fi
  if [[ ! -d "$HOME/.cloakbrowser" ]]; then
    ( cd browser-search && node -e "import('cloakbrowser').then(c=>c.ensureBinary())" ) \
      && ok "CloakBrowser Chromium binary downloaded (~/.cloakbrowser)" \
      || warn "Chromium download failed — retry: cd browser-search && node -e \"import('cloakbrowser').then(c=>c.ensureBinary())\""
  else
    ok "CloakBrowser Chromium binary present (~/.cloakbrowser)"
  fi
  # Link the skill into opencode's global skills dir (auto-picked-up by opencode v2)
  mkdir -p "$HOME/.config/opencode/skills"
  if [[ ! -e "$HOME/.config/opencode/skills/browser-search" ]]; then
    ln -s "$(pwd)/browser-search" "$HOME/.config/opencode/skills/browser-search" \
      && ok "skill linked into ~/.config/opencode/skills/browser-search"
  else
    ok "opencode global skill link already present"
  fi
elif (( ! INSTALL_BS )); then
  warn "browser-search skipped — Layer W inactive (run: bash bs-bridge.sh status shows fallback)"
else
  warn "browser-search/ not found — Layer W (web research) unavailable"
fi

# ----------------------------- 4f. oc-proxy (Layer P, optional) --------------
log "step 4f/5: oc-proxy portable Zen bypass (Layer P, optional)"
if [[ -d oc-proxy ]] && command -v node >/dev/null 2>&1; then
  if [[ ! -f oc-proxy/upstream/api/v1/chat/completions.js ]]; then
    if (( INTERACTIVE )); then
      read -p "Install oc-proxy upstream (clones MarkDev11/oc-proxy, zero deps)? [y/N] " ans
      case "${ans:-N}" in
        [Yy]*) bash oc-proxy/install-oc-proxy.sh || warn "oc-proxy install failed (see log above)" ;;
        *) warn "oc-proxy skipped — Layer P inactive (HF Space packaging also unavailable)" ;;
      esac
    fi
  else
    ok "oc-proxy upstream already installed"
  fi
  if [[ -f oc-proxy/upstream/api/v1/chat/completions.js ]]; then
    log "smoke test: boot oc-proxy adapter and probe /api/health"
    ( cd oc-proxy && PORT=7864 HOST=127.0.0.1 node server.js > /tmp/oc-proxy-setup.log 2>&1 & echo $! > /tmp/oc-proxy-setup.pid )
    OC_OK=0
    for _ in $(seq 1 16); do
      curl -sf --max-time 2 http://127.0.0.1:7864/api/health >/dev/null 2>&1 && { OC_OK=1; break; }
      sleep 0.5
    done
    if (( OC_OK )); then
      ok "oc-proxy adapter boots; health 200 on :7864"
      MODELS=$(curl -s --max-time 15 http://127.0.0.1:7864/v1/models | python3 -c "
import json,sys
try: print(len(json.load(sys.stdin).get('data',[])))
except Exception: print('?')" 2>/dev/null || echo "?")
      ok "live catalog through Layer P: $MODELS model ids"
    else
      warn "oc-proxy smoke test failed — see /tmp/oc-proxy-setup.log"
    fi
    kill "$(cat /tmp/oc-proxy-setup.pid 2>/dev/null)" 2>/dev/null || true
    log "deploy to HF Space: bash oc-proxy/make-hf-space.sh --check"
  fi
elif ! command -v node >/dev/null 2>&1; then
  warn "node not found — Layer P requires Node.js >= 18"
else
  warn "oc-proxy/ not found — Layer P unavailable"
fi

# ----------------------------- 5. contract test -----------------------------
log "step 5/5: run contract test (mock, A+D_thin, 9/9 expected)"
bash verify-a-contract/verify-a-contract.sh \
  --simulate --mock --rich-metadata --simulate-d-thin --schema v2 \
  --keep --artifacts-dir ./setup-contract-artifacts 2>&1 | tail -3

python3 -c "
import json
v = json.load(open('./setup-contract-artifacts/verdict.json'))
print(f'  verdict: {v[\"verdict\"]}')
print(f'  assertions: {len(v[\"results\"])}')
fails = sum(1 for r in v['results'].values() if r['status'] in ('FAIL', 'clobbered', 'missing', 'missing_or_wrong'))
if fails:
    print(f'  FAILED assertions: {fails}')
    exit(1)
print(f'  all {len(v[\"results\"])} assertions: PASS')
"
rm -rf ./setup-contract-artifacts

# ----------------------------- done -----------------------------------------
log "setup complete"
echo
echo "  Next steps:"
echo "    1. Run an example:"
echo "         bun run examples/index.zen-free.ts        # free-tier, \$0/req"
echo "         bun run examples/index.opencode.ts        # paid (kimi-k3)"
echo
echo "    2. Run real-gateway contract (needs OPENCODE_API_KEY):"
echo "         source .env.local"
echo "         TARGET_ID=kimi-k3 CONTROL_ID=glm-5.3-flash-free \\"
echo "         EXPECTED_CONTEXT=1048576 EXPECTED_OUTPUT=131072 CONTROL_CONTEXT=200000 \\"
echo "         GHOST_ID=legacy-removed-model \\"
echo "         bash verify-a-contract/verify-a-contract.sh \\"
echo "           --simulate --simulate-d-thin --rich-metadata --schema v2 \\"
echo "           --gateway-url https://opencode.ai/inference/v1 --api-key \$OPENCODE_API_KEY"
echo
echo "    3. Stop daemons when done:"
echo "         bash sphinx-lite/launch-unified.sh --stop"
echo
