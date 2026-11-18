#!/usr/bin/env bash
# ============================================================================
# feed-proxies.sh — fetches free proxies via proxy-hunter.py and feeds them
# into ProxyPool's config/custom-proxies.txt
#
# This is the CLI equivalent of the browser tool at
# https://cmalf.github.io/web-tools/proxy-hunter/ — it replicates the sidebar
# "active feeds toggle all" + protocol filter + scanner functionality.
#
# Usage:
#   bash proxy-hunter/feed-proxies.sh                    # SOCKS5 only (default)
#   bash proxy-hunter/feed-proxies.sh --protocol all     # all protocols
#   bash proxy-hunter/feed-proxies.sh --protocol socks5,http
#   bash proxy-hunter/feed-proxies.sh --output /custom/path/proxies.txt
#   bash proxy-hunter/feed-proxies.sh --proxy-pool /path/to/ProxyPool
#
# What it does:
#   1. Runs proxy-hunter.py to fetch from 5 public feeds (Roosterkid, TheSpeedX, Hookzof)
#   2. Dedupes by (protocol, host, port)
#   3. Writes the result to ProxyPool's config/custom-proxies.txt
#   4. Prints instructions for restarting ProxyPool to pick up the new proxies
#
# Integration with ProxyPool:
#   ProxyPool reads config/custom-proxies.txt on startup and tests each proxy
#   against OpenCode Zen. Working proxies enter the personal tier (always
#   preferred over public proxies).
#
# Integration with zen-unlimited:
#   The fetched proxies can also be used as EGRESS_UPSTREAMS for zen-unlimited:
#     EGRESS_UPSTREAMS=$(bash proxy-hunter/feed-proxies.sh --format csv) bun run src/index.ts serve
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
PROTOCOL="socks5"
OUTPUT=""
PROXY_POOL_DIR=""
FORMAT="txt"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --protocol)    PROTOCOL="$2"; shift 2 ;;
    --output)      OUTPUT="$2"; shift 2 ;;
    --proxy-pool)   PROXY_POOL_DIR="$2"; shift 2 ;;
    --format)       FORMAT="$2"; shift 2 ;;
    -h|--help)      grep '^#' "$0" | sed -n '1,35p'; exit 0 ;;
    *)              echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# If no output specified, default to ProxyPool's custom-proxies.txt
if [[ -z "$OUTPUT" ]]; then
  if [[ -n "$PROXY_POOL_DIR" ]]; then
    OUTPUT="$PROXY_POOL_DIR/config/custom-proxies.txt"
  elif [[ -d "$BUNDLE_ROOT/proxy-pool" ]]; then
    OUTPUT="$BUNDLE_ROOT/proxy-pool/config/custom-proxies.txt"
  else
    OUTPUT="$BUNDLE_ROOT/proxy-hunter/custom-proxies.txt"
  fi
fi

echo "[feed-proxies] fetching $PROTOCOL proxies from public feeds..."
echo "[feed-proxies] output: $OUTPUT"
echo

# Run proxy-hunter.py
python3 "$SCRIPT_DIR/proxy-hunter.py" \
  --protocol "$PROTOCOL" \
  --format "$FORMAT" \
  --output "$OUTPUT" \
  --timeout 15

echo
echo "[feed-proxies] done. Proxies written to: $OUTPUT"
echo

# If ProxyPool is detected, print restart instructions
if [[ -d "$BUNDLE_ROOT/proxy-pool" ]] || [[ -n "$PROXY_POOL_DIR" ]]; then
  PP_DIR="${PROXY_POOL_DIR:-$BUNDLE_ROOT/proxy-pool}"
  echo "[feed-proxies] ProxyPool detected at: $PP_DIR"
  echo "[feed-proxies] to apply the new proxies, restart ProxyPool:"
  echo "  cd $PP_DIR"
  echo "  # stop existing: pkill -f 'node src/server.mjs'"
  echo "  # start: npm start"
  echo
  echo "[feed-proxies] ProxyPool will test each proxy against OpenCode Zen on startup."
  echo "[feed-proxies] Working proxies enter the personal tier (always preferred)."
fi
