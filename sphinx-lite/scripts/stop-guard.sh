#!/usr/bin/env bash
# Stops the zen_guard daemon.
set -e
PID_FILE="$HOME/.local/share/opencode-unlimited/guard/guard.pid"
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  kill "$(cat "$PID_FILE")" && rm -f "$PID_FILE"
  echo "stopped zen_guard daemon"
else
  pkill -f "zen_guard.py" 2>/dev/null && echo "stopped zen_guard daemon" || echo "zen_guard not running"
fi
