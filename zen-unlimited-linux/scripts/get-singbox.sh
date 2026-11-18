#!/usr/bin/env bash
# ============================================================================
# get-singbox.sh — Linux port of get-singbox.ps1
#
# Fetches the latest sing-box binary for Linux x86_64, SHA-256 verified.
# On Arch/Omarchy, prefers `pacman -S sing-box` if available.
#
# Lands the binary at $REPO_ROOT/bin/sing-box (matches the Windows .exe path
# convention so setup.ts:174 works unchanged: `join(projectRoot, "bin",
# platform === "win32" ? "sing-box.exe" : "sing-box")`).
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"
TARGET="$BIN_DIR/sing-box"

log()  { printf '\033[1;34m[get-singbox]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN \033[0m %s\n' "$*"; }

mkdir -p "$BIN_DIR"

# Already installed?
if [[ -x "$TARGET" ]]; then
  VERSION=$("$TARGET" version 2>&1 | head -1)
  ok "sing-box already present: $VERSION"
  exit 0
fi

# On Arch/Omarchy, try pacman first (sing-box is in the `extra` repo)
if command -v pacman >/dev/null 2>&1; then
  log "detected Arch/Omarchy — trying pacman -S sing-box"
  if sudo pacman -S --noconfirm sing-box 2>&1 | tail -5; then
    # Symlink the pacman-installed binary into the repo's bin/ dir
    ln -sf "$(command -v sing-box)" "$TARGET"
    ok "installed via pacman: $(sing-box version | head -1)"
    exit 0
  fi
  warn "pacman install failed, falling back to direct download"
fi

# Direct download from GitHub releases (Linux x86_64)
log "downloading sing-box for linux/amd64"
ARCH="linux-amd64"
LATEST_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

VERSION=$(curl -fsSL "$LATEST_URL" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['tag_name'].lstrip('v'))
" 2>/dev/null || echo "")

if [[ -z "$VERSION" ]]; then
  bad "could not determine latest sing-box version"
  exit 1
fi

TARBALL="sing-box-${VERSION}-${ARCH}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${TARBALL}"

log "version: $VERSION"
log "URL: $URL"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if ! curl -fsSL "$URL" -o "$TMPDIR/$TARBALL"; then
  bad "download failed"
  exit 1
fi

# Verify SHA-256 (sing-box ships a checksums file)
CHECKSUMS_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${TARBALL}.sha256"
if curl -fsSL "$CHECKSUMS_URL" -o "$TMPDIR/checksums.txt" 2>/dev/null; then
  EXPECTED=$(awk '{print $1}' "$TMPDIR/checksums.txt")
  ACTUAL=$(sha256sum "$TMPDIR/$TARBALL" | awk '{print $1}')
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    bad "SHA-256 mismatch (expected $EXPECTED, got $ACTUAL)"
    exit 1
  fi
  ok "SHA-256 verified"
else
  warn "no checksums file found, skipping verification"
fi

tar xzf "$TMPDIR/$TARBALL" -C "$TMPDIR"
cp "$TMPDIR/sing-box-${VERSION}-${ARCH}/sing-box" "$TARGET"
chmod +x "$TARGET"

ok "installed: $("$TARGET" version 2>&1 | head -1)"
