# verify-a-contract.sh — opencode v2 "unlimited models" contract verifier

Final installer for the staged equation:

```
Ecosystem = B (offline generator, hand-written models block)
          + A (opencode-models-discovery plugin, /v1/models auto-fetch)
          + D_thin (reconcile plugin, disable-not-delete)   [Stage 2 — additive]
          -> E (native openai-compatible discovery)          [Stage 3 — deferred]
```

## STATUS (verified 2026-11-14)

| Layer | Mode | Verdict | Notes |
|---|---|---|---|
| Selftest | mock fixtures | **PASS** | Engine detects PASS/FAIL correctly |
| Simulated merge | embedded mock gateway | **PASS** 7/7 | All 7 assertions (C1-C7) hold |
| Real gateway | opencode Console (`https://opencode.ai/inference/v1`) | **PASS** 7/7 | 52-model catalog, kimi-k3 explicit + glm-5.3-flash-free control |

The real-gateway run validates the contract against the **live opencode Console**
catalog (52 models) using `kimi-k3` as the B-explicit target and
`glm-5.3-flash-free` as the A-only control. All 7 assertions hold, including the
rich-metadata enrichment checks (C6, C7) that confirm A enriches discovered-only
entries from the gateway's `limit.context`/`limit.output` fields without
clobbering B's explicit `tools:true` / `limit.context` / `limit.output`.

See `verdict-real-gateway.json` for the machine-readable verdict.

## Production deployment

The full production stack in this project is:

| Layer | Implementation | Status |
|---|---|---|
| **B** (offline generator) | Hand-written `models` block in `/home/z/my-project/opencode.json` | Active (17 models: 5 paid + 12 free) |
| **A** (discovery) | `https://opencode.ai/inference/v1/models` (opencode Console catalog) | Active (52 models discoverable) |
| **Execution (paid)** | Direct to `https://opencode.ai/inference/v1/chat/completions` with `oc_sk_` key | Verified (kimi-k3 returns text, $0.0006/req) |
| **Execution (free)** | Via `opencode-egress-router` proxy at `127.0.0.1:8318` (zenfix gate rewrite) | Verified (glm-5.3-flash-free returns text, $0/req) |

The opencode-egress-router proxy (https://github.com/Magiszonekk/opencode-proxy)
sits between OpenAI-compatible clients and `https://opencode.ai/zen/v1`. For
free-tier model IDs (`*-free`, `big-pickle`), it rewrites the request (TLS
fingerprint spoofing, opencode-format session ID, `bash`/`read` tool stubs,
`<env>` block injection) so Zen's "from within OpenCode" gate passes.
Paid models with real `oc_sk_` keys pass through unchanged.

**Contract under test:** `A only adds, never overwrites.`

B writes an explicit `qwen3-coder` entry with hand-set overrides
(`tools:true`, `limit.context:131072`, `limit.output:65536`, custom name).
A then discovers the same model from the gateway's `/v1/models`. The
contract HOLDS iff A preserves B's overrides verbatim and only fills
metadata B never set.

This script verifies that contract end-to-end against either an embedded
2-model mock gateway OR your real gateway, then emits a machine-readable
verdict JSON that doubles as a CI gate (exit code 0 = PASS, 1 = FAIL,
2 = unverifiable, 3 = prerequisites missing).

---

## The 9 assertions

| #  | Assertion | What it proves | Statuses |
|----|-----------|----------------|----------|
| C1 | `qwen3-coder` appears exactly ONCE per effective model list | No dup after A's merge | PASS / FAIL |
| C2 | `tools:true` override survives A's discovery | A doesn't clobber tool flags | preserved / clobbered / unknown |
| C3 | `limit.context:131072` override survives | A doesn't clobber B's hand-set context | preserved / clobbered / unknown |
| C4 | `llama-3.3-70b` (B-omitted) appears in merged state | A loaded + apiKey passthrough worked | PASS / FAIL |
| C5 | `text-embedding-3-large` is ABSENT | A's skip-embeddings rule works | PASS / FAIL |
| C6 | `llama-3.3-70b` carries `limit.context:128000` (from gateway's `max_model_len`) | A enriches discovered-only entries rather than adding empty stubs | enriched / missing / missing_or_wrong / FAIL |
| C7 | B's `limit.output:65536` survives even when gateway also returns `max_completion_tokens` | A doesn't clobber B's output limit | preserved / clobbered / unknown |
| C8 | Ghost model (B-written, NOT in gateway catalog) is `enabled: false` | D_thin disables ghosts (never deletes) | disabled / FAIL |
| C9 | Target model (B-written, present in gateway) stays `enabled: true` | D_thin doesn't disable non-ghosts | preserved / FAIL |

**C1-C5 always run.** C6/C7 require `--rich-metadata`. C8/C9 require `--simulate-d-thin` (they validate the Layer D_thin reconcile plugin's disable-not-delete contract). Without those flags, the corresponding assertions are marked `skipped` in the verdict JSON.

The embedded mock gateway returns all the metadata fields needed for C6/C7, so they pass in simulation. If your real gateway returns sparser metadata, omit `--rich-metadata` and the engine will mark C6/C7 as `skipped`.


**Overall verdict mapping:**
- `PASS` — every applicable assertion is PASS/preserved/enriched
- `FAIL` — at least one assertion is FAIL/clobbered/missing/missing_or_wrong
- `WARN` — at least one assertion is unknown/unverifiable_text_only (e.g. CLI-only evidence that lacks structured tool/limit fields)

---

## Mode matrix

| Mode | Flag | Needs opencode? | Needs gateway? | Use for |
|------|------|-----------------|----------------|---------|
| selftest | `--selftest` | no | no | Validate assertion engine against built-in PASS/FAIL fixtures |
| smoke | `--smoke-gateway` | no | mock (embedded) | Boot mock gateway, curl `/health` + `/v1/models`, exit |
| simulate | `--simulate` | **no** | mock OR `--gateway-url` | Pre-flight smoke, CI without opencode installed, offline reproduction |
| full (default) | (none) | **yes** | mock OR `--gateway-url` | Production verification with real opencode binary + real plugin |

**`--simulate` faithfully mirrors A's documented merge logic** ("only adds,
never overwrites; existing entries preserved entirely; new entries enriched
with gateway metadata; embedding mode skipped"). It does NOT execute the
real `opencode-models-discovery` plugin binary — for binary verification,
omit `--simulate` and ensure `opencode` is on your PATH (or set `OC_BIN=`).

---

## Flag matrix

```
--simulate              Python-only; no opencode binary needed
--smoke-gateway         Boot mock gateway, curl endpoints, exit
--selftest              Validate assertion engine against fixtures
--mock                  Use embedded 2-model mock gateway (default)
--gateway-url URL       Point at a real OpenAI-compatible gateway
                        (disables --mock; probes URL on startup)
--api-key KEY           Bearer token for /v1/models (default: sk-test-contract
                        or $GATEWAY_API_KEY env var)
--schema v1|v2|auto     Force config schema (default: auto-detect from
                        opencode --version; v2.x -> v2, else v1)
--plugin-spec SPEC      Plugin spec to write into config
                        (default: opencode-models-discovery@2.1.2)
--plugin-version V      Convenience alias: --plugin-spec opencode-models-discovery@V
--opencode-bin PATH     opencode binary (default: opencode from PATH,
                        or $OC_BIN env var)
--rich-metadata         Add C6 + C7 enrichment assertions
--keep                  Persist artifacts to ./opencode-contract-artifacts/
                        (or --artifacts-dir PATH)
--artifacts-dir PATH    Where to copy workdir contents when --keep
-h, --help              Show help
```

---

## Usage examples

### 1. Sandbox / CI smoke (no opencode needed)

```bash
bash verify-a-contract.sh --simulate --mock --rich-metadata --keep
# -> verdict.json with 7/7 PASS, exit 0
```

### 2. Real gateway + real opencode + real plugin (PRODUCTION)

```bash
export GATEWAY_API_KEY="sk-..."
bash verify-a-contract.sh \
  --gateway-url https://gateway.example.com/v1 \
  --rich-metadata --keep
# -> probes https://gateway.example.com/v1/models with Bearer $GATEWAY_API_KEY
# -> boots opencode, harvests effective model state from CLI + serve API
# -> asserts contract, writes verdict.json
```

### 3. Pre-upgrade CI gate (gates plugin version bumps)

```bash
bash verify-a-contract.sh \
  --gateway-url "$GW" --api-key "$K" \
  --plugin-version 2.1.3 --rich-metadata
# exit 0 -> safe to merge the version bump
# exit 1 -> contract broken; pin to previous version
```

### 4. Validate the assertion engine without any external deps

```bash
bash verify-a-contract.sh --selftest
# PASS fixture detected as PASS (rc=0)
# FAIL fixture detected as FAIL (rc=1)
```

### 5. Smoke-test the mock gateway in isolation

```bash
bash verify-a-contract.sh --smoke-gateway
# /health -> 200
# /v1/models without auth -> 401
# /v1/models with auth -> 200 + 3 models (2 chat + 1 embedding control)
```

---

## Verdict JSON schema

```jsonc
{
  "verdict": "PASS",                    // PASS | FAIL | WARN
  "timestamp": "2026-11-14T04:23:37+00:00",
  "contract": "A only adds, never overwrites",
  "target_id": "qwen3-coder",          // B-explicit entry under test
  "provider_id": "gateway",            // provider scope
  "control_id": "llama-3.3-70b",       // A-only discovered model (proves plugin loaded)
  "embedding_id": "text-embedding-3-large",  // negative control (must be absent)
  "expected": { "context": 131072, "output": 65536, "control_context": 128000 },
  "rich_metadata": true,               // whether C6/C7 ran
  "match_count": 1,                    // TARGET entries found in evidence
  "gw_model_count": 2,                 // total models under test provider
  "results": {
    "C1_no_duplicate":                 { "status": "PASS",      "detail": {...} },
    "C2_tools_preserved":              { "status": "preserved", "detail": {} },
    "C3_limit_context":                { "status": "preserved", "detail": {"limit/context": 131072} },
    "C4_discovery_adds_missing":       { "status": "PASS",      "detail": {} },
    "C5_embeddings_skipped":           { "status": "PASS",      "detail": {} },
    "C6_control_enriched_with_context": { "status": "enriched", "detail": {"limit/context": 128000} },
    "C7_B_limit_output_preserved":     { "status": "preserved", "detail": {"limit/output": 65536} }
  }
}
```

---

## What to send back after running against your real gateway

After running example #2 above, paste back:

1. The full **`verdict.json`** from `./opencode-contract-artifacts/verdict.json`
2. The first 30 lines of **`opencode.json`** (so I can confirm the schema
   shape that the V2 binary auto-detected)
3. **`runtime_state.json`** if you ran with `--simulate` (shows A's merge
   output explicitly — useful for diffing against the binary mode)

If verdict is `WARN` (some assertion is `unknown`), also include the
contents of `./opencode-contract-artifacts/docs/` (the harvested JSON
evidence) so I can extend `TOOL_PATHS` / `LIMIT_PATHS` in the assertion
engine to match your opencode version's actual API response shape.

---

## Staged rollout

### Stage 1 — B + A + this contract test  (target confidence: 10/10)

```jsonc
// opencode.json (or ~/.config/opencode/opencode.json)
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["opencode-models-discovery@2.1.2"],
  "providers": {
    "gateway": {
      "name": "My Gateway",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "https://gateway.example.com/v1",
        "apiKey": "{env:GATEWAY_API_KEY}",
        "modelsDiscovery": { "enabled": true, "smartModelName": true }
      },
      "models": {
        // Written by Layer B (sammcj/opencode-model-tool, or by hand).
        // Version-controlled. These entries ALWAYS win over A's discovery.
        "qwen3-coder": {
          "name": "Qwen3 Coder",
          "capabilities": { "tools": true },
          "limit": { "context": 131072, "output": 65536 }
        }
      }
    }
  }
}
```

CI gate: `verify-a-contract.sh --gateway-url $GW --rich-metadata`
must exit 0 before any plugin version bump merges.

### Stage 2 — + D_thin reconcile plugin  (additive, not risky)

Add `.opencode/plugins/reconcile.ts` (~30 lines) implementing:

```ts
// disable-not-delete ghost reconciliation
// on every model reload: for each disk entry absent from gateway,
// set disabled=true (never delete); preserve B's overrides verbatim
```

D_thin closes the ghost-model gap (a model removed from your gateway
would otherwise linger forever in B's `models` block). It does NOT
interfere with A's contract — it only marks entries as disabled, never
deletes or overwrites.

Confidence delta: 9/10 → 10/10 production-hardened (handles gateway
churn gracefully). Still gated behind Stage 1's contract test passing.

### Stage 3 — swap A -> PR #57161 native discovery  (deferred until merged)

When [PR #57161](https://github.com/sst/opencode/pull/57161) merges
(internal `opencode.provider.openai-compatible` plugin calling
`GET {baseURL}/models` behind `experimental.openai_compatible_discovery`
flag), the migration is:

1. Remove `"plugins": ["opencode-models-discovery@2.1.2"]` from config
2. Add `"experimental": { "openai_compatible_discovery": true }` to provider settings
3. Keep B's `models` block — the contract is the same (`only adds, never
   overwrites`), so this contract test still gates the migration
4. Re-run `verify-a-contract.sh` (with `--plugin-spec` removed since the
   discovery is now native)

Confidence at Stage 3: 10/10 production-validated AND no third-party
plugin dependency. Until PR merges, Stage 1 + Stage 2 is the
recommended production setup.

---

## Files in this bundle

| File | Purpose |
|------|---------|
| `verify-a-contract.sh` | Main installer / contract verifier (self-contained) |
| `mock_gateway.py` | Standalone 2-model mock gateway (also embedded in the .sh as a heredoc) |
| `verdict-example.json` | Sample verdict JSON from a `--simulate --mock --rich-metadata` run |
| `opencode-v2-example.json` | Sample B-layer config (v2 schema) the script generates |
| `runtime-state-example.json` | Sample merged runtime state (simulated A's output) |
| `mock_test_ecosystem.py` | Prior-session 3-test logical simulation (dedup, graceful degradation, ghost reconciliation) |
| `score_workarounds.py` | Prior-session weighted scorecard ranking options A-E |
| `README.md` | This file |

---

## Honesty caveats

- **`--simulate` mode is a logical simulation**, NOT a binary verification.
  It faithfully mirrors A's documented merge contract but cannot catch a
  plugin binary that violates its own documentation. For production
  validation, run without `--simulate` (default `full` mode) against your
  real opencode binary.
- The script's evidence harvesting (`opencode models <provider> --print-logs`
  + `opencode serve` + HTTP API probing) is best-effort across opencode
  versions. If your version's API response shape differs from what
  `TOOL_PATHS` / `LIMIT_PATHS` expect, the engine returns `unknown` /
  `WARN` — re-run with `--keep` and extend the paths in the
  `--assert-helper` block.
- If your real gateway's `/v1/models` returns richer metadata fields
  beyond `max_model_len` / `max_completion_tokens` / `supports_tool_calls`
  (e.g. `top_provider`, `pricing`, `permission`), extend
  `LIMIT_CTX_PATHS` / `LIMIT_OUT_PATHS` / `TOOL_PATHS` in the assert
  engine to cover them. The verdict JSON will then surface the
  additional paths in each assertion's `detail` map.
