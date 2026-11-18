#!/usr/bin/env bash
# ============================================================================
# rotate-egress.sh — manages your VPS-deployed personal proxy fleet
#
# Provides a single command to:
#   - list all configured VPS proxies and their health
#   - add a new VPS proxy to the fleet
#   - remove a dead VPS proxy
#   - test all proxies (TCP connect + SOCKS5 handshake)
#   - generate the output file for zen-unlimited / ProxyPool / Magiszonekk
#   - disable public proxy scanning (ProxyPool's 422-source scan)
#
# Usage:
#   bash vps-proxy/rotate-egress.sh list                    # list all VPS proxies
#   bash vps-proxy/rotate-egress.sh add socks5://1.2.3.4:1080  # add a proxy
#   bash vps-proxy/rotate-egress.sh remove 1.2.3.4          # remove by IP
#   bash vps-proxy/rotate-egress.sh test                     # test all proxies
#   bash vps-proxy/rotate-egress.sh generate                 # generate output files
#   bash vps-proxy/rotate-egress.sh disable-public           # disable public scanning
#
# Proxy list file: vps-proxy/vps-proxies.txt (one URL per line)
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROXY_FILE="$SCRIPT_DIR/vps-proxies.txt"
LOCK_FILE="$SCRIPT_DIR/.public-scan-disabled"

log()  { printf '\033[1;34m[rotate]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN \033[0m %s\n' "$*"; }

mkdir -p "$SCRIPT_DIR"
touch "$PROXY_FILE"

case "${1:-list}" in

  # --- list ---
  list)
    log "VPS proxy fleet ($PROXY_FILE):"
    COUNT=0
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      COUNT=$((COUNT + 1))
      echo "  $COUNT: $line"
    done < "$PROXY_FILE"
    if [[ $COUNT -eq 0 ]]; then
      warn "no VPS proxies configured — add one:"
      echo "    bash $0 add socks5://1.2.3.4:1080"
    else
      echo
      echo "  total: $COUNT proxies"
    fi
    ;;

  # --- add ---
  add)
    URL="${2:?Usage: add socks5://IP:PORT}"
    # Check if already present
    if grep -qF "$URL" "$PROXY_FILE" 2>/dev/null; then
      warn "already in list: $URL"
      exit 0
    fi
    echo "$URL" >> "$PROXY_FILE"
    ok "added: $URL"
    echo
    log "fleet now has $(grep -cvE '^\s*#|^\s*$' "$PROXY_FILE") proxies"
    ;;

  # --- remove ---
  remove)
    IP="${2:?Usage: remove <IP>}"
    if grep -qF "$IP" "$PROXY_FILE" 2>/dev/null; then
      grep -vF "$IP" "$PROXY_FILE" > "$PROXY_FILE.tmp" && mv "$PROXY_FILE.tmp" "$PROXY_FILE"
      ok "removed all entries containing: $IP"
    else
      warn "not found: $IP"
    fi
    ;;

  # --- test ---
  test)
    log "testing all VPS proxies (TCP connect + SOCKS5 handshake)..."
    PASS=0; FAIL=0
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      # Extract protocol, host, port
      PROTO=$(echo "$line" | sed -E 's|^([a-z0-9]+)://.*|\1|')
      HOST=$(echo "$line" | sed -E 's|^[a-z0-9]+://||; s|:.*||')
      PORT=$(echo "$line" | sed -E 's|.*:||; s|/.*||')
      # TCP connect test (3s timeout)
      if timeout 3 bash -c "echo > /dev/tcp/$HOST/$PORT" 2>/dev/null; then
        # SOCKS5 handshake test (curl through the proxy)
        RESULT=$(curl -sS --max-time 8 --socks5 "$HOST:$PORT" https://api64.ipify.org 2>/dev/null || echo "FAIL")
        if [[ "$RESULT" == "FAIL" || -z "$RESULT" ]]; then
          bad "$line — TCP OK, SOCKS5 handshake failed"
          FAIL=$((FAIL + 1))
        else
          ok "$line — working (egress IP: $RESULT)"
          PASS=$((PASS + 1))
        fi
      else
        bad "$line — TCP connect failed (timeout/refused)"
        FAIL=$((FAIL + 1))
      fi
    done < "$PROXY_FILE"
    echo
    log "results: $PASS working, $FAIL failed"
    ;;

  # --- generate output files ---
  generate)
    log "generating output files for all integration targets..."
    # 1. zen-unlimited EGRESS_UPSTREAMS (comma-separated)
    EGRESS=$(grep -vE '^\s*#|^\s*$' "$PROXY_FILE" | tr '\n' ',' | sed 's/,$//')
    if [[ -n "$EGRESS" ]]; then
      echo "  EGRESS_UPSTREAMS=$EGRESS"
      echo "  → write to: zen-unlimited-linux/.env"
    fi
    echo
    # 2. ProxyPool custom-proxies.txt (one per line)
    echo "  custom-proxies.txt format:"
    grep -vE '^\s*#|^\s*$' "$PROXY_FILE" | sed 's/^/    /'
    echo "  → write to: proxy-pool/config/custom-proxies.txt"
    echo
    # 3. Magiszonekk flags
    echo "  Magiszonekk flags:"
    FIRST=1
    FLAG="-ovh-proxy"
    grep -vE '^\s*#|^\s*$' "$PROXY_FILE" | while IFS= read -r url; do
      echo "    $FLAG $url"
      if [[ $FIRST -eq 1 ]]; then FLAG="-oracle-proxy"; FIRST=0; else FLAG="-oracle2-proxy"; fi
    done
    ;;

  # --- disable public scanning ---
  disable-public)
    log "disabling public proxy scanning..."
    touch "$LOCK_FILE"

    # ProxyPool: disable the 422-source scan, keep personal proxies
    if [[ -d "$BUNDLE_ROOT/proxy-pool" ]]; then
      cat > "$BUNDLE_ROOT/proxy-pool/config/config.json" << 'EOF'
{
  "port": 8787,
  "bind": "localhost",
  "proxyEnabled": true,
  "v2rayEnabled": false,
  "scanMode": "off",
  "dashboard": true,
  "openAuth": true,
  "tray": false,
  "hideConsole": false
}
EOF
      ok "ProxyPool: scanMode=off (only personal proxies from custom-proxies.txt)"
    else
      warn "ProxyPool not found at $BUNDLE_ROOT/proxy-pool — skipping"
    fi

    # proxy-hunter: mark as disabled
    echo "Public proxy feeds disabled. Using VPS-deployed personal proxies only." > "$SCRIPT_DIR/.public-feeds-disabled"
    ok "proxy-hunter: public feeds disabled (use vps-proxy/rotate-egress.sh list to manage)"

    echo
    log "public scanning disabled — personal VPS proxies are now the primary egress"
    echo "  Next steps:"
    echo "    1. Deploy VPS proxies: see vps-proxy/FREE-VPS-PROXY-GUIDE.md"
    echo "    2. Add each VPS: bash $0 add socks5://<IP>:1080"
    echo "    3. Test them: bash $0 test"
    echo "    4. Generate configs: bash $0 generate"
    ;;

  # --- help ---
  -h|--help)
    grep '^#' "$0" | sed -n '1,30p'
    ;;

  *)
    bad "unknown command: $1"
    echo "usage: $0 {list|add|remove|test|generate|disable-public}"
    exit 1
    ;;
esac
