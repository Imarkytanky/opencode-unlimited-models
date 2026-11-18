#!/usr/bin/env bash
# ============================================================================
# launch-unified.sh
#
# Unified launcher for the opencode unlimited-models stack.
# Detects what's available and starts the right combination:
#
#   1. SphinX-lite (binary shim + log watcher + auto-resume)
#      → wraps the opencode CLI in an unshare -rm namespace
#      → watches opencode.log for rate-limit patterns
#      → dispatches auto-resume when a wall is hit
#      → requires: ~/.local/share/opencode-unlimited/ (installed by install-sphinx-lite.sh)
#
#   2. Magiszonekk opencode-egress-router (Zen free-tier gate bypass)
#      → listens on 127.0.0.1:8318
#      → rewrites free-tier model requests to pass Zen's gate
#      → requires: opencode-proxy/opencode-egress-router (Go binary)
#
#   3. Both (recommended) — they operate at different layers:
#      SphinX-lite handles /64 + edge rotation for the CLI
#      opencode-egress-router handles gate bypass for any OpenAI-compatible client
#
# Usage:
#   bash launch-unified.sh                # start everything available
#   bash launch-unified.sh --check        # show what would be started, exit
#   bash launch-unified.sh --status       # show status of running components
#   bash launch-unified.sh --stop         # stop all daemons
#   bash launch-unified.sh --restart      # restart all daemons
# ============================================================================

set -Eeuo pipefail

# ----------------------------- paths ----------------------------------------
SPHINX_DEST="${HOME}/.local/share/opencode-unlimited"
SPHINX_RUN="${SPHINX_DEST}/scripts/run-guard.sh"
SPHINX_STOP="${SPHINX_DEST}/scripts/stop-guard.sh"
SPHINX_STATUS="${SPHINX_DEST}/scripts/status.sh"

# Resolve paths relative to the bundle root (parent of sphinx-lite/)
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROXY_BIN="${PROXY_BIN:-$BUNDLE_ROOT/opencode-proxy/opencode-egress-router}"
PROXY_LAUNCH="${PROXY_LAUNCH:-$BUNDLE_ROOT/opencode-proxy/launch-oc-proxy.sh}"
PROXY_PID_FILE="/tmp/oc-proxy.pid"

# ----------------------------- helpers --------------------------------------
log()  { printf '\033[1;34m[unified]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN \033[0m %s\n' "$*"; }

# ----------------------------- detect what's available ----------------------
detect() {
  SPHINX_AVAILABLE=0
  PROXY_AVAILABLE=0

  if [[ -x "$SPHINX_RUN" && -d "$SPHINX_DEST/src" ]]; then
    SPHINX_AVAILABLE=1
  fi

  if [[ -x "$PROXY_BIN" ]] || [[ -x "$PROXY_LAUNCH" ]]; then
    PROXY_AVAILABLE=1
  fi
}

is_running_sphinx() {
  local pid_file="${SPHINX_DEST}/guard/guard.pid"
  [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

is_running_proxy() {
  [[ -f "$PROXY_PID_FILE" ]] && kill -0 "$(cat "$PROXY_PID_FILE")" 2>/dev/null
}

# ----------------------------- actions --------------------------------------
start_sphinx() {
  if is_running_sphinx; then
    ok "SphinX-lite guard: already running (pid $(cat "${SPHINX_DEST}/guard/guard.pid"))"
    return 0
  fi
  if (( SPHINX_AVAILABLE )); then
    bash "$SPHINX_RUN"
    ok "SphinX-lite guard: started"
  else
    warn "SphinX-lite: not installed (run scripts/install-sphinx-lite.sh)"
  fi
}

start_proxy() {
  if is_running_proxy; then
    ok "opencode-egress-router: already running (pid $(cat "$PROXY_PID_FILE"))"
    return 0
  fi
  if (( PROXY_AVAILABLE )); then
    if [[ -x "$PROXY_LAUNCH" ]]; then
      bash "$PROXY_LAUNCH"
      ok "opencode-egress-router: started"
    else
      # Direct binary launch (sandbox fallback)
      setsid bash -c "trap '' HUP INT TERM; $PROXY_BIN -listen 127.0.0.1:8318 -upstream https://opencode.ai/zen/v1 -ovh-proxy '' -cooldown 60s > /tmp/oc-proxy.log 2>&1" </dev/null >/dev/null 2>&1 &
      echo $! > "$PROXY_PID_FILE"
      disown 2>/dev/null || true
      sleep 1
      ok "opencode-egress-router: started (direct binary, pid $(cat "$PROXY_PID_FILE"))"
    fi
  else
    warn "opencode-egress-router: binary not found (expected at $PROXY_BIN)"
  fi
}

stop_sphinx() {
  if is_running_sphinx; then
    bash "$SPHINX_STOP" 2>/dev/null && ok "SphinX-lite guard: stopped"
  else
    ok "SphinX-lite guard: not running"
  fi
}

stop_proxy() {
  if is_running_proxy; then
    kill "$(cat "$PROXY_PID_FILE")" 2>/dev/null && ok "opencode-egress-router: stopped"
    rm -f "$PROXY_PID_FILE"
  else
    ok "opencode-egress-router: not running"
  fi
}

show_status() {
  log "status"
  echo
  echo "  SphinX-lite (binary shim + log watcher + auto-resume):"
  if (( SPHINX_AVAILABLE )); then
    if is_running_sphinx; then
      local pid=$(cat "${SPHINX_DEST}/guard/guard.pid")
      local uptime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
      ok "guard RUNNING (pid $pid, uptime $uptime)"
    else
      warn "guard STOPPED (shim still installed at ~/.local/bin/opencode)"
    fi
    [[ -x "$HOME/.local/bin/opencode" ]] && ok "shim installed" || warn "shim missing"
  else
    bad "not installed (run scripts/install-sphinx-lite.sh)"
  fi
  echo
  echo "  opencode-egress-router (Zen free-tier gate bypass):"
  if (( PROXY_AVAILABLE )); then
    if is_running_proxy; then
      ok "proxy RUNNING (pid $(cat "$PROXY_PID_FILE"), port 8318)"
    else
      warn "proxy STOPPED"
    fi
  else
    bad "binary not found (expected at $PROXY_BIN)"
  fi
  echo
  echo "  Recommended client config:"
  echo "    opencode CLI (paid models via oc_sk_ key):"
  echo "      → direct to https://opencode.ai/inference/v1 (no proxy needed)"
  echo "    opencode CLI (free models via Zen):"
  echo "      → already wrapped by the shim (SphinX-lite)"
  echo "    AI SDK / external clients (free models via Zen):"
  echo "      → set baseURL to http://127.0.0.1:8318 (opencode-egress-router)"
}

# ----------------------------- main -----------------------------------------
detect
case "${1:-start}" in
  start|--start|"")
    log "starting unified stack"
    start_sphinx
    start_proxy
    echo
    show_status
    ;;
  --check)
    log "detection (dry-run)"
    echo "  SphinX-lite available: $SPHINX_AVAILABLE"
    echo "  opencode-egress-router available: $PROXY_AVAILABLE"
    echo
    if (( SPHINX_AVAILABLE && PROXY_AVAILABLE )); then
      ok "BOTH components available — recommended: run with no args"
    elif (( SPHINX_AVAILABLE )); then
      warn "only SphinX-lite available (no proxy) — CLI free-tier routing works, AI SDK does not"
    elif (( PROXY_AVAILABLE )); then
      warn "only proxy available (no SphinX-lite) — AI SDK works, CLI free-tier routing needs the shim"
    else
      bad "neither available — run install-sphinx-lite.sh and ensure $PROXY_BIN exists"
    fi
    ;;
  --status|status)
    show_status
    ;;
  --stop|stop)
    log "stopping unified stack"
    stop_sphinx
    stop_proxy
    ;;
  --restart|restart)
    log "restarting unified stack"
    stop_sphinx
    stop_proxy
    sleep 1
    start_sphinx
    start_proxy
    echo
    show_status
    ;;
  -h|--help)
    grep '^#' "$0" | sed -n '1,40p'
    ;;
  *)
    bad "unknown command: $1"
    echo "usage: $0 [--check|--status|--stop|--restart]"
    exit 1
    ;;
esac
