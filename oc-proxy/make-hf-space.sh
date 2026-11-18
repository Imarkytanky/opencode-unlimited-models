#!/usr/bin/env bash
# ============================================================================
# make-hf-space.sh — assemble a ready-to-push Hugging Face Space for oc-proxy
#
# Output: dist/oc-proxy-hf-space/  (a complete Space repository)
#   README.md            HF frontmatter (sdk: docker, app_port: 7860) + docs
#   Dockerfile           node:20-slim, listens on 0.0.0.0:7860, zero npm deps
#   server.js            the standalone adapter (from this directory)
#   api/, lib/, public/, scripts/, package.json, .env.example
#                        upstream oc-proxy code (cloned by install-oc-proxy.sh)
#
# Deploy:
#   cd dist/oc-proxy-hf-space
#   git init && git add -A && git commit -m "oc-proxy Layer P"
#   git remote add space https://huggingface.co/spaces/<USER>/oc-proxy
#   git push space master   # or: hf upload / drag-drop in the browser
# Then set GATEWAY_API_KEY in Space settings -> Variables and secrets.
#
# Usage:
#   bash oc-proxy/make-hf-space.sh            # assemble
#   bash oc-proxy/make-hf-space.sh --check    # assemble + validate output
# ============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"

UP="upstream"
DIST="dist/oc-proxy-hf-space"

log()  { printf '\033[1;34m[hf-space]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }

[[ -f "$UP/api/v1/chat/completions.js" ]] || {
  bad "upstream not installed — run: bash oc-proxy/install-oc-proxy.sh"
  exit 1
}

log "assembling HF Space -> $DIST/"
rm -rf "$DIST"
mkdir -p "$DIST"

# 1. upstream code (api/, lib/, public/, scripts/, package.json, .env.example)
cp -r "$UP/api" "$UP/lib" "$UP/public" "$UP/scripts" "$DIST/"
cp "$UP/package.json" "$UP/.env.example" "$DIST/"
# provenance
if [[ -f "$UP/.upstream-provenance" ]]; then cp "$UP/.upstream-provenance" "$DIST/UPSTREAM_PROVENANCE"; fi

# 2. adapter
cp server.js "$DIST/server.js"

# 3. Dockerfile — HF Spaces Docker SDK
cat > "$DIST/Dockerfile" << 'EOF'
# Hugging Face Space — oc-proxy (Layer P)
# Thin OpenAI-compatible proxy for the opencode.ai free tier.
# Zero npm dependencies; Node >= 18 native fetch. Listens on 0.0.0.0:7860.
FROM node:20-slim

WORKDIR /app
COPY package.json ./
COPY api ./api
COPY lib ./lib
COPY public ./public
COPY scripts ./scripts
COPY server.js ./

ENV PORT=7860 \
    HOST=0.0.0.0 \
    NODE_ENV=production \
    OC_PROXY_UPSTREAM_DIR=/app

EXPOSE 7860

# No HEALTHCHECK needed — HF probes app_port itself.
CMD ["node", "server.js"]
EOF

# 4. Space README with HF frontmatter
COMMIT=$(cat "$UP/.upstream-provenance" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
cat > "$DIST/README.md" << EOF
---
title: oc-proxy
emoji: 🛡️
colorFrom: gray
colorTo: blue
sdk: docker
app_port: 7860
pinned: false
license: mit
short_description: OpenAI-compatible proxy for the opencode.ai free tier
---

# oc-proxy — OpenAI-compatible proxy for the opencode.ai free tier

Deployed here as **Layer P** of the opencode-unlimited-models stack, packaged
for Hugging Face Spaces instead of Vercel (no \`maxDuration\` hard-kill, so long
agentic runs survive; raise \`SOFT_DEADLINE_MS\` / \`ABSOLUTE_DEADLINE_MS\`).

Upstream: [MarkDev11/oc-proxy](https://github.com/MarkDev11/oc-proxy)
(commit ${COMMIT:0:12}). Vercel-free packaging by the
opencode-unlimited-models stack.

## Endpoints (same contract as upstream)

| Route | Method | Purpose |
|---|---|---|
| \`/v1/models\` | GET | live \`*-free\` model list (5 min cache) |
| \`/v1/chat/completions\` | POST | OpenAI-shaped chat (stream + non-stream) |
| \`/api/health\` | GET | health check |
| \`/\` | GET | live monitor dashboard |
| \`/api/stats\` | GET | stats JSON snapshot |

## Quick test

\`\`\`bash
BASE=https://<YOUR-USER>-oc-proxy.hf.space
curl \$BASE/api/health
curl \$BASE/v1/models | head -c 400
curl \$BASE/v1/chat/completions \\
  -H "Authorization: Bearer \$GATEWAY_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{"model":"oc/muse-spark-1.3-contributor-free","messages":[{"role":"user","content":"reply OK"}]}'
\`\`\`

## Configuration (Space settings -> Variables and secrets)

| Variable | Required | Notes |
|---|---|---|
| \`GATEWAY_API_KEY\` | strongly recommended | comma-separated keys; open access if unset — **do not expose publicly without it** |
| \`SOFT_DEADLINE_MS\` | no | default 50000; on HF raise (e.g. 300000) |
| \`ABSOLUTE_DEADLINE_MS\` | no | default 55000; on HF raise (e.g. 330000) |
| \`PROXY_FALLBACK\` | no | \`1\` enables 429-fallback via pooled proxies |
| \`PROXY_POOL_URL\` | no | pool JSON (upstream pool branch via jsDelivr) |
| \`UPSTREAM_BASE_URL\` | no | default \`https://opencode.ai\` |

## Caveats (inherited from upstream)

- Upstream free tier rate-limits aggressively (\`429 FreeUsageLimitError\`) — normal; retry with backoff.
- The decoy cloak spoofs the \`within OpenCode\` check. Upstream may block it at any time.
- Free Spaces sleep after 48h inactivity; in-memory stats reset on restart.
- Upstream oc-proxy has no LICENSE file — see UPSTREAM_PROVENANCE for the exact commit deployed.
EOF

# 5. .gitattributes not needed; add a minimal .gitignore for the Space
cat > "$DIST/.gitignore" << 'EOF'
node_modules/
.env
.env.local
EOF

ok "assembled $DIST"

if [[ "${1:-}" == "--check" ]]; then
  log "validating assembled Space"
  [[ -f "$DIST/Dockerfile" ]] && ok "Dockerfile present" || { bad "Dockerfile missing"; exit 1; }
  [[ -f "$DIST/README.md" ]] && head -1 "$DIST/README.md" | grep -q '^---' && ok "README frontmatter present" || { bad "README frontmatter missing"; exit 1; }
  grep -q 'sdk: docker' "$DIST/README.md" && ok "sdk: docker" || { bad "sdk missing"; exit 1; }
  grep -q 'app_port: 7860' "$DIST/README.md" && ok "app_port: 7860" || { bad "app_port missing"; exit 1; }
  grep -q 'CMD \["node", "server.js"\]' "$DIST/Dockerfile" && ok "CMD node server.js" || { bad "CMD missing"; exit 1; }
  grep -q 'EXPOSE 7860' "$DIST/Dockerfile" && ok "EXPOSE 7860" || { bad "EXPOSE missing"; exit 1; }
  node --check "$DIST/server.js" && ok "server.js syntax" || { bad "server.js syntax"; exit 1; }
  ( cd "$DIST" && node --check lib/opencode.js && node --check "api/v1/chat/completions.js" ) && ok "upstream syntax" || { bad "upstream syntax"; exit 1; }
  [[ -d "$DIST/public" ]] && ok "dashboard assets present" || { bad "public/ missing"; exit 1; }
  log "Space directory is ready to push to https://huggingface.co/new-space (sdk: docker)"
fi
