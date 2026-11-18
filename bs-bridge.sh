#!/usr/bin/env bash
# ============================================================================
# bs-bridge.sh — Layer F (proxy fleet) → Layer W (browser-search) glue
#
# browser-search's CloakBrowser accepts HTTP/SOCKS5 proxies:
#     node scripts/cloak/cloak-fetch.mjs --proxy socks5://host:port <url>
# The stack's Layer F (proxy-hunter + vps-proxy) maintains validated proxy
# lists. This bridge connects the two without modifying any upstream script.
#
# Usage:
#   bash bs-bridge.sh status                     # show proxy sources
#   bash bs-bridge.sh next                       # print next SOCKS5 proxy
#   bash bs-bridge.sh fetch <url> [cloak args]   # fetch via Layer F proxy
#   bash bs-bridge.sh fetch --direct <url>       # fetch without proxy
#
# Proxy source order (first found wins):
#   1. $BS_PROXY            — explicit override
#   2. vps-proxy/proxies.txt — personal VPS fleet (recommended)
#   3. proxy-hunter/custom-proxies.txt — public scraped proxies (last resort)
#
# Exit codes: 0 ok, 1 no proxy available, 2 fetch failed
# ============================================================================

set -Eeuo pipefail

BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$BRIDGE_DIR"          # bridge lives at the stack root
SKILL_DIR="$STACK_ROOT/browser-search"

log()  { printf '\033[1;34m[bs-bridge]\033[0m %s\n' "$*" >&2; }
bad()  { printf '\033[1;31m[bs-bridge]\033[0m %s\n' "$*" >&2; }

proxy_file() {
  if [[ -s "$STACK_ROOT/vps-proxy/proxies.txt" ]]; then
    echo "$STACK_ROOT/vps-proxy/proxies.txt"
  elif [[ -s "$STACK_ROOT/proxy-hunter/custom-proxies.txt" ]]; then
    echo "$STACK_ROOT/proxy-hunter/custom-proxies.txt"
  else
    echo ""
  fi
}

next_proxy() {
  # 1. explicit override
  if [[ -n "${BS_PROXY:-}" ]]; then
    echo "$BS_PROXY"
    return 0
  fi
  # 2./3. first validated socks5 line from the fleet files
  # (grep -m1: a `grep | head` pipe exits 141 under pipefail — head closes
  #  the pipe and SIGPIPE-kills grep — even when it printed a match)
  local pf
  pf="$(proxy_file)"
  if [[ -z "$pf" ]]; then
    return 1
  fi
  grep -m1 -E '^socks5://' "$pf" 2>/dev/null || return 1
}

cmd_status() {
  echo "Layer W ↔ Layer F bridge status"
  echo "  skill dir:      ${SKILL_DIR}"
  echo "  BS_PROXY:       ${BS_PROXY:-<unset>}"
  local pf
  pf="$(proxy_file)"
  if [[ -n "$pf" ]]; then
    local total socks
    total=$(grep -cE '^[a-z]+5?://' "$pf" 2>/dev/null || echo 0)
    socks=$(grep -cE '^socks5://' "$pf" 2>/dev/null || echo 0)
    echo "  proxy file:     $pf ($total proxies, $socks socks5)"
  else
    echo "  proxy file:     none (run: bash proxy-hunter/feed-proxies.sh)"
  fi
  if (cd "$SKILL_DIR" && node --input-type=module -e "import('cloakbrowser').then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>/dev/null); then
    echo "  cloakbrowser:   installed"
  else
    echo "  cloakbrowser:   NOT installed (run: cd browser-search && npm install, then ensureBinary)"
  fi
}

cmd_fetch() {
  local direct=0
  if [[ "${1:-}" == "--direct" ]]; then
    direct=1; shift
  fi
  local url="${1:-}"
  [[ -z "$url" ]] && { bad "usage: bs-bridge.sh fetch [--direct] <url> [cloak args]"; exit 2; }
  shift || true

  # Ensure cwd is the skill dir so node resolves its node_modules
  cd "$SKILL_DIR"

  if (( direct )); then
    log "fetch (direct): $url"
    exec node scripts/cloak/cloak-fetch.mjs "$url" "$@"
  fi

  local proxy
  if proxy="$(next_proxy)"; then
    log "fetch via Layer F proxy: $proxy"
    # URL must come FIRST: cloak-fetch.mjs picks the first non-flag arg as the
    # URL, so `--proxy socks5://... <url>` would treat the proxy as the target.
    exec node scripts/cloak/cloak-fetch.mjs "$url" --proxy "$proxy" "$@"
  else
    log "no Layer F proxy available (run: bash proxy-hunter/feed-proxies.sh) — falling back to direct"
    exec node scripts/cloak/cloak-fetch.mjs "$url" "$@"
  fi
}

case "${1:-}" in
  status) cmd_status ;;
  next)   next_proxy || { bad "no proxy available"; exit 1; } ;;
  fetch)  shift; cmd_fetch "$@" ;;
  -h|--help|"") grep '^#' "$0" | sed -n '2,25p' | sed 's/^# \?//' ;;
  *)      bad "unknown command: $1"; exit 2 ;;
esac
