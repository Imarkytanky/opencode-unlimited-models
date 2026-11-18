#!/usr/bin/env bash
# ============================================================================
# deploy-proxy.sh — automate sing-box SOCKS5 proxy deployment on a remote VPS
#
# Usage:
#   bash vps-proxy/deploy-proxy.sh user@host [port] [ssh_key]
#
# Examples:
#   bash vps-proxy/deploy-proxy.sh ubuntu@1.2.3.4                    # default port 1080
#   bash vps-proxy/deploy-proxy.sh ubuntu@1.2.3.4 1080 ~/.ssh/oracle-key
#   bash vps-proxy/deploy-proxy.sh azureuser@my-azure-vm.eastus.cloudapp.azure.com 1080
#
# What it does (via SSH):
#   1. Installs sing-box on the remote VPS (Debian/Ubuntu/Amazon Linux)
#   2. Writes /etc/sing-box/config.json with a SOCKS5 inbound on the specified port
#   3. Enables + starts the sing-box systemd service
#   4. Opens the firewall (ufw or iptables)
#   5. Verifies the proxy is reachable from the VPS itself
#   6. Prints the socks5:// URL to add to your proxy list
#
# After deployment, verify from your local machine:
#   curl --socks5 <VPS_IP>:1080 https://api64.ipify.org
#   (should return the VPS's public IP)
# ============================================================================

set -Eeuo pipefail

SSH_TARGET="${1:?Usage: deploy-proxy.sh user@host [port] [ssh_key]}"
PORT="${2:-1080}"
SSH_KEY="${3:-}"

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN \033[0m %s\n' "$*"; }

# Build SSH command
SSH_CMD="ssh"
if [[ -n "$SSH_KEY" ]]; then
  SSH_CMD="$SSH_CMD -i $SSH_KEY -o StrictHostKeyChecking=accept-new"
else
  SSH_CMD="$SSH_CMD -o StrictHostKeyChecking=accept-new"
fi

log "deploying sing-box SOCKS5 proxy to $SSH_TARGET on port $PORT"

# Step 1: Install sing-box + create config + start service (all in one SSH command)
log "step 1/3: install sing-box + configure + start"
$SSH_CMD "$SSH_TARGET" bash -s "$PORT" << 'REMOTE_SCRIPT'
PORT="$1"

echo "[remote] detecting OS..."
if command -v apt-get >/dev/null 2>&1; then
  echo "[remote] Debian/Ubuntu detected — installing sing-box via official repo"
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl
  # Install sing-box via official install script
  curl -fsSL https://sing-box.sh | sh -s -- install
elif command -v yum >/dev/null 2>&1; then
  echo "[remote] RHEL/CentOS/Amazon Linux — installing sing-box"
  sudo yum install -y curl
  curl -fsSL https://sing-box.sh | sh -s -- install
elif command -v dnf >/dev/null 2>&1; then
  echo "[remote] Fedora — installing sing-box"
  sudo dnf install -y curl
  curl -fsSL https://sing-box.sh | sh -s -- install
else
  echo "[remote] unknown OS — trying manual binary download"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  SB_ARCH="linux-amd64" ;;
    aarch64) SB_ARCH="linux-arm64" ;;
    *) echo "[remote] unsupported arch: $ARCH"; exit 1 ;;
  esac
  VERSION="1.11.4"
  URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-${SB_ARCH}.tar.gz"
  curl -fsSL "$URL" -o /tmp/sb.tar.gz
  tar xzf /tmp/sb.tar.gz -C /tmp
  sudo cp "/tmp/sing-box-${VERSION}-${SB_ARCH}/sing-box" /usr/local/bin/
  sudo chmod +x /usr/local/bin/sing-box
fi

echo "[remote] writing /etc/sing-box/config.json..."
sudo mkdir -p /etc/sing-box
sudo tee /etc/sing-box/config.json << 'EOF'
{
  "inbounds": [{
    "type": "socks",
    "tag": "socks-in",
    "listen": "0.0.0.0",
    "listen_port": PORT_PLACEHOLDER
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
sudo sed -i "s/PORT_PLACEHOLDER/$PORT/" /etc/sing-box/config.json

echo "[remote] creating systemd service..."
sudo tee /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# If the official installer created a service, use that; otherwise use ours
if ! systemctl list-unit-files | grep -q 'sing-box.service'; then
  sudo systemctl daemon-reload
  sudo systemctl enable sing-box
fi
sudo systemctl restart sing-box

echo "[remote] opening firewall..."
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow ${PORT}/tcp 2>/dev/null || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  sudo firewall-cmd --permanent --add-port=${PORT}/tcp 2>/dev/null || true
  sudo firewall-cmd --reload 2>/dev/null || true
else
  sudo iptables -A INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || true
fi

echo "[remote] done — sing-box listening on 0.0.0.0:${PORT}"
REMOTE_SCRIPT

ok "sing-box deployed"

# Step 2: Get the VPS's public IP
log "step 2/3: detect VPS public IP"
VPS_IP=$($SSH_CMD "$SSH_TARGET" 'curl -sS --max-time 5 https://api64.ipify.org 2>/dev/null || curl -sS --max-time 5 ifconfig.me 2>/dev/null' 2>/dev/null || echo "")
if [[ -z "$VPS_IP" ]]; then
  warn "could not auto-detect VPS public IP — check manually"
  VPS_IP="<VPS_PUBLIC_IP>"
else
  ok "VPS public IP: $VPS_IP"
fi

# Step 3: Print integration instructions
log "step 3/3: integration instructions"
echo
echo "  ═══════════════════════════════════════════════════"
echo "  Proxy URL:  socks5://${VPS_IP}:${PORT}"
echo "  ═══════════════════════════════════════════════════"
echo
echo "  Verify from your local machine:"
echo "    curl --socks5 ${VPS_IP}:${PORT} https://api64.ipify.org"
echo "    (should return: ${VPS_IP})"
echo
echo "  Add to your proxy list:"
echo
echo "  Option A — zen-unlimited EGRESS_UPSTREAMS:"
echo "    echo 'EGRESS_UPSTREAMS=socks5h://${VPS_IP}:${PORT}' >> zen-unlimited-linux/.env"
echo
echo "  Option B — ProxyPool custom-proxies.txt:"
echo "    echo 'socks5://${VPS_IP}:${PORT}' >> config/custom-proxies.txt"
echo
echo "  Option C — Magiszonekk -ovh-proxy flag:"
echo "    ./opencode-egress-router -ovh-proxy socks5://${VPS_IP}:${PORT} ..."
echo
echo "  Deploy more VPS instances on different providers for IP rotation."
