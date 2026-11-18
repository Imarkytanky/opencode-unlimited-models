# ============================================================================
# Dockerfile — Containerized opencode-unlimited-models stack
#
# Builds a single image containing ALL layers:
#   Layer B: opencode.json config
#   Layer A: opencode Console discovery (runtime, no daemon)
#   Layer C: sphinx-lite (binary shim + log watcher) — NOT included (needs host binary)
#   Layer D: opencode-egress-router (Go binary, Zen gate bypass) on :8318
#   Layer D_thin: reconcile.ts plugin (loaded by opencode at runtime)
#   Layer G: zen-unlimited (gateway :20128 + relay :1090) — sing-box NOT included
#   Layer W: browser-search (npm deps; Chromium binary NOT pre-downloaded, ~700 MB)
#
# Container exposes:
#   :8318   — opencode-egress-router (Magiszonekk proxy, free-tier Zen gate bypass)
#   :20128  — zen-unlimited gateway (muse-spark, /v1/responses)
#   :1090   — zen-unlimited round-robin SOCKS relay (for sing-box egress)
#   :8080   — SearXNG (when run in-container via native Python, see Layer W docs)
#   :9377   — Camofox (when run via docker compose --profile search)
#
# Usage with kiri:
#   kiri build -t opencode-unlimited .
#   kiri run -d --name oc-stack -p 8318:8318 -p 20128:20128 opencode-unlimited
#   curl http://localhost:8318/chat/completions ...   # free-tier Zen
#   curl http://localhost:20128/v1/models             # zen-unlimited models
#
# Usage with docker:
#   docker build -t opencode-unlimited .
#   docker run -d --name oc-stack -p 8318:8318 -p 20128:20128 opencode-unlimited
#
# Usage with docker compose (kiri compose / docker compose):
#   # See docker-compose.yml next to this file
#   kiri compose up -d
#   kiri compose --profile search up -d   # also starts SearXNG + Camofox
#
# Why containerize?
#   1. Solves portability: consistent /app paths inside the container, no /home/user variation
#   2. Solves dependency hell: bun + node + python3 + go all in one image
#   3. Solves daemon management: one container = one process supervisor (s6-overlay or supervisord)
#   4. kiri adds: 22ms container start, lower memory than Docker Desktop, native Docker API
#
# Layer C (sphinx-lite) is NOT included because it wraps the host's opencode
# binary. Run sphinx-lite on the host, and point opencode.json at the container's
# :8318 and :20128 ports instead.
#
# Layer W (browser-search): npm deps are installed at build time. The CloakBrowser
# Chromium binary (~700 MB) is NOT pre-downloaded to keep the image small — run
# `docker exec oc-stack bash -c "cd /app/browser-search && node -e 'import(\"cloakbrowser\").then(c=>c.ensureBinary())'"`
# once after first start, or use `docker compose --profile search up -d` for the
# separate SearXNG + Camofox containers (recommended for full 3-tier).
# ============================================================================

FROM oven/bun:1.3-debian AS base

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    python3 \
    python3-pip \
    nodejs \
    ca-certificates \
    supervisor \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ---- Layer D: opencode-egress-router (Go binary, pre-built) ----
COPY opencode-proxy/opencode-egress-router /app/opencode-proxy/opencode-egress-router
RUN chmod +x /app/opencode-proxy/opencode-egress-router

# ---- Layer G: zen-unlimited (TypeScript, needs bun install) ----
COPY zen-unlimited-linux/ /app/zen-unlimited-linux/
WORKDIR /app/zen-unlimited-linux
RUN bun install --frozen-lockfile 2>/dev/null || bun install
WORKDIR /app

# ---- Layer B: config ----
COPY config/opencode.json /app/config/opencode.json
COPY plugins/ /app/plugins/
WORKDIR /app/plugins
RUN bun add @opencode/plugin 2>/dev/null || true
WORKDIR /app

# ---- Layer D_thin: reconcile plugin tests ----
# (the plugin itself is loaded by opencode at runtime, not as a daemon)

# ---- Layer W: browser-search (web research skill, invoked on-demand) ----
# npm deps installed at build time (small). CloakBrowser Chromium binary (~700 MB)
# is NOT pre-downloaded — run `bun run bs:install` after first container start,
# or use `docker compose --profile search up -d` for the SearXNG + Camofox services.
COPY browser-search/ /app/browser-search/
WORKDIR /app/browser-search
RUN npm install --omit=dev 2>/dev/null || npm install
WORKDIR /app

# ---- Process supervisor config ----
RUN mkdir -p /var/log/supervisor
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# ---- Expose ports ----
# 8318  — Layer D (opencode-egress-router)
# 20128 — Layer G (zen-unlimited gateway)
# 1090  — Layer G (zen-unlimited SOCKS relay)
# 8080  — Layer W tier 1 (SearXNG, when run in-container natively)
# 9377  — Layer W tier 2 (Camofox, when run via docker compose --profile search)
EXPOSE 8318 20128 1090 8080 9377

# ---- Health check ----
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8318/__router/status || exit 1

# ---- Start the supervisor (manages both daemons) ----
CMD ["supervisord", "-n", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
