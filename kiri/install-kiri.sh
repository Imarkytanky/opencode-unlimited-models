#!/usr/bin/env bash
# ============================================================================
# install-kiri.sh — installs kiri and runs the stack as containers
#
# What this does:
#   1. Downloads and installs kiri for Linux (.deb or manual extraction)
#   2. Starts the kiri daemon
#   3. Builds the opencode-unlimited Docker image
#   4. Starts the stack via kiri compose
#   5. Verifies all endpoints are up
#
# Usage:
#   bash kiri/install-kiri.sh              # full install + build + start
#   bash kiri/install-kiri.sh --check      # check if kiri is already installed
#   bash kiri/install-kiri.sh --start      # just start the stack (kiri already installed)
#   bash kiri/install-kiri.sh --stop       # stop the stack
#   bash kiri/install-kiri.sh --logs       # follow logs
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KIRI_VERSION="0.2.0"
KIRI_DEB_URL="https://download.runkiri.com/kiri_${KIRI_VERSION}_amd64.deb"
KIRI_LITE_DEB_URL="https://download.runkiri.com/kiri-lite_${KIRI_VERSION}_amd64.deb"

log()  { printf '\033[1;34m[kiri]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN \033[0m %s\n' "$*"; }

MODE="full"
case "${1:-}" in
  --check)  MODE="check" ;;
  --start)  MODE="start" ;;
  --stop)   MODE="stop" ;;
  --logs)   MODE="logs" ;;
  -h|--help) grep '^#' "$0" | sed -n '1,30p'; exit 0 ;;
esac

# --- check mode ---
if [[ "$MODE" == "check" ]]; then
  log "checking kiri installation"
  if command -v kiri >/dev/null 2>&1; then
    ok "kiri found: $(kiri --version 2>&1 | head -1 || echo 'installed')"
    kiri ps 2>&1 | head -5 || warn "kiri daemon not running — run: kiri daemon &"
  else
    bad "kiri not installed — run: bash $0"
  fi
  exit 0
fi

# --- stop mode ---
if [[ "$MODE" == "stop" ]]; then
  cd "$BUNDLE_ROOT"
  command -v kiri >/dev/null 2>&1 && { kiri compose down 2>&1 | tail -5; ok "stack stopped"; } || { bad "kiri not installed"; exit 1; }
  exit 0
fi

# --- logs mode ---
if [[ "$MODE" == "logs" ]]; then
  cd "$BUNDLE_ROOT"
  command -v kiri >/dev/null 2>&1 && { kiri compose logs -f; } || { bad "kiri not installed"; exit 1; }
  exit 0
fi

# --- start mode (kiri already installed) ---
if [[ "$MODE" == "start" ]]; then
  cd "$BUNDLE_ROOT"
  kiri compose up -d 2>&1 | tail -10
  ok "stack started"
  sleep 3
  curl -sS --max-time 5 http://127.0.0.1:8318/__router/status 2>&1 | head -c 100; echo
  curl -sS --max-time 5 http://127.0.0.1:20128/api/health 2>&1 | head -c 100; echo
  exit 0
fi

# --- full install mode ---
log "full install: kiri + build + start"

# Step 1: Install kiri
if command -v kiri >/dev/null 2>&1; then
  ok "kiri already installed"
else
  log "step 1/4: install kiri v${KIRI_VERSION}"
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  curl -fsSL "$KIRI_DEB_URL" -o "$TMPDIR/kiri.deb"
  dpkg-deb -x "$TMPDIR/kiri.deb" "$TMPDIR/kiri-extracted" 2>/dev/null
  sudo cp "$TMPDIR/kiri-extracted/usr/bin/kiri" /usr/local/bin/kiri 2>/dev/null
  sudo cp "$TMPDIR/kiri-extracted/usr/bin/kiri-init" /usr/local/bin/kiri-init 2>/dev/null
  sudo chmod +x /usr/local/bin/kiri /usr/local/bin/kiri-init 2>/dev/null

  if command -v kiri >/dev/null 2>&1; then
    ok "kiri installed"
  else
    bad "kiri install failed — download manually from https://runkiri.com/releases"
    exit 1
  fi
fi

# Step 2: Start kiri daemon
log "step 2/4: start kiri daemon"
if kiri ps >/dev/null 2>&1; then
  ok "kiri daemon already running"
else
  nohup kiri daemon > /tmp/kiri-daemon.log 2>&1 &
  echo $! > /tmp/kiri-daemon.pid
  sleep 3
  if kill -0 $(cat /tmp/kiri-daemon.pid) 2>/dev/null; then
    ok "kiri daemon running"
  else
    bad "kiri daemon failed — check /tmp/kiri-daemon.log"
    tail -10 /tmp/kiri-daemon.log
    exit 1
  fi
fi

# Step 3: Build
log "step 3/4: build opencode-unlimited image"
cd "$BUNDLE_ROOT"
kiri build -t opencode-unlimited:latest . 2>&1 | tail -10
ok "image built"

# Step 4: Start
log "step 4/4: start the stack"
kiri compose up -d 2>&1 | tail -10
ok "stack started"

sleep 5
log "verification:"
echo "  :8318 status: $(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8318/__router/status 2>/dev/null || echo 000)"
echo "  :20128 health: $(curl -sS --max-time 5 http://127.0.0.1:20128/api/health 2>/dev/null | head -c 50)"
echo
log "done — kiri integration complete"
