#!/usr/bin/env bash
# ============================================================================
# install-sphinx-lite.sh
#
# Sandbox-aware installer for the SphinX (Opencode-Unlimited-Limit-Bypass-)
# components that can run WITHOUT warp-cli, /dev/net/tun, or root.
#
# What this installs:
#   1. The zen-lane.sh binary shim at ~/.local/bin/opencode (wraps the real
#      binary in an `unshare -rm` namespace with /etc/hosts and /etc/machine-id
#      overrides). Requires CAP_SYS_ADMIN inside a user namespace, which
#      most modern Linux kernels grant to unprivileged users.
#   2. The zen_guard.py log watcher as a background daemon (no systemd needed).
#      Tails opencode.log for rate-limit patterns.
#   3. The auto_resume.py module — invoked by zen_guard when a rate-limit is
#      detected, queries opencode.db's session_v2 table and dispatches
#      `opencode run --continue` to resume the active session.
#
# What this does NOT install (requires real VPS with root + /dev/net/tun):
#   - warp-cli (Cloudflare WARP daemon)
#   - systemd units (keeper + guard)
#   - sudoers entry for passwordless warp-cli
#   - The doctor's iptables leakguard check
#
# Coexistence with our existing bundle:
#   - This installer does NOT touch opencode.json — your existing config
#     (opencode provider + opencode-zen provider) keeps working unchanged.
#   - The shim wraps the BINARY, not the API. So your AI SDK examples
#     (which call opencode via the API directly) are unaffected.
#   - The Magiszonekk opencode-egress-router (port 8318) handles the
#     "from-within-OpenCode" gate bypass for non-CLI clients.
#   - SphinX's shim handles /64 + edge rotation for the CLI itself.
#   - They operate at different layers and don't conflict.
#
# Usage:
#   bash install-sphinx-lite.sh              # install everything possible
#   bash install-sphinx-lite.sh --check      # dry-run, show what would be done
#   bash install-sphinx-lite.sh --uninstall  # restore original opencode binary
# ============================================================================

set -Eeuo pipefail

# ----------------------------- config ---------------------------------------
# Bundle-relative default: try the sphinx-lite/src/ folder next to this script
# first, then fall back to a clone in $HOME/my-project/opencode-unlimited-sphinx
# (sandbox), then any path set via SPHINX_SRC env var.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SPHINX_SRC:-}" ]]; then
  if [[ -d "$SCRIPT_DIR/src" ]]; then
    SPHINX_SRC="$SCRIPT_DIR/src/.."   # bundle layout: sphinx-lite/src/ + sphx-lite/scripts/
  elif [[ -d "$HOME/my-project/opencode-unlimited-sphinx" ]]; then
    SPHINX_SRC="$HOME/my-project/opencode-unlimited-sphinx"
  else
    SPHINX_SRC="$SCRIPT_DIR"   # last-resort: assume script lives next to source
  fi
fi
DEST="${HOME}/.local/share/opencode-unlimited"
SHIM="${HOME}/.local/bin/opencode"
BACKUP="${DEST}/real-opencode-backup"
LANE_DIR="${DEST}/lane"
GUARD_DIR="${DEST}/guard"
LOG_FILE="${DEST}/install.log"

# Real opencode binary (will be wrapped by the shim)
REAL_OC="${OUC_REAL_BIN:-}"
if [[ -z "$REAL_OC" ]]; then
  for p in "${HOME}/.opencode/bin/opencode" \
           "${HOME}/.local/bin/opencode" \
           /usr/local/bin/opencode \
           /usr/bin/opencode; do
    if [[ -x "$p" && ! -L "$p" ]]; then
      REAL_OC="$p"; break
    fi
  done
fi

DRY_RUN=0
UNINSTALL=0
case "${1:-}" in
  --check)      DRY_RUN=1 ;;
  --uninstall)  UNINSTALL=1 ;;
  -h|--help)    grep '^#' "$0" | sed -n '1,40p'; exit 0 ;;
esac

# ----------------------------- helpers --------------------------------------
log()  { printf '\033[1;34m[sphinx-lite]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN \033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$DEST" "$LANE_DIR" "$GUARD_DIR" "${HOME}/.local/bin"

# ----------------------------- uninstall mode ------------------------------
if (( UNINSTALL )); then
  log "uninstall: restoring original opencode binary"
  if [[ -x "$BACKUP" ]]; then
    cp "$BACKUP" "$SHIM"
    chmod +x "$SHIM"
    ok "restored $SHIM from $BACKUP"
  else
    bad "no backup at $BACKUP — nothing to restore"
    log "to manually restore: install opencode via https://opencode.ai/install"
    exit 1
  fi
  pkill -f "zen_guard.py" 2>/dev/null && ok "stopped zen_guard daemon" || true
  rm -rf "$DEST"
  ok "removed $DEST"
  exit 0
fi

# ----------------------------- pre-flight checks ----------------------------
log "pre-flight checks"
[[ -d "$SPHINX_SRC" ]] || { bad "SphinX source not found at $SPHINX_SRC"; exit 1; }
[[ -n "$REAL_OC" ]]     || { bad "opencode binary not found; run: curl -fsSL https://opencode.ai/install | bash"; exit 1; }
have python3            || { bad "python3 required"; exit 1; }
have unshare            || { bad "unshare required (util-linux)"; exit 1; }
have dig                || warn "dig not found — zen-lane.sh will fall back to Python socket.getaddrinfo"
have psutil 2>/dev/null || pip install --quiet psutil 2>&1 || warn "psutil install failed — auto_resume won't run"

ok "SphinX source: $SPHINX_SRC"
ok "real opencode binary: $REAL_OC"
ok "DEST: $DEST"

# Test that unshare -rm + bind-mount works (the core zen-lane.sh requirement)
if unshare -rm bash -c 'mount --bind /etc/hostname /etc/hostname 2>/dev/null' 2>/dev/null; then
  ok "unshare -rm + bind-mount: WORKS (zen-lane.sh will function)"
else
  warn "unshare -rm bind-mount FAILED — zen-lane.sh will fall back to plain exec (no /etc/hosts override)"
  warn "(this is a sandbox restriction; on a real VPS it works)"
fi

if (( DRY_RUN )); then
  log "DRY RUN — no changes made"
  exit 0
fi

# ----------------------------- install shim ---------------------------------
log "installing zen-lane.sh shim at $SHIM"

# Back up the existing opencode binary (in case SHIM was already a real binary)
if [[ -x "$SHIM" && ! -L "$SHIM" && "$SHIM" != "$REAL_OC" ]]; then
  # SHIM was a real binary (not a symlink) — back it up
  cp "$SHIM" "$BACKUP"
  ok "backed up existing $SHIM to $BACKUP"
elif [[ -L "$SHIM" ]]; then
  warn "$SHIM is already a symlink — overwriting (no backup made)"
fi

# Copy zen-lane.sh and the SphinX scripts to DEST
mkdir -p "$DEST/scripts"
cp "$SPHINX_SRC/scripts/zen-lane.sh" "$DEST/scripts/"
chmod +x "$DEST/scripts/zen-lane.sh"
ok "installed $DEST/scripts/zen-lane.sh"

# Write the shim (matches install.sh:262 from upstream)
printf '#!/usr/bin/env bash\nexport OUC_REAL_BIN="%s"\nexec bash "%s/scripts/zen-lane.sh" "$@"\n' \
  "$REAL_OC" "$DEST" > "$SHIM"
chmod +x "$SHIM"
ok "wrote shim: $SHIM"
echo "  shim contents:"
sed 's/^/    /' "$SHIM"

# Verify shim works
if "$SHIM" --version >/dev/null 2>&1; then
  ok "shim self-test: $("$SHIM" --version 2>&1 | head -1)"
else
  bad "shim self-test FAILED"
  exit 1
fi

# ----------------------------- install guard + auto-resume ------------------
log "installing zen_guard.py + auto_resume.py (no systemd; runs as background daemon)"

# Copy the Python source (with patched paths for Linux)
mkdir -p "$DEST/src"
for f in ouc_common.py zen_guard.py auto_resume.py; do
  cp "$SPHINX_SRC/src/$f" "$DEST/src/"
done

# Patch ouc_common.py to use Linux-style paths if it has Windows paths
# (only patches if LOCAL_APPDATA is unset, which is the Linux case)
python3 - "$DEST/src/ouc_common.py" <<'PY'
import sys, re
path = sys.argv[1]
with open(path) as f:
  content = f.read()
# Add Linux path fallback after the LOCAL_APPDATA definition
patched = re.sub(
  r'(LOCAL_APPDATA = Path\(os\.environ\.get\("LOCALAPPDATA", Path\.home\(\) / "AppData" / "Local"\)\))',
  r'\1\n# Linux fallback: if LOCALAPPDATA is unset (Linux), use ~/.local/share\nif "LOCALAPPDATA" not in os.environ:\n    LOCAL_APPDATA = Path.home() / ".local" / "share"',
  content
)
if patched != content:
  with open(path, 'w') as f:
    f.write(patched)
  print(f"  patched {path}: added Linux path fallback")
else:
  print(f"  no patch needed for {path}")
PY

ok "installed Python source to $DEST/src/"

# ----------------------------- write launcher for guard ---------------------
cat > "$DEST/scripts/run-guard.sh" <<EOF
#!/usr/bin/env bash
# Launches zen_guard.py as a background daemon (replaces systemd unit).
# Logs to $GUARD_DIR/guard.log; PID file at $GUARD_DIR/guard.pid.
set -e
cd "$DEST/src"
export PYTHONPATH="$DEST/src"
export OUC_REAL_BIN="$REAL_OC"
mkdir -p "$GUARD_DIR"
nohup python3 -u zen_guard.py >> "$GUARD_DIR/guard.log" 2>&1 &
echo \$! > "$GUARD_DIR/guard.pid"
disown
EOF
chmod +x "$DEST/scripts/run-guard.sh"
ok "wrote $DEST/scripts/run-guard.sh"

# ----------------------------- write stop-guard.sh --------------------------
cat > "$DEST/scripts/stop-guard.sh" <<EOF
#!/usr/bin/env bash
# Stops the zen_guard daemon.
set -e
PID_FILE="$GUARD_DIR/guard.pid"
if [[ -f "\$PID_FILE" ]] && kill -0 "\$(cat "\$PID_FILE")" 2>/dev/null; then
  kill "\$(cat "\$PID_FILE")" && rm -f "\$PID_FILE"
  echo "stopped zen_guard daemon"
else
  pkill -f "zen_guard.py" 2>/dev/null && echo "stopped zen_guard daemon" || echo "zen_guard not running"
fi
EOF
chmod +x "$DEST/scripts/stop-guard.sh"
ok "wrote $DEST/scripts/stop-guard.sh"

# ----------------------------- write status-check.sh -----------------------
cat > "$DEST/scripts/status.sh" <<EOF
#!/usr/bin/env bash
# Shows the status of the SphinX-lite installation.
set -e
echo "=== SphinX-lite status ==="
echo
echo "--- opencode shim ---"
if [[ -x "$SHIM" ]]; then
  echo "  shim: $SHIM"
  echo "  real binary: $REAL_OC"
  echo "  shim version: \$( $SHIM --version 2>&1 | head -1 )"
else
  echo "  shim: NOT INSTALLED"
fi
echo
echo "--- zen_guard daemon ---"
if [[ -f "$GUARD_DIR/guard.pid" ]] && kill -0 "\$(cat "$GUARD_DIR/guard.pid" 2>/dev/null; echo \$?)" 2>/dev/null; then
  PID=\$(cat "$GUARD_DIR/guard.pid")
  echo "  status: RUNNING (pid \$PID)"
  echo "  uptime: \$(ps -o etime= -p \$PID 2>/dev/null | tr -d ' ')"
else
  echo "  status: STOPPED"
fi
echo
echo "--- guard log (last 5 lines) ---"
tail -5 "$GUARD_DIR/guard.log" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
echo
echo "--- opencode.log path being watched ---"
echo "  \$HOME/.local/share/opencode/log/opencode.log"
ls -la "\$HOME/.local/share/opencode/log/opencode.log" 2>/dev/null | awk '{print "  ", \$5, "bytes,", \$6, \$7, \$8}' || echo "  (log file not yet created — opencode hasn't run with logging yet)"
EOF
chmod +x "$DEST/scripts/status.sh"
ok "wrote $DEST/scripts/status.sh"

# ----------------------------- final summary --------------------------------
log "installation complete"
echo
echo "  Shim:        $SHIM"
echo "  Real binary: $REAL_OC"
echo "  Scripts:     $DEST/scripts/"
echo "  Python src:  $DEST/src/"
echo "  Guard log:   $GUARD_DIR/guard.log"
echo
echo "Next steps:"
echo "  1. Start the log watcher:"
echo "       $DEST/scripts/run-guard.sh"
echo "  2. Check status:"
echo "       $DEST/scripts/status.sh"
echo "  3. Run opencode (now wrapped by the shim):"
echo "       opencode --version"
echo "  4. Stop the daemon when done:"
echo "       $DEST/scripts/stop-guard.sh"
echo "  5. Uninstall (restores original binary):"
echo "       bash $0 --uninstall"
