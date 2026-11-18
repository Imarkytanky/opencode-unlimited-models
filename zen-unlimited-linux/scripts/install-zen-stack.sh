#!/usr/bin/env bash
# ============================================================================
# install-zen-stack.sh — Linux (Omarchy/Arch) port of install-zen-stack.ps1
#
# Replaces the Windows PowerShell scheduled-task installer with systemd user
# units. Designed for Omarchy (Arch Linux + Hyprland) but works on any Linux
# with systemd and a user session (XDG_RUNTIME_DIR set).
#
# Creates 3 systemd user units (staggered boot, mirrors the Windows PT1M/2M/3M):
#   oc-singbox.service  — sing-box egress (Hysteria2 nodes :1081-:1086)
#   oc-relay.service    — round-robin SOCKS relay :1090
#   oc-gateway.service  — zen-unlimited gateway :20128
#
# Plus 1 watchdog unit (mirrors the Windows PT5M self-heal):
#   oc-watchdog.timer   — runs oc-watchdog.service every 5 min to restart dead procs
#
# Usage:
#   bash scripts/install-zen-stack.sh              # install + start
#   bash scripts/install-zen-stack.sh --dry-run    # show what would be created
#   bash scripts/install-zen-stack.sh --uninstall # remove all units
#
# Prerequisites:
#   - systemd user session (XDG_RUNTIME_DIR set; check with `systemctl --user status`)
#   - bun >= 1.3.14, node >= 22, sing-box >= 1.14.0
#   - Repo at $REPO_ROOT (auto-detected from this script's location)
# ============================================================================

set -Eeuo pipefail

# ----------------------------- config ---------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"
LOG_DIR="${HOME}/.local/share/opencode-zen-unlimited/logs"
PID_DIR="${HOME}/.local/state/opencode-zen-unlimited"

# Resolve binary paths (systemd user units don't inherit user PATH on Arch)
BUN_BIN="${BUN_BIN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}"
NODE_BIN="${NODE_BIN:-$(command -v node || echo "/usr/bin/node")}"
SINGBOX_BIN="${SINGBOX_BIN:-$(command -v sing-box || echo "$REPO_ROOT/bin/sing-box")}"

DRY_RUN=0
UNINSTALL=0
case "${1:-}" in
  --dry-run)    DRY_RUN=1 ;;
  --uninstall)  UNINSTALL=1 ;;
  -h|--help)    grep '^#' "$0" | sed -n '1,30p'; exit 0 ;;
esac

# ----------------------------- helpers --------------------------------------
log()  { printf '\033[1;34m[zen-stack]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN \033[0m %s\n' "$*"; }

# ----------------------------- uninstall mode ------------------------------
if (( UNINSTALL )); then
  log "uninstalling systemd user units"
  for unit in oc-singbox oc-relay oc-gateway oc-watchdog; do
    systemctl --user stop "$unit.service" 2>/dev/null || true
    systemctl --user stop "$unit.timer" 2>/dev/null || true
    systemctl --user disable "$unit.service" "$unit.timer" 2>/dev/null || true
    rm -f "$UNIT_DIR/$unit.service" "$UNIT_DIR/$unit.timer"
    ok "removed $unit"
  done
  systemctl --user daemon-reload
  ok "daemon-reload complete"
  exit 0
fi

# ----------------------------- pre-flight checks ----------------------------
log "pre-flight checks"
[[ -d "$REPO_ROOT/src" ]] || { bad "repo not found at $REPO_ROOT"; exit 1; }
[[ -x "$BUN_BIN" ]]       || { bad "bun not found (set BUN_BIN or install from bun.sh)"; exit 1; }
[[ -x "$NODE_BIN" ]]      || { bad "node >=22 not found (set NODE_BIN)"; exit 1; }

if [[ ! -x "$SINGBOX_BIN" ]]; then
  warn "sing-box not found at $SINGBOX_BIN"
  log "fetching sing-box for Linux (run scripts/get-singbox.sh manually to pin a version)..."
  if [[ -f "$SCRIPT_DIR/get-singbox.sh" ]]; then
    bash "$SCRIPT_DIR/get-singbox.sh" || warn "sing-box fetch failed — install manually: pacman -S sing-box"
  else
    warn "get-singbox.sh not found — install sing-box manually: pacman -S sing-box"
  fi
fi

# Verify systemd user session
if ! systemctl --user status >/dev/null 2>&1; then
  bad "systemd user session not available (XDG_RUNTIME_DIR not set)"
  log "on a headless VPS, enable user lingering: sudo loginctl enable-linger $USER"
  exit 1
fi
ok "systemd user session available"

mkdir -p "$UNIT_DIR" "$LOG_DIR" "$PID_DIR"

if (( DRY_RUN )); then
  log "DRY RUN — would create:"
  echo "  $UNIT_DIR/oc-singbox.service"
  echo "  $UNIT_DIR/oc-relay.service"
  echo "  $UNIT_DIR/oc-gateway.service"
  echo "  $UNIT_DIR/oc-watchdog.service"
  echo "  $UNIT_DIR/oc-watchdog.timer"
  echo "  REPO_ROOT=$REPO_ROOT"
  echo "  BUN_BIN=$BUN_BIN"
  echo "  NODE_BIN=$NODE_BIN"
  echo "  SINGBOX_BIN=$SINGBOX_BIN"
  exit 0
fi

# ----------------------------- create systemd units -------------------------
log "creating systemd user units"

# 1. sing-box (starts first, PT1M equivalent = After=network-online.target)
cat > "$UNIT_DIR/oc-singbox.service" <<EOF
[Unit]
Description=OpenCode Zen Unlimited — sing-box egress (Hysteria2 nodes :1081-1086)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_ROOT}
ExecStart=${SINGBOX_BIN} run -C ${REPO_ROOT}/sing-box
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_DIR}/singbox.log
StandardError=append:${LOG_DIR}/singbox.log
Environment=HOME=${HOME}

[Install]
WantedBy=default.target
EOF
ok "wrote oc-singbox.service"

# 2. relay (starts second, PT2M equivalent = After=oc-singbox.service)
cat > "$UNIT_DIR/oc-relay.service" <<EOF
[Unit]
Description=OpenCode Zen Unlimited — round-robin SOCKS relay :1090
After=oc-singbox.service

[Service]
Type=simple
WorkingDirectory=${REPO_ROOT}
ExecStart=${NODE_BIN} ${REPO_ROOT}/src/relay/rr-socks.mjs
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_DIR}/relay.log
StandardError=append:${LOG_DIR}/relay.log
Environment=HOME=${HOME}
EnvironmentFile=-${REPO_ROOT}/.env

[Install]
WantedBy=default.target
EOF
ok "wrote oc-relay.service"

# 3. gateway (starts third, PT3M equivalent = After=oc-relay.service)
cat > "$UNIT_DIR/oc-gateway.service" <<EOF
[Unit]
Description=OpenCode Zen Unlimited — gateway :20128
After=oc-relay.service

[Service]
Type=simple
WorkingDirectory=${REPO_ROOT}
ExecStart=${BUN_BIN} run ${REPO_ROOT}/src/index.ts serve
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_DIR}/gateway.log
StandardError=append:${LOG_DIR}/gateway.log
Environment=HOME=${HOME}
EnvironmentFile=-${REPO_ROOT}/.env

[Install]
WantedBy=default.target
EOF
ok "wrote oc-gateway.service"

# 4. watchdog (PT5M equivalent — self-heal every 5 min)
cat > "$UNIT_DIR/oc-watchdog.service" <<EOF
[Unit]
Description=OpenCode Zen Unlimited — watchdog (restart dead services)

[Service]
Type=oneshot
ExecStart=${BUN_BIN} run ${REPO_ROOT}/src/index.ts status --self-heal
Environment=HOME=${HOME}
EnvironmentFile=-${REPO_ROOT}/.env
EOF
ok "wrote oc-watchdog.service"

cat > "$UNIT_DIR/oc-watchdog.timer" <<EOF
[Unit]
Description=OpenCode Zen Unlimited — 5min watchdog timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
ok "wrote oc-watchdog.timer"

# ----------------------------- reload + enable + start ----------------------
log "reloading systemd + enabling units"
systemctl --user daemon-reload
ok "daemon-reload"

for unit in oc-singbox oc-relay oc-gateway; do
  systemctl --user enable "$unit.service" 2>&1 | tail -1
done
systemctl --user enable oc-watchdog.timer 2>&1 | tail -1
ok "units enabled (auto-start on login)"

# Start in order (sing-box, relay, gateway) — mirrors the Windows staggered boot
log "starting services in order"
for unit in oc-singbox oc-relay oc-gateway; do
  systemctl --user start "$unit.service" 2>&1 | tail -1
  sleep 2
done
systemctl --user start oc-watchdog.timer 2>&1 | tail -1
ok "all services started"

# ----------------------------- verify ---------------------------------------
log "verification"
sleep 3
echo
systemctl --user status oc-singbox.service --no-pager 2>&1 | head -5
echo
systemctl --user status oc-relay.service --no-pager 2>&1 | head -5
echo
systemctl --user status oc-gateway.service --no-pager 2>&1 | head -5
echo
echo "  gateway health:"
curl -sS --max-time 5 http://127.0.0.1:20128/api/health 2>&1 | head -c 200
echo
echo
echo "  /v1/models:"
curl -sS --max-time 5 http://127.0.0.1:20128/v1/models 2>&1 | head -c 300
echo
echo
log "install complete"
echo
echo "  Useful commands:"
echo "    systemctl --user status oc-gateway    # check gateway"
echo "    systemctl --user restart oc-relay     # restart relay"
echo "    journalctl --user -u oc-gateway -f    # follow gateway logs"
echo "    bash $0 --uninstall                   # remove all units"
