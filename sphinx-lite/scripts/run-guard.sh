#!/usr/bin/env bash
# Launches zen_guard.py as a background daemon (replaces systemd unit).
# Uses the venv python3 (has psutil pre-installed).
set -e
cd "$HOME/.local/share/opencode-unlimited/src"
export PYTHONPATH="$HOME/.local/share/opencode-unlimited/src"
export OUC_REAL_BIN="$HOME/.opencode/bin/opencode"
export OUC_PYTHON="$HOME/.venv/bin/python3"
mkdir -p "$HOME/.local/share/opencode-unlimited/guard"
nohup "$OUC_PYTHON" -u zen_guard.py >> "$HOME/.local/share/opencode-unlimited/guard/guard.log" 2>&1 &
echo $! > "$HOME/.local/share/opencode-unlimited/guard/guard.pid"
disown
echo "zen_guard started (pid $(cat "$HOME/.local/share/opencode-unlimited/guard/guard.pid"))"
