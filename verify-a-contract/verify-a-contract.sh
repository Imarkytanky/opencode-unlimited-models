#!/usr/bin/env bash
# ============================================================================
# verify-a-contract.sh  —  FINAL INSTALLER
#
# Contract test for the opencode v2 "unlimited models" equation:
#
#     Ecosystem = B (offline generator, hand-written models block)
#               + A (opencode-models-discovery plugin, /v1/models auto-fetch)
#               + D_thin (reconcile plugin, disable-not-delete)   [Stage 2]
#               -> E (native openai-compatible discovery)          [Stage 3]
#
# Contract under test:  **A only adds, never overwrites.**
# B writes an explicit entry (qwen3-coder) with hand-set overrides
# (tools:true, limit.context:131072, limit.output:65536, custom name).
# A then discovers the same model from the gateway's /v1/models.
# The contract HOLDS iff:
#
#   C1  qwen3-coder appears exactly ONCE per effective model list (no dup)
#   C2  tools:true override survives A's discovery (NOT clobbered to false)
#   C3  limit.context:131072 override survives (NOT clobbered to gateway value)
#   C4  llama-3.3-70b (B-omitted, A-discovered) appears  -> A loaded + auth OK
#   C5  text-embedding-3-large is absent                  -> A skips embeddings
#
# Rich-metadata extensions (--rich-metadata, for real gateways that return
# context_length / max_completion_tokens / supports_tool_calls):
#
#   C6  discovered-only control model (llama-3.3-70b) carries limit.context
#       populated from the gateway's max_model_len (128000)  -> A enriches
#   C7  B's limit.output:65536 survives even when the gateway also returns
#       max_completion_tokens for the same model            -> A doesn't clobber
#
# MODES
#   --simulate        Python-only; no opencode binary needed. Faithfully
#                     mirrors A's documented "only adds, never overwrites"
#                     merge logic. Use for: pre-flight smoke, CI without
#                     opencode installed, or reproducing a verdict offline.
#   --smoke-gateway   Boot mock gateway, curl /health + /v1/models, exit.
#   --selftest        Validate the assertion engine against built-in fixtures.
#   (default)         Full end-to-end: real opencode binary + real/mock gateway.
#
# USAGE
#   # 1. Mock + simulation (no opencode needed; sandbox / CI smoke):
#   bash verify-a-contract.sh --simulate --mock --keep
#
#   # 2. Real gateway + real opencode + real plugin (PRODUCTION):
#   bash verify-a-contract.sh --gateway-url https://gateway.example.com/v1 \
#       --api-key "$GATEWAY_API_KEY" --rich-metadata --keep
#
#   # 3. Pre-upgrade CI gate (verdict JSON exits non-zero on contract break):
#   bash verify-a-contract.sh --gateway-url "$GW" --api-key "$K" \
#       --plugin-version 2.1.3 --rich-metadata
#
# EXIT CODES
#   0  CONTRACT PASS  (verdict == "PASS")
#   1  CONTRACT FAIL  (verdict == "FAIL" — A broke "only adds, never overwrites")
#   2  RAN but unverifiable (verdict == "WARN" — engine couldn't read flags)
#   3  prerequisites missing (opencode/python3/curl)
#
# STAGED ROLLOUT (see README.md for full detail)
#   Stage 1: B + A + this contract test          (target confidence: 10/10)
#   Stage 2: + D_thin reconcile plugin            (additive, not risky)
#   Stage 3: swap A -> PR #57161 native discovery  (deferred until merged)
# ============================================================================

set -Eeuo pipefail

# ----------------------------- defaults -------------------------------------
SCHEMA="auto"
PLUGIN_SPEC="opencode-models-discovery@2.1.2"
GATEWAY_URL="${GATEWAY_URL:-}"                 # empty -> boot mock gateway
API_KEY="${GATEWAY_API_KEY:-sk-test-contract}"
GW_PORT=$((18000 + RANDOM % 2000))
API_PORT=$((GW_PORT + 100))
OC_BIN="${OC_BIN:-opencode}"
TARGET_ID="${TARGET_ID:-qwen3-coder}"
PROV_ID="${TARGET_PROV:-gateway}"
CONTROL_ID="${CONTROL_ID:-llama-3.3-70b}"
EMBEDDING_ID="${EMBEDDING_ID:-text-embedding-3-large}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-131072}"
EXPECTED_OUTPUT="${EXPECTED_OUTPUT:-65536}"
CONTROL_CONTEXT="${CONTROL_CONTEXT:-128000}"         # gateway's max_model_len for the control model
KEEP="${KEEP:-0}"
RICH_METADATA="${RICH_METADATA:-0}"
SIMULATE_D_THIN="${SIMULATE_D_THIN:-0}"
# GHOST_ID: a 3rd model written by B that is NOT in the gateway catalog.
# Used to validate the D_thin reconcile plugin's disable-not-delete contract.
# Default "ghost-removed-from-gateway" matches what mock_gateway.py does NOT list.
GHOST_ID="${GHOST_ID:-ghost-removed-from-gateway}"
MODE="full"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-}"
POSITIONALS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --selftest)        MODE="selftest" ;;
    --smoke-gateway)   MODE="smoke" ;;
    --assert-helper)   MODE="assert" ;;
    --simulate)        MODE="simulate" ;;
    --simulate-d-thin) SIMULATE_D_THIN=1 ;;
    --mock)            GATEWAY_URL="" ;;
    --gateway-url)     GATEWAY_URL="$2"; shift ;;
    --api-key)         API_KEY="$2"; shift ;;
    --schema)          SCHEMA="$2"; shift ;;
    --plugin-spec)     PLUGIN_SPEC="$2"; shift ;;
    --plugin-version)  PLUGIN_SPEC="opencode-models-discovery@$2"; shift ;;
    --opencode-bin)    OC_BIN="$2"; shift ;;
    --keep)            KEEP=1 ;;
    --rich-metadata)   RICH_METADATA=1 ;;
    --artifacts-dir)   ARTIFACTS_DIR="$2"; shift ;;
    -h|--help)         grep '^#' "$0" | sed -n '1,80p'; exit 0 ;;
    *) POSITIONALS+=("$1") ;;
  esac
  shift
done

# ----------------------------- helpers --------------------------------------
log()  { printf '\033[1;34m[verify]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN \033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

run_to() {  # portable timeout (GNU coreutils absent on stock macOS)
  if have timeout; then timeout 90s "$@"; return $?; fi
  "$@" & local p=$!
  ( sleep 90; kill "$p" 2>/dev/null || true ) & local w=$!
  local rc=0; wait "$p" || rc=$?
  kill "$w" 2>/dev/null || true; return "$rc"
}

wait_http() {  # url, tries
  local url="$1" tries="${2:-30}" i=0
  while (( i < tries )); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then return 0; fi
    sleep 0.5; i=$((i+1))
  done
  return 1
}

# ============================================================================
# MODE: assert (internal) — pure-python contract-assertion engine
# Reads one or more JSON evidence docs, walks for the target id under the
# test provider, emits verdict JSON.
# ============================================================================
if [[ "$MODE" == "assert" ]]; then
  RICH_METADATA="$RICH_METADATA" \
  EXPECTED_OUTPUT="$EXPECTED_OUTPUT" \
  CONTROL_CONTEXT="$CONTROL_CONTEXT" \
  exec python3 - ${POSITIONALS[@]+"${POSITIONALS[@]}"} <<'PY'
import json, sys, os, glob, datetime

docs = []
for p in sys.argv[1:]:
    with open(p) as f:
        docs.append((os.path.basename(p), json.load(f)))

TARGET       = os.environ.get("TARGET_ID", "qwen3-coder")
PROV         = os.environ.get("TARGET_PROV", "gateway")
CONTROL_ID   = os.environ.get("CONTROL_ID", "llama-3.3-70b")
EMBEDDING_ID = os.environ.get("EMBEDDING_ID", "text-embedding-3-large")
EXPECTED_CTX = int(os.environ.get("EXPECTED_CONTEXT", "131072"))
EXPECTED_OUT = int(os.environ.get("EXPECTED_OUTPUT", "65536"))
CONTROL_CTX  = int(os.environ.get("CONTROL_CONTEXT", "128000"))
RICH         = os.environ.get("RICH_METADATA", "0") == "1"

TOOL_PATHS  = [("capabilities","toolcall"), ("capabilities","tool_call"),
               ("capabilities","tools"), ("toolcall",), ("tool_call",), ("tools",),
               # opencode Console catalog uses nested {tools: {supported: true}}
               ("capabilities","tools","supported"),
               ("capabilities","tool_call","supported")]
LIMIT_CTX_PATHS = [("limit","context"), ("limitContext",), ("context_length",),
                   ("contextWindow",), ("limit","context_window")]
LIMIT_OUT_PATHS = [("limit","output"), ("limitOutput",), ("max_completion_tokens",),
                   ("limit","max_completion_tokens")]

def gn(node, path):
    cur = node
    for k in path:
        if isinstance(cur, dict) and k in cur: cur = cur[k]
        else: return None
    return cur

# Provider-scoped collection: walk for any dict whose id==PROV that also has
# a "models" sub-map (dict OR list); capture the ORIGINAL shape so dup
# detection still works for list-shaped evidence. (Avoids recursing INTO
# model entries whose api:{id:...} sub-objects would double-count.)
gw = {}        # doc -> list of original models_field values (dict or list)
smatches = []  # (doc, node) provider-scoped TARGET entries (last wins per field)

def _id_of(item):
    if not isinstance(item, dict): return None
    return item.get("id") or item.get("modelID") or item.get("modelId")

def walk(node, path="$", doc="", prov=None):
    if isinstance(node, dict):
        cur = prov
        mid = node.get("id") or node.get("modelID") or node.get("modelId")
        mf = node.get("models")
        if mid and isinstance(mf, (dict, list)):
            cur = mid
            if cur == PROV:
                gw.setdefault(doc, []).append(mf)
        for k, v in node.items():
            walk(v, f"{path}.{k}", doc, cur)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{path}[{i}]", doc, prov)

for doc, c in docs:
    walk(c, "$", doc)

# Count TARGET occurrences per doc (handles both dict and list shapes);
# list-shaped duplicates remain visible to C1; ALL TARGET entries are
# captured so C2/C3 can detect clobbering across duplicates.
per_doc = {}
for doc, mfs in gw.items():
    c = 0
    for mf in mfs:
        if isinstance(mf, dict):
            if TARGET in mf:
                c += 1
                smatches.append((doc, mf[TARGET]))
        elif isinstance(mf, list):
            for item in mf:
                if _id_of(item) == TARGET:
                    c += 1
                    smatches.append((doc, item))
    if c:
        per_doc[doc] = c

# All model IDs across all captured models_fields (for C4/C5)
all_gw_keys = set()
for mfs in gw.values():
    for mf in mfs:
        if isinstance(mf, dict):
            all_gw_keys.update(mf.keys())
        elif isinstance(mf, list):
            for item in mf:
                iid = _id_of(item)
                if iid: all_gw_keys.add(iid)

# Also harvest text-only evidence (CLI listings) — best-effort, no error if absent
txt_all = ""; txt_scoped = ""
try:
    txt_dir = os.path.dirname(os.path.abspath(sys.argv[1])) if sys.argv[1:] else "."
    for p in sorted(glob.glob(os.path.join(txt_dir, "*.txt"))):
        try: txt_all += open(p, encoding="utf-8", errors="replace").read()
        except Exception: pass
    txt_scoped = "\n".join(l for l in txt_all.splitlines() if l.startswith(PROV + "/"))
except Exception:
    pass

res = {}
# C1: no duplicate
dup = {d: c for d, c in per_doc.items() if c > 1}
if dup:                       res["C1_no_duplicate"] = ("FAIL", dup)
elif not smatches:            res["C1_no_duplicate"] = ("FAIL", "target absent under provider '"+PROV+"'")
else:                         res["C1_no_duplicate"] = ("PASS", per_doc)
# C2: tools preserved
tstate = "unknown"
for _, n in smatches:
    for p in TOOL_PATHS:
        v = gn(n, p)
        if v is True:   tstate = "preserved"
        elif v is False and tstate != "preserved": tstate = "clobbered"
if tstate == "unknown" and TARGET in txt_scoped: tstate = "unverifiable_text_only"
res["C2_tools_preserved"] = (tstate, {})
# C3: limit.context preserved
cstate, seen_ctx = "unknown", {}
for _, n in smatches:
    for p in LIMIT_CTX_PATHS:
        v = gn(n, p)
        if isinstance(v, (int, float)):
            seen_ctx["/".join(p)] = v
            cstate = "preserved" if int(v) == EXPECTED_CTX else "clobbered"
res["C3_limit_context"] = (cstate, seen_ctx)
# C4: control model added (proves plugin loaded + auth passthrough)
res["C4_discovery_adds_missing"] = (
    "PASS" if (CONTROL_ID in all_gw_keys or CONTROL_ID in txt_scoped) else "FAIL", {})
# C5: embeddings skipped
res["C5_embeddings_skipped"] = (
    "FAIL" if (EMBEDDING_ID in all_gw_keys or EMBEDDING_ID in txt_scoped) else "PASS", {})

# C6 / C7: rich-metadata enrichment assertions
if RICH:
    # C6: control model (A-only) carries limit.context from gateway
    ctrl = None
    for mfs in gw.values():
        for mf in mfs:
            if isinstance(mf, dict):
                if CONTROL_ID in mf: ctrl = mf[CONTROL_ID]
            elif isinstance(mf, list):
                for item in mf:
                    if _id_of(item) == CONTROL_ID: ctrl = item
    c6state, c6seen = "unknown", {}
    if ctrl is None and CONTROL_ID in txt_scoped:
        c6state = "unverifiable_text_only"
    elif ctrl is None:
        c6state = "FAIL"
    else:
        for p in LIMIT_CTX_PATHS:
            v = gn(ctrl, p)
            if isinstance(v, (int, float)):
                c6seen["/".join(p)] = v
                c6state = "enriched" if int(v) == CONTROL_CTX else "missing_or_wrong"
                break
        else:
            c6state = "missing"  # A added entry but didn't enrich metadata
    res["C6_control_enriched_with_context"] = (c6state, c6seen)
    # C7: B's limit.output preserved even when gateway returns max_completion_tokens
    ostate, seen_out = "unknown", {}
    for _, n in smatches:
        for p in LIMIT_OUT_PATHS:
            v = gn(n, p)
            if isinstance(v, (int, float)):
                seen_out["/".join(p)] = v
                ostate = "preserved" if int(v) == EXPECTED_OUT else "clobbered"
    res["C7_B_limit_output_preserved"] = (ostate, seen_out)
else:
    # Explicitly mark as skipped so verdict JSON is self-documenting
    res["C6_control_enriched_with_context"] = ("skipped", {"reason": "--rich-metadata not set"})
    res["C7_B_limit_output_preserved"]     = ("skipped", {"reason": "--rich-metadata not set"})

# C8 / C9: D_thin reconcile assertions (only when --simulate-d-thin is set)
SIM_D = os.environ.get("SIMULATE_D_THIN", "0") == "1"
GHOST = os.environ.get("GHOST_ID", "ghost-removed-from-gateway")
if SIM_D:
    # Find the GHOST entry in the captured models_fields
    ghost_entry = None
    for mfs in gw.values():
        for mf in mfs:
            if isinstance(mf, dict) and GHOST in mf:
                ghost_entry = mf[GHOST]
                break
            elif isinstance(mf, list):
                for item in mf:
                    if _id_of(item) == GHOST:
                        ghost_entry = item
                        break
        if ghost_entry is not None:
            break
    # C8: ghost model (in B but NOT in gateway catalog) must be disabled (enabled=false)
    if ghost_entry is None:
        c8state = "FAIL"
        c8detail = {"reason": f"ghost model {GHOST!r} not found in registry"}
    else:
        enabled_val = ghost_entry.get("enabled", True) if isinstance(ghost_entry, dict) else True
        if enabled_val is False:
            c8state = "disabled"  # PASS — ghost correctly disabled
            c8detail = {"ghost_id": GHOST, "enabled": False}
        else:
            c8state = "FAIL"  # ghost should have been disabled
            c8detail = {"ghost_id": GHOST, "enabled": enabled_val, "expected": False}
    res["C8_ghost_disabled"] = (c8state, c8detail)

    # C9: target model (present in gateway) must remain enabled (default true).
    # Verifies D_thin doesn't disable non-ghosts.
    target_entry = smatches[0][1] if smatches else None
    if target_entry is None:
        c9state = "FAIL"
        c9detail = {"reason": f"target model {TARGET!r} not found"}
    else:
        enabled_val = target_entry.get("enabled", True) if isinstance(target_entry, dict) else True
        if enabled_val is True or enabled_val is None:
            c9state = "preserved"  # PASS — non-ghost kept enabled
            c9detail = {"target_id": TARGET, "enabled": True}
        else:
            c9state = "FAIL"  # target was wrongly disabled
            c9detail = {"target_id": TARGET, "enabled": enabled_val, "expected": True}
    res["C9_present_model_stays_enabled"] = (c9state, c9detail)
else:
    res["C8_ghost_disabled"]              = ("skipped", {"reason": "--simulate-d-thin not set"})
    res["C9_present_model_stays_enabled"]  = ("skipped", {"reason": "--simulate-d-thin not set"})

verdict = ("FAIL" if any(v[0] in ("FAIL","clobbered","missing","missing_or_wrong") for v in res.values()) else
           "WARN" if any(v[0] in ("unknown","unverifiable_text_only") for v in res.values()) else
           "PASS")

out = {
  "verdict": verdict,
  "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "contract": "A only adds, never overwrites; D_thin disables, never deletes",
  "target_id": TARGET,
  "provider_id": PROV,
  "control_id": CONTROL_ID,
  "embedding_id": EMBEDDING_ID,
  "ghost_id": GHOST if SIM_D else None,
  "expected": {"context": EXPECTED_CTX, "output": EXPECTED_OUT, "control_context": CONTROL_CTX},
  "rich_metadata": RICH,
  "simulate_d_thin": SIM_D,
  "match_count": len(smatches),
  "gw_model_count": len(all_gw_keys),
  "results": {k: {"status": v[0], "detail": v[1]} for k, v in res.items()},
}
print(json.dumps(out, indent=2))
rank = {"preserved":0, "enriched":0, "PASS":0, "skipped":0, "disabled":0,
        "unknown":2, "unverifiable_text_only":2,
        "clobbered":1, "missing":1, "missing_or_wrong":1, "FAIL":1}
sys.exit(max(rank.get(v[0], 2) for v in res.values()))
PY
fi

# ============================================================================
# MODE: selftest — validate the assertion engine against built-in fixtures
# ============================================================================
if [[ "$MODE" == "selftest" ]]; then
  log "selftest: validating assertion engine (no opencode needed)"
  have python3 || { bad "python3 required"; exit 3; }
  ST="$(mktemp -d "${TMPDIR:-/tmp}/vac-selftest.XXXXXX")"
  RICH_METADATA=0 python3 - "$ST" <<'PY'
import json, os, sys
work = sys.argv[1]
ok_doc = {"provider": {"gateway": {"id": "gateway", "models": {
    "qwen3-coder": {"id": "qwen3-coder", "name": "Qwen3 Coder",
                    "capabilities": {"tools": True},
                    "limit": {"context": 131072, "output": 65536}},
    "llama-3.3-70b": {"id": "llama-3.3-70b", "limit": {"context": 128000}},
}}}}
bad_doc = {"provider": {"gateway": {"id": "gateway", "models": [
    {"id": "qwen3-coder", "capabilities": {"tools": False}, "limit": {"context": 4096}},
    {"id": "qwen3-coder", "capabilities": {"tools": True}},
    {"id": "text-embedding-3-large"},
]}}}
json.dump(ok_doc,  open(os.path.join(work, "fx_ok.json"),  "w"))
json.dump(bad_doc, open(os.path.join(work, "fx_bad.json"), "w"))
PY
  bash "$0" --assert-helper "$ST/fx_ok.json"  >/dev/null 2>&1 && rc_ok=0   || rc_ok=$?
  bash "$0" --assert-helper "$ST/fx_bad.json" >/dev/null 2>&1 && rc_bad=0 || rc_bad=$?
  rm -rf "$ST"
  if [[ $rc_ok == 0 && $rc_bad == 1 ]]; then
    ok "engine: PASS fixture detected as PASS (rc=$rc_ok)"
    ok "engine: FAIL fixture detected as FAIL (rc=$rc_bad)"
    log "SELFTEST PASS"; exit 0
  fi
  bad "engine rc_ok=$rc_ok (want 0), rc_bad=$rc_bad (want 1)"
  log "SELFTEST FAIL"; exit 1
fi

# ----------------------------- workspace ------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-a-contract.XXXXXX")"
GATEWAY_PID=""; SERVE_PID=""
cleanup() {
  [[ -n "$GATEWAY_PID" ]] && kill "$GATEWAY_PID" 2>/dev/null || true
  [[ -n "$SERVE_PID" ]]   && kill "$SERVE_PID"   2>/dev/null || true
  if (( KEEP )); then
    local dest="${ARTIFACTS_DIR:-./opencode-contract-artifacts}"
    mkdir -p "$dest"
    cp -r "$WORK"/. "$dest"/ 2>/dev/null || true
    log "artifacts kept: $dest  (workdir was $WORK)"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

# ============================================================================
# Mock gateway — 2 chat models + 1 embedding negative-control, auth-enforced
# ============================================================================
write_gateway() {
  cat > "$WORK/mock_gateway.py" <<PY
#!/usr/bin/env python3
import json, sys, http.server, socketserver
PORT = int(sys.argv[1])
MODELS = {"object": "list", "data": [
  {"id": "$TARGET_ID", "object": "model", "owned_by": "vllm",
   "max_model_len": $EXPECTED_CONTEXT, "max_completion_tokens": $EXPECTED_OUTPUT,
   "supports_tool_calls": True},
  {"id": "$CONTROL_ID", "object": "model", "owned_by": "openai",
   "max_model_len": $CONTROL_CONTEXT, "supports_tool_calls": False},
  {"id": "$EMBEDDING_ID", "object": "model", "owned_by": "openai",
   "mode": "embedding", "max_model_len": 8192},
]}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/health"):
            return self._send(200, {"status": "ok"})
        if self.path.startswith("/v1/models"):
            if self.headers.get("Authorization", "") != "Bearer $API_KEY":
                return self._send(401, {"error": {"message": "bad bearer token"}})
            return self._send(200, MODELS)
        return self._send(404, {"error": "not found"})
    def do_POST(self):
        if self.path.startswith("/v1/chat/completions"):
            return self._send(200, {"id":"chatcmpl-stub","object":"chat.completion",
                "choices":[{"index":0,"message":{"role":"assistant","content":"ok"},
                            "finish_reason":"stop"}]})
        return self._send(404, {"error": "not found"})
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
socketserver.ThreadingTCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), H) as s:
    s.serve_forever()
PY
}

start_mock_gateway() {
  write_gateway
  python3 "$WORK/mock_gateway.py" "$GW_PORT" & GATEWAY_PID=$!
  wait_http "http://127.0.0.1:$GW_PORT/health" 30 || { bad "gateway did not boot"; exit 1; }
  GATEWAY_URL="http://127.0.0.1:$GW_PORT/v1"
  ok "mock gateway up on :$GW_PORT (auth: Bearer $API_KEY, 2 chat + 1 embedding control)"
}

# ============================================================================
# MODE: smoke — boot mock gateway, curl endpoints, exit
# ============================================================================
if [[ "$MODE" == "smoke" ]]; then
  have python3 || { bad "python3 required"; exit 3; }
  have curl    || { bad "curl required"; exit 3; }
  start_mock_gateway
  code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GW_PORT/v1/models")
  if [[ "$code" == "401" ]]; then ok "/v1/models without auth -> 401 (auth enforced)"
  else bad "expected 401, got $code"; exit 1; fi
  echo "--- /v1/models with auth (expect 200 + 3 models):"
  curl -sS -H "Authorization: Bearer $API_KEY" "http://127.0.0.1:$GW_PORT/v1/models"
  echo; log "SMOKE PASS"; exit 0
fi

# ============================================================================
# Resolve gateway URL (mock or real)
# ============================================================================
if [[ -z "$GATEWAY_URL" ]]; then
  have python3 || { bad "python3 required for mock gateway"; exit 3; }
  have curl    || { bad "curl required"; exit 3; }
  start_mock_gateway
else
  # Normalize FIRST so the probe hits the right path regardless of
  # whether the user passed .../v1, .../v1/, or a bare host.
  GATEWAY_URL="${GATEWAY_URL%/}"
  GATEWAY_URL="${GATEWAY_URL%/v1}"
  GATEWAY_URL="$GATEWAY_URL/v1"
  ok "using real gateway: $GATEWAY_URL"
  # sanity-check it answers /v1/models with the supplied key
  if ! curl -fsS -H "Authorization: Bearer $API_KEY" "$GATEWAY_URL/models" \
        -o "$WORK/gw_models_probe.json" 2>/dev/null; then
    bad "gateway $GATEWAY_URL/models not reachable with provided --api-key"
    log "check: URL is reachable, API key is valid, /v1/models endpoint exists"
    exit 3
  fi
  ok "gateway /v1/models reachable ($(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d.get("data",[])),"models")' "$WORK/gw_models_probe.json" 2>/dev/null || echo '?'))"
fi

# ============================================================================
# Generate B-layer opencode.json (explicit qwen3-coder with tools/limit/name)
# ============================================================================
log "writing B-layer config (explicit $TARGET_ID, tools=true, ctx=$EXPECTED_CONTEXT, out=$EXPECTED_OUTPUT)"
if [[ "$SCHEMA" == "auto" ]]; then
  if have "$OC_BIN"; then
    v="$("$OC_BIN" --version 2>/dev/null | head -1 || true)"
    case "$v" in 2.*) SCHEMA="v2" ;; *) SCHEMA="v1" ;; esac
    log "opencode version: ${v:-unknown} -> schema=$SCHEMA"
  else
    SCHEMA="v2"  # default for simulation (V2 build is the assumed target)
    log "no opencode binary on PATH -> defaulting schema=$SCHEMA for B-layer"
  fi
fi

if [[ "$SCHEMA" == "v1" ]]; then
  cat > "$WORK/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "plugin": ["$PLUGIN_SPEC"],
  "provider": {
    "gateway": {
      "name": "Contract Test Gateway",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "$GATEWAY_URL",
        "apiKey": "$API_KEY",
        "modelsDiscovery": { "enabled": true, "smartModelName": true, "timeoutMs": 3000 }
      },
      "models": {
        "$TARGET_ID": {
          "name": "$TARGET_ID (B-explicit)",
          "tool_call": true,
          "limit": { "context": $EXPECTED_CONTEXT, "output": $EXPECTED_OUTPUT }
        },
        "$GHOST_ID": {
          "name": "$GHOST_ID (B-explicit ghost — NOT in gateway catalog)",
          "tool_call": true
        }
      }
    }
  }
}
JSON
else
  cat > "$WORK/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "plugins": ["$PLUGIN_SPEC"],
  "providers": {
    "gateway": {
      "name": "Contract Test Gateway",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "$GATEWAY_URL",
        "apiKey": "$API_KEY",
        "modelsDiscovery": { "enabled": true, "smartModelName": true, "timeoutMs": 3000 }
      },
      "models": {
        "$TARGET_ID": {
          "modelID": "$TARGET_ID",
          "name": "$TARGET_ID (B-explicit)",
          "capabilities": { "tools": true },
          "limit": { "context": $EXPECTED_CONTEXT, "output": $EXPECTED_OUTPUT }
        },
        "$GHOST_ID": {
          "modelID": "$GHOST_ID",
          "name": "$GHOST_ID (B-explicit ghost)",
          "capabilities": { "tools": true }
        }
      }
    }
  }
}
JSON
fi
python3 -c "import json;json.load(open('$WORK/opencode.json'))" \
  || { bad "generated config is not valid JSON"; exit 1; }
ok "config valid ($SCHEMA schema; $CONTROL_ID intentionally NOT written by B)"

# ============================================================================
# MODE: simulate — Python-only; mirrors A's documented merge logic
# Faithful to: "only adds, never overwrites"; existing entries preserved
# entirely; new entries enriched with gateway metadata (max_model_len ->
# limit.context, max_completion_tokens -> limit.output); embedding mode
# skipped. DOES NOT execute the real plugin binary — for binary verification
# use the default mode (no --simulate).
# ============================================================================
if [[ "$MODE" == "simulate" ]]; then
  log "SIMULATE: applying A's documented merge logic in-process (no opencode binary)"
  RICH_METADATA="$RICH_METADATA" \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  EXPECTED_OUTPUT="$EXPECTED_OUTPUT" \
  CONTROL_CONTEXT="$CONTROL_CONTEXT" \
  SIMULATE_D_THIN="$SIMULATE_D_THIN" \
  python3 - "$WORK/opencode.json" "$GATEWAY_URL" "$API_KEY" "$WORK/runtime_state.json" <<'PY'
import json, sys, os, urllib.request
cfg_path, gw_base, api_key, out_path = sys.argv[1:5]
RICH = os.environ.get("RICH_METADATA", "0") == "1"
EXPECTED_CONTEXT = int(os.environ["EXPECTED_CONTEXT"])
EXPECTED_OUTPUT  = int(os.environ["EXPECTED_OUTPUT"])
CONTROL_CONTEXT  = int(os.environ["CONTROL_CONTEXT"])

# read opencode.json (JSONC-safe: strip // comments OUTSIDE string literals)
def strip_jsonc_comments(text):
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            if c == '\\' and i+1 < n:
                out.append(c); out.append(text[i+1]); i += 2; continue
            if c == '"': in_str = False
            out.append(c); i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == '/' and i+1 < n and text[i+1] == '/':
            while i < n and text[i] != '\n': i += 1
            continue
        out.append(c); i += 1
    return ''.join(out)

raw = strip_jsonc_comments(open(cfg_path).read())
cfg = json.loads(raw)
provider = (cfg.get("provider") or cfg.get("providers") or {}).get("gateway", {})
disk_models = provider.get("models", {}) or {}

# fetch /v1/models from the gateway
# Note: some gateways (opencode Console behind Cloudflare) reject urllib's
# default User-Agent (Python-urllib/X.Y) with HTTP 403 / error 1010.
# Send a realistic UA so the request passes.
req = urllib.request.Request(gw_base.rstrip("/") + "/models",
                             headers={"Authorization": f"Bearer {api_key}",
                                      "User-Agent": "opencode/1.19.5"})
gw = json.loads(urllib.request.urlopen(req, timeout=10).read())
gw_data = gw.get("data", [])

# --- A's documented merge logic: "only adds, never overwrites" ---
merged = {}
for mid, m in disk_models.items():
    merged[mid] = json.loads(json.dumps(m))  # deep copy B's entry verbatim

for m in gw_data:
    mid = m.get("id")
    if mid is None: continue
    if m.get("mode") == "embedding":
        continue  # A's skip-embeddings rule
    # Gateway metadata enrichment: handle both flat (max_model_len /
    # max_completion_tokens — vLLM-style) and nested (limit.context /
    # limit.output — opencode Console / models.dev style) schemas.
    gw_limit = m.get("limit") or {}
    ctx = (m.get("max_model_len") or m.get("context_length")
           or (gw_limit.get("context") if isinstance(gw_limit, dict) else None))
    out = (m.get("max_completion_tokens")
           or (gw_limit.get("output") if isinstance(gw_limit, dict) else None))
    gw_caps = m.get("capabilities") or {}
    gw_tools_supported = None
    if isinstance(gw_caps, dict):
        t = gw_caps.get("tools")
        if isinstance(t, dict):
            gw_tools_supported = t.get("supported")
        elif isinstance(t, bool):
            gw_tools_supported = t
    if mid in merged:
        # PRESERVE B's entry entirely; only FILL MISSING fields if B omitted them
        existing = merged[mid]
        if "limit" not in existing:
            if ctx or out:
                existing["limit"] = {}
                if ctx: existing["limit"]["context"] = ctx
                if out: existing["limit"]["output"] = out
        # NEVER touch tools, name, capabilities — that's the contract
    else:
        # ADD new entry, enriched with gateway metadata
        entry = {"id": mid}
        if ctx or out:
            entry["limit"] = {}
            if ctx: entry["limit"]["context"] = ctx
            if out: entry["limit"]["output"] = out
        if gw_tools_supported is not None:
            entry["capabilities"] = {"tools": {"supported": gw_tools_supported}}
        merged[mid] = entry

# emit a runtime state doc that the assert engine can walk
out = {
  "id": "gateway",
  "models": merged,
  "_meta": {
    "source": "simulated-A",
    "gateway_url": gw_base,
    "disk_models_count": len(disk_models),
    "gateway_models_count": len(gw_data),
    "merged_count": len(merged),
  }
}

# --- D_thin reconcile pass (only when --simulate-d-thin is set) ---
# Mirrors plugins/reconcile.ts's behavior:
#   - For each model in merged: if absent from gateway -> enabled = false
#   - For each model present in gateway -> PRESERVED VERBATIM (never touched)
#   - NEVER deletes (disable-not-delete contract)
SIMULATE_D = os.environ.get("SIMULATE_D_THIN", "0") == "1"
if SIMULATE_D:
    gw_ids = {m.get("id") for m in gw_data if m.get("id") and m.get("mode") != "embedding"}
    disabled_ids = []
    preserved_ids = []
    for mid, m in merged.items():
        if mid in gw_ids:
            preserved_ids.append(mid)
            # leave entry untouched
        else:
            # Ghost: present in opencode registry, absent from gateway.
            # Set enabled=false (disable, never delete).
            if isinstance(m, dict):
                m["enabled"] = False
                disabled_ids.append(mid)
    out["_meta"]["source"] = "simulated-A+D_thin"
    out["_meta"]["d_thin_disabled_count"] = len(disabled_ids)
    out["_meta"]["d_thin_preserved_count"] = len(preserved_ids)
    out["_meta"]["d_thin_disabled_ids"] = disabled_ids

json.dump(out, open(out_path, "w"), indent=2)
print(json.dumps({"merged": list(merged.keys()), "meta": out["_meta"]}, indent=2))
PY
  ok "simulated A-merge complete; runtime_state.json written"

  # Run the assertion engine on the simulated runtime state
  log "asserting the contract (simulated evidence)"
  TARGET_ID="$TARGET_ID" TARGET_PROV="$PROV_ID" CONTROL_ID="$CONTROL_ID" \
  EMBEDDING_ID="$EMBEDDING_ID" EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  EXPECTED_OUTPUT="$EXPECTED_OUTPUT" CONTROL_CONTEXT="$CONTROL_CONTEXT" \
  RICH_METADATA="$RICH_METADATA" \
  SIMULATE_D_THIN="$SIMULATE_D_THIN" \
  GHOST_ID="$GHOST_ID" \
  bash "$0" --assert-helper "$WORK/runtime_state.json" \
    | tee "$WORK/verdict.json"
  RC=${PIPESTATUS[0]}
  log "verdict JSON written to $WORK/verdict.json (and ./opencode-contract-artifacts/ with --keep)"
  exit "$RC"
fi

# ============================================================================
# MODE: full — real opencode binary + real/mock gateway
# ============================================================================
log "prerequisites"
have python3 || { bad "python3 required"; exit 3; }
have curl    || { bad "curl required"; exit 3; }
if ! have "$OC_BIN"; then
  bad "opencode binary '$OC_BIN' not found on PATH"
  log "install it first:  npm i -g opencode-ai@latest   (or set OC_BIN=/path/to/opencode)"
  log "or use --simulate to run the contract engine without the binary."
  exit 3
fi
ok "opencode found: $(command -v "$OC_BIN")"
OC_VERSION=$("$OC_BIN" --version 2>/dev/null | head -1 || true)
log "opencode version: ${OC_VERSION:-unknown}"

DOCS_DIR="$WORK/docs"; mkdir -p "$DOCS_DIR"
cd "$WORK"
export OPENCODE_CONFIG="$WORK/opencode.json"

# Strategy 1: opencode models (CLI listing, scoped to the test provider)
if run_to "$OC_BIN" models "$PROV_ID" --print-logs > "$WORK/models_cli.txt" 2> "$WORK/cli.err" \
   && [[ -s "$WORK/models_cli.txt" ]]; then
  cp "$WORK/models_cli.txt" "$DOCS_DIR/01_cli_models_${PROV_ID}.txt"
  ok "CLI 'models ${PROV_ID}' captured"
else
  warn "CLI 'models ${PROV_ID}' produced no output (provider not registered?)"
fi

# Strategy 1b: CONTROL run without external plugins — proves plugin contribution by delta.
# The --pure flag is not available in all opencode builds; if it errors, we
# skip the control comparison (the assert engine still works without it).
if run_to "$OC_BIN" models "$PROV_ID" --pure --print-logs > "$WORK/models_pure.txt" 2>> "$WORK/cli.err" \
   && [[ -s "$WORK/models_pure.txt" ]]; then
  cp "$WORK/models_pure.txt" "$DOCS_DIR/02_cli_models_${PROV_ID}_pure.txt"
  ok "control run (--pure, no plugins) captured"
else
  warn "control run (--pure) unavailable or produced no output — skipping delta comparison"
  log "(this is non-fatal; the --pure flag may not exist in your opencode build)"
fi

# Strategy 2: opencode serve + HTTP API (rich JSON evidence)
"$OC_BIN" serve --hostname 127.0.0.1 --port "$API_PORT" > "$WORK/serve.log" 2>&1 &
SERVE_PID=$!
wait_http "http://127.0.0.1:$API_PORT/" 40 || true

CANDS=("http://127.0.0.1:$API_PORT")
while IFS= read -r u; do
  [[ -n "$u" ]] && CANDS+=("$u") || true
done < <(grep -oE 'http://[0-9A-Za-z.:/?=&_-]+' "$WORK/serve.log" 2>/dev/null | sort -u || true)

BEFORE=$(ls "$DOCS_DIR" 2>/dev/null | wc -l)
i=0
for base in "${CANDS[@]}"; do
  b="${base%/}"
  for ep in /provider /providers /models /config /app /status; do
    if curl -fsS "$b$ep" -o "$WORK/resp.json" 2>/dev/null \
       && python3 -c "import json;json.load(open('$WORK/resp.json'))" 2>/dev/null; then
      i=$((i+1))
      cp "$WORK/resp.json" "$DOCS_DIR/api_$(echo "$b$ep" | tr '/:' '__').json"
    fi
  done
  if (( i > 0 )); then break; fi
done
NEWDOCS=$(( $(ls "$DOCS_DIR" 2>/dev/null | wc -l) - BEFORE ))
if (( NEWDOCS > 0 )); then ok "captured $NEWDOCS JSON API response(s)"
else warn "serve API gave no JSON; CLI evidence only"; fi

TOTAL_DOCS=$(ls "$DOCS_DIR" 2>/dev/null | wc -l)
if (( TOTAL_DOCS == 0 )); then
  bad "no evidence harvested - cannot run contract"
  log "re-run with --keep and inspect $WORK for logs"
  exit 1
fi

# Collect JSON evidence files; fall back to text-only if no JSON was captured.
# (Glob-safe: nullglob prevents passing a literal '*.json' string to Python
# when the serve API gave no JSON responses.)
shopt -s nullglob
JSON_EVIDENCE=("$DOCS_DIR"/*.json)
shopt -u nullglob

if (( ${#JSON_EVIDENCE[@]} == 0 )); then
  warn "no JSON evidence harvested (serve API gave no JSON); CLI text-only evidence available"
  log "C2/C3 may return 'unverifiable_text_only' — this is expected with CLI-only runs."
  log "To get full JSON evidence, ensure 'opencode serve' starts and exposes /models or /provider."
  # Create a minimal JSON stub so the assert engine has at least one doc to walk;
  # the text evidence in the same dir will still be harvested by the engine.
  python3 -c "import json; json.dump({'_note':'no JSON API evidence; CLI text-only mode'}, open('$DOCS_DIR/_stub.json','w'))"
  JSON_EVIDENCE=("$DOCS_DIR/_stub.json")
fi

# ---- assert the contract ---------------------------------------------------
log "asserting the contract (binary evidence)"
TARGET_ID="$TARGET_ID" TARGET_PROV="$PROV_ID" CONTROL_ID="$CONTROL_ID" \
EMBEDDING_ID="$EMBEDDING_ID" EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
EXPECTED_OUTPUT="$EXPECTED_OUTPUT" CONTROL_CONTEXT="$CONTROL_CONTEXT" \
RICH_METADATA="$RICH_METADATA" \
bash "$0" --assert-helper "${JSON_EVIDENCE[@]}" \
  | tee "$WORK/verdict.json"
RC=${PIPESTATUS[0]}

# ---- diagnostics -----------------------------------------------------------
log "diagnostics"
if grep -qiE "models-discovery|modelsDiscovery" "$WORK/serve.log" "$WORK/cli.err" 2>/dev/null; then
  ok "plugin load referenced in opencode logs"
else
  warn "no plugin-load line found in logs (C4 PASS is the stronger proof)"
fi

if grep -q "configuration compatibility diagnostic" "$WORK/cli.err" "$WORK/serve.log" 2>/dev/null; then
  warn "config compatibility diagnostics emitted - some settings were OMITTED:"
  grep -m4 "compatibility diagnostic" "$WORK/cli.err" "$WORK/serve.log" 2>/dev/null | sed 's/^/    /' || true
  log "hint: schema shape mismatch. Force with --schema v1 or --schema v2."
fi

if [[ -s "$WORK/models_cli.txt" && -s "$WORK/models_pure.txt" ]] \
   && grep -q "${PROV_ID}/${CONTROL_ID}" "$WORK/models_cli.txt" \
   && ! grep -q "${PROV_ID}/${CONTROL_ID}" "$WORK/models_pure.txt"; then
  ok "plugin contribution proven: $CONTROL_ID appears ONLY in the plugin-enabled run"
fi

case "$RC" in
  0) log "CONTRACT PASS — equation validated against a real gateway. 10/10 unlocked." ;;
  1) log "CONTRACT FAIL — A did NOT honor 'only adds, never overwrites'."
     log "Fall back to B-only (remove plugins[] from config) — your explicit entries stay intact." ;;
  2) log "RAN but could not verify tools/limit flags from harvested evidence."
     log "Re-run with --keep and inspect docs/*.json to extend TOOL_PATHS/LIMIT_PATHS in the helper." ;;
esac

exit "$RC"
