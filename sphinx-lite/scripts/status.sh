#!/usr/bin/env bash
# Shows the status of the SphinX-lite installation.
set -e
echo "=== SphinX-lite status ==="
echo
echo "--- opencode shim ---"
if [[ -x "$HOME/.local/bin/opencode" ]]; then
  echo "  shim: $HOME/.local/bin/opencode"
  echo "  real binary: $HOME/.opencode/bin/opencode"
  echo "  shim version: $( $HOME/.local/bin/opencode --version 2>&1 | head -1 )"
else
  echo "  shim: NOT INSTALLED"
fi
echo
echo "--- zen_guard daemon ---"
if [[ -f "$HOME/.local/share/opencode-unlimited/guard/guard.pid" ]] && kill -0 "$(cat "$HOME/.local/share/opencode-unlimited/guard/guard.pid" 2>/dev/null; echo $?)" 2>/dev/null; then
  PID=$(cat "$HOME/.local/share/opencode-unlimited/guard/guard.pid")
  echo "  status: RUNNING (pid $PID)"
  echo "  uptime: $(ps -o etime= -p $PID 2>/dev/null | tr -d ' ')"
else
  echo "  status: STOPPED"
fi
echo
echo "--- guard log (last 5 lines) ---"
tail -5 "$HOME/.local/share/opencode-unlimited/guard/guard.log" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
echo
echo "--- opencode.log path being watched ---"
echo "  $HOME/.local/share/opencode/log/opencode.log"
ls -la "$HOME/.local/share/opencode/log/opencode.log" 2>/dev/null | awk '{print "  ", $5, "bytes,", $6, $7, $8}' || echo "  (log file not yet created — opencode hasn't run with logging yet)"
