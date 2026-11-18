# Free Cloud VPS Personal Proxy Guide

**Date:** 2026-11-15
**Purpose:** Replace unreliable public proxies (rate-limited, shared, often down) with personal proxies you deploy on free-tier cloud VPS instances across different IPs and regions.

**Why personal proxies beat public proxies:**
- You control the IP reputation (not shared with spammers)
- No rate-limiting from other users on the same proxy
- Each VPS gives you a fresh /64 (IPv6) or unique IPv4 → fresh Zen quota
- 10 free VPS instances = 10 independent IP addresses = 10× the daily quota
- You choose the region (spread across countries for geo-diversity)

---

## The 10 free-tier cloud VPS providers

### Tier 1: Always-free, real VPS with SSH (best for proxies)

| # | Provider | Free tier | Specs | Region(s) | CC? | Notes |
|---|---|---|---|---|---|---|
| 1 | **Oracle Cloud** | Always Free (forever) | 4 ARM cores + 24 GB RAM (Ampere A1) OR 2 AMD VMs (1/8 OCPU, 1 GB each) | 30+ regions | Yes (not charged) | **Best overall.** ARM instance is the most generous free VPS. Often "Out of host capacity" — try ap-tokyo-1, us-phoenix-1, ap-mumbai-1. |
| 2 | **Google Cloud** | Always Free | 1× e2-micro (0.25 vCPU, 1 GB), 30 GB disk, 1 GB egress/mo | us-west1, us-central1, us-east1 | Yes | Reliable. 1 GB egress is tight — monitor. Only 3 US regions. |
| 3 | **AWS** | 12-month free | 750 hrs/mo t2.micro/t3.micro (1 vCPU, 1 GB) | 30+ regions | Yes | Expires after 12 months. Good for first year. |
| 4 | **Azure** | 12-month free | 750 hrs B1s (1 vCPU, 1 GB) | 60+ regions | Yes | Most regions. Expires after 12 months. |

### Tier 2: Free tier with limitations

| # | Provider | Free tier | Specs | Region(s) | CC? | Notes |
|---|---|---|---|---|---|---|
| 5 | **Fly.io** | Legacy: 3 micro VMs. New: ~$2/mo/VM | 256 MB shared-cpu-1x | 30+ regions | Yes | Legacy accounts get 3 free VMs in different regions = 3 proxy IPs. |
| 6 | **Koyeb** | Free (1 Eco service) | 512 MB, 0.1 vCPU | US, EU | No (GitHub) | Cold starts after inactivity. Use keep-alive pings. |
| 7 | **Render** | Free (web services) | 512 MB | US, EU, Asia | No (GitHub) | Cold starts after 15 min. Use HTTP proxy + keep-alive. |
| 8 | **Northflank** | Free Developer (2 services) | 0.2 vCPU, 256 MB | EU, US | No (GitHub) | Managed containers, no SSH. Run SOCKS5 as container. |

### Tier 3: Free compute, not traditional VPS (creative use)

| # | Provider | Free tier | Specs | Region(s) | CC? | Notes |
|---|---|---|---|---|---|---|
| 9 | **GitHub Codespaces** | 120 core-hours/mo (2-core VM) | 2 vCPU, 8 GB, 32 GB | US, EU, Asia | No | Dev environment, not VPS. Run SOCKS5 in tmux. Auto-stops after 30 min — use keep-alive. |
| 10 | **Cloudflare Workers** | 100K requests/day | V8 isolate (not a VM) | 300+ edge locations | No | HTTP-only proxy (no SOCKS5). Each request = different edge IP = auto-rotation. |

---

## Architecture: personal proxy fleet

```
Your machine (opencode v2)
  │
  ├── opencode-egress-router (:8318)     ← Layer D (Zen gate bypass)
  │     │
  │     └── -ovh-proxy points at:
  │           │
  │           ▼
  │     zen-unlimited relay (:1090)       ← Layer G (round-robin SOCKS)
  │           │
  │           ├── VPS-1: socks5://1.2.3.4:1080    (Oracle Cloud ARM, Tokyo)
  │           ├── VPS-2: socks5://5.6.7.8:1080    (GCP e2-micro, us-central1)
  │           ├── VPS-3: socks5://9.10.11.12:1080 (AWS t3.micro, Frankfurt)
  │           ├── VPS-4: socks5://13.14.15.16:1080 (Azure B1s, Singapore)
  │           └── ... (up to 10 VPS instances)
  │                 │
  │                 ▼
  │           opencode.ai/zen   (each VPS = different IP = fresh quota)
```

---

## Quick-start: deploy sing-box on any VPS (2 minutes)

After SSH access to any Linux VPS, run:

```bash
# 1. Install sing-box
curl -fsSL https://sing-box.sh | sh
# OR on Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y sing-box

# 2. Create config (SOCKS5 on port 1080)
sudo tee /etc/sing-box/config.json << 'EOF'
{
  "inbounds": [{
    "type": "socks",
    "tag": "socks-in",
    "listen": "0.0.0.0",
    "listen_port": 1080
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

# 3. Start + enable
sudo systemctl enable --now sing-box

# 4. Open firewall
sudo ufw allow 1080/tcp 2>/dev/null || sudo iptables -A INPUT -p tcp --dport 1080 -j ACCEPT

# 5. Verify from your local machine:
# curl --socks5 <VPS_PUBLIC_IP>:1080 https://api64.ipify.org
```

Or use the bundled automation script:
```bash
bash vps-proxy/deploy-proxy.sh user@<VPS_IP> 1080
```

---

## Provider-specific deployment steps

### 1. Oracle Cloud (best — 4 ARM cores, 24 GB RAM, forever free)

1. Sign up at https://cloud.oracle.com (credit card for verification, not charged)
2. Create **VM Standard.A1.Flex** (ARM):
   - OCPUs: 4, Memory: 24 GB (max always-free allocation)
   - Image: Ubuntu 22.04
   - Region: try ap-tokyo-1, us-phoenix-1, ap-mumbai-1 (avoid us-ashburn-1 — often at capacity)
3. SSH: `ssh -i ~/.ssh/oracle-key ubuntu@<IP>`
4. Run the sing-box quick-start above
5. Add to proxy list: `socks5://<IP>:1080`

**Tips:** If "Out of host capacity", change region or retry. You get 2 AMD VMs + 1 ARM VM = 3 IPs.

### 2. Google Cloud (e2-micro, forever free, 3 US regions)

1. Sign up at https://cloud.google.com/free
2. Create VM: e2-micro, Debian 12, us-west1/us-central1/us-east1, 30 GB disk
3. Add firewall rule: `gcloud compute firewall-rules create allow-socks5 --allow tcp:1080`
4. SSH: `gcloud compute ssh <instance-name>`
5. Run sing-box quick-start, add: `socks5://<IP>:1080`

**Limitation:** 1 GB egress/month — monitor with GCP Console.

### 3. AWS (t3.micro, 12 months free, 30+ regions)

1. Sign up at https://aws.amazon.com/free
2. Launch EC2: t3.micro, Ubuntu 22.04, any region
3. Security group: allow inbound TCP 1080 from 0.0.0.0/0
4. SSH: `ssh -i ~/.ssh/aws-key.pem ubuntu@<IP>`
5. Run sing-box quick-start, add: `socks5://<IP>:1080`

### 4. Azure (B1s, 12 months free, 60+ regions)

1. Sign up at https://azure.microsoft.com/free
2. Create VM: Standard_B1s, Ubuntu 22.04, any region
3. NSG inbound rule: allow TCP 1080
4. SSH: `ssh -i ~/.ssh/azure-key azureuser@<IP>`
5. Run sing-box quick-start, add: `socks5://<IP>:1080`

### 5. Fly.io (legacy: 3 free VMs, new: ~$2/mo/VM)

1. Install flyctl: `curl -L https://fly.io/install.sh | sh`
2. `fly launch --image ghcr.io/sagernet/sing-box:latest`
3. `fly deploy --vm-size shared-cpu-1x --vm-memory 256`
4. `fly ips allocate-v4`
5. Connect: `socks5://<FLY_V4_IP>:1080`

### 6. Koyeb (1 free Eco service, cold starts)

1. Sign up at https://koyeb.com (GitHub login)
2. Deploy Docker image `ghcr.io/sagernet/sing-box:latest`, port 1080, Eco instance
3. Keep-alive cron on your local machine: `*/5 * * * * curl -s --socks5 <url>:1080 http://checkip.amazonaws.com > /dev/null`

### 7. Render (free, cold starts after 15 min)

1. Sign up at https://render.com (GitHub login)
2. New Web Service from Docker image `ghcr.io/sagernet/sing-box:latest`, port 1080, Free tier
3. Use HTTP proxy mode (not SOCKS5) to survive cold starts, or add keep-alive pings every 10 min

### 8. Northflank (free Developer plan, 2 services)

1. Sign up at https://northflank.com (GitHub login)
2. Service from Docker image `ghcr.io/sagernet/sing-box:latest`, port 1080, Free plan

### 9. GitHub Codespaces (120 core-hours/mo, creative use)

1. Create a Codespace (2-core, 8 GB) at https://github.com/codespaces
2. In the terminal:
   ```bash
   curl -fsSL https://sing-box.sh | sh
   # Create config (see quick-start)
   tmux new -d -s proxy 'sing-box run -c /etc/sing-box/config.json'
   ```
3. Forward port 1080: Codespaces → Ports → forward 1080
4. Connect: `socks5://0.tcp.<region>.codespaces.io:1080`
5. Keep-alive cron inside codespace: `*/10 * * * * touch /tmp/keepalive`

### 10. Cloudflare Workers (100K req/day, edge HTTP proxy)

1. Sign up at https://workers.cloudflare.com
2. Create a Worker with HTTP forward proxy code
3. Deploy: `npx wrangler deploy`
4. Use: `http://<worker-name>.<subdomain>.workers.dev`
5. Each request goes through a different edge IP → automatic rotation

---

## Recommended deployment: 5 VPS (optimal)

For the best effort-to-quota ratio, deploy on these 5 (all free):

1. **Oracle Cloud ARM** (Tokyo) — 4 cores, 24 GB RAM
2. **GCP e2-micro** (us-central1) — stable, reliable
3. **AWS t3.micro** (Frankfurt) — EU IP
4. **Azure B1s** (Singapore) — Asia IP
5. **GitHub Codespaces** (2-core) — no credit card needed

= 5 IPs across 5 regions (JP, US, DE, SG, + Codespace region) at $0/mo.

---

## Integration with the opencode-unlimited stack

### Option A: zen-unlimited EGRESS_UPSTREAMS (Layer G)

```bash
# In zen-unlimited-linux/.env:
EGRESS_UPSTREAMS=socks5h://1.2.3.4:1080,socks5h://5.6.7.8:1080,socks5h://9.10.11.12:1080
```

### Option B: ProxyPool custom-proxies.txt (Layer F)

```bash
# In ProxyPool config/custom-proxies.txt:
socks5://1.2.3.4:1080
socks5://5.6.7.8:1080
socks5://9.10.11.12:1080
```

### Option C: Magiszonekk -ovh-proxy flag (Layer D → G chaining)

```bash
./opencode-egress-router \
  -listen 127.0.0.1:8318 \
  -upstream https://opencode.ai/zen/v1 \
  -ovh-proxy socks5://1.2.3.4:1080 \
  -oracle-proxy socks5://5.6.7.8:1080 \
  -oracle2-proxy socks5://9.10.11.12:1080 \
  -cooldown 60s
```

---

## What was disabled (public proxy scanning)

The following are now **disabled by default** — public proxies are rate-limited and unreliable:

1. **ProxyPool's 422-source public scan** → set `PROXY_ENABLED=0` to disable; only personal proxies from `custom-proxies.txt` are used
2. **proxy-hunter's public feeds** → kept as a fallback tool but not run automatically in `setup.sh`
3. **ProxyPool's V2Ray/Xray scanning** → set `V2RAY_ENABLED=0` unless you have subscription links

The personal-proxy path (VPS-deployed SOCKS5) is now the **primary** egress rotation strategy.
