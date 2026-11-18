#!/usr/bin/env bash
# Launches the opencode-egress-router as a fully-detached daemon.
# Re-running it kills any prior instance first.
set -e

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/opencode-egress-router"
LOG=/tmp/oc-proxy.log
PIDFILE=/tmp/oc-proxy.pid

# Kill any prior instance
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  sleep 0.5
fi
pkill -f opencode-egress-router 2>/dev/null || true
sleep 0.3

# Daemonize: setsid detaches from controlling terminal, & backgrounds,
# </dev/null closes stdin, &>log redirects all output, disown removes from job table.
# The trap of SIGHUP is belt-and-suspenders: even if the parent shell sends SIGHUP
# the proxy keeps running (it has no controlling terminal anyway via setsid).
setsid bash -c "
  trap '' HUP INT TERM
  exec $BIN \
    -listen 127.0.0.1:8318 \
    -upstream https://opencode.ai/zen/v1 \
    -ovh-proxy '' \
    -cooldown 60s \
    > '$LOG' 2>&1
" </dev/null >/dev/null 2>&1 &
PROXY_PID=$!
echo "$PROXY_PID" > "$PIDFILE"
disown 2>/dev/null || true

# Wait for the listen socket
for i in $(seq 1 20); do
  if curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8318/__router/status" 2>/dev/null | grep -qE '^[0-9]+$'; then
    echo "proxy up after ${i} tries (pid $PROXY_PID)"
    exit 0
  fi
  sleep 0.25
done

echo "proxy failed to bind after 5s" >&2
exit 1
