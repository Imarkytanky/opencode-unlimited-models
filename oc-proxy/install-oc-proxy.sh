#!/usr/bin/env bash
# ============================================================================
# install-oc-proxy.sh — fetch upstream oc-proxy for Layer P
#
# oc-proxy upstream (MarkDev11/oc-proxy) has NO LICENSE file (all rights
# reserved by default). This stack therefore does NOT redistribute its code;
# it is cloned here, at install time, into oc-proxy/upstream/ (gitignored).
# The adapter (server.js), Dockerfile generator, and contract test are this
# stack's own code and ship normally.
#
# Usage:
#   bash oc-proxy/install-oc-proxy.sh            # clone or update upstream/
#   bash oc-proxy/install-oc-proxy.sh --check    # syntax-check + verify wiring only
#   OC_PROXY_REF=main bash oc-proxy/install-oc-proxy.sh   # pin a branch/tag/SHA
# ============================================================================
set -Eeuo pipefail

cd "$(dirname "$0")"

REF="${OC_PROXY_REF:-master}"
UP="upstream"
REPO="https://github.com/MarkDev11/oc-proxy"

log()  { printf '\033[1;34m[oc-proxy]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

if [[ "${1:-}" == "--check" ]]; then
  if [[ ! -f "$UP/api/v1/chat/completions.js" ]]; then
    bad "upstream not installed — run: bash oc-proxy/install-oc-proxy.sh"
    exit 1
  fi
  ( cd "$UP" && npm run --silent check ) >/dev/null 2>&1 || {
    ( cd "$UP" && node --check lib/opencode.js && node --check "api/v1/chat/completions.js" ) || { bad "upstream syntax check failed"; exit 1; }
  }
  node --check server.js || { bad "server.js syntax error"; exit 1; }
  ok "upstream handlers + server.js syntax OK"
  exit 0
fi

have git || { bad "git required"; exit 1; }
have node || { bad "node >= 18 required (native fetch)"; exit 1; }

if [[ -d "$UP/.git" ]]; then
  log "upstream already cloned — updating to origin/$REF"
  git -C "$UP" fetch --depth 1 origin "$REF" 2>/dev/null || true
  git -C "$UP" checkout -q FETCH_HEAD 2>/dev/null || true
else
  log "cloning $REPO (ref: $REF) -> $UP/"
  rm -rf "$UP"
  git clone --depth 1 --branch "$REF" "$REPO" "$UP" 2>/dev/null \
    || git clone --depth 1 "$REPO" "$UP"   # fall back to default branch
fi

# Record provenance (the exact commit we run against)
git -C "$UP" rev-parse HEAD > "$UP/.upstream-commit" 2>/dev/null || true
git -C "$UP" log -1 --format="%H %cI %s" > "$UP/.upstream-provenance" 2>/dev/null || true

# Upstream ships zero dependencies — nothing to npm install. Verify syntax.
log "verifying upstream syntax (npm run check)"
if ( cd "$UP" && npm run --silent check ); then
  ok "upstream handlers: syntax OK"
else
  bad "upstream syntax check failed — upstream may have changed; pin a known-good ref:"
  bad "  OC_PROXY_REF=2a41370 bash oc-proxy/install-oc-proxy.sh"
  exit 1
fi

node --check server.js && ok "server.js adapter: syntax OK"

# License notice
if [[ ! -f "$UP/LICENSE" ]]; then
  log "NOTE: upstream has no LICENSE file — code stays in upstream/ (gitignored),"
  log "      is NOT redistributed in this stack's tarball, and is used here for"
  log "      local interoperability testing with attribution in NOTICE."
fi

COMMIT=$(cat "$UP/.upstream-commit" 2>/dev/null || echo "unknown")
log "installed oc-proxy upstream at commit ${COMMIT:0:12}"
log "next steps:"
log "  node oc-proxy/server.js                    # serve on :7860 (HF convention)"
log "  bash verify-oc-proxy.sh                    # Layer P contract test"
log "  bash oc-proxy/make-hf-space.sh             # assemble ready-to-push HF Space"
