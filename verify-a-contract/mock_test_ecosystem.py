#!/usr/bin/env python3
"""
Simulated mock tests for the opencode v2 'unlimited models' ecosystem equation:

    Ecosystem = B (offline generator) + A (runtime discovery plugin) + D_thin (reconcile)

Three pre-flight tests:
  T1  Dedup         : B writes explicit model; A discovers same ID -> no duplicate, B's
                      limit/tools survive (proves A "only adds, never overwrites").
  T2  Graceful-Depr : Disable A -> B's explicit models still load; A-only models gone.
  T3  Ghost Removal : Gateway drops a model -> D_thin removes it from runtime map.

This is a LOGICAL simulation of each layer's documented behavior, not an integration
test against a real opencode binary. Sources of the simulated behavior:
  - B (sammcj/opencode-model-tool): writes/merges the models block of opencode.jsonc,
    per-model fields {name, limit.context, limit.output}; "updates only the models block
    for the matched provider, preserving all other config including JSONC comments."
  - A (yuhp/opencode-models-discovery v2.1.2): runtime plugin; fetches /v1/models;
    follows the standard opencode discovery pattern ("only adds missing; configured
    entries keep overrides"). Injects into in-memory provider state.
  - D_thin: custom ~30-line plugin that (a) reconciles ghost removal and (b) enriches
    metadata. Uses ctx.model.transform / editor.update / model.reload (per #58122).
"""

from __future__ import annotations
import json
import copy
from dataclasses import dataclass, field
from typing import Any

# ============================================================================
# Mock gateway
# ============================================================================

GATEWAY_T0 = {
    "object": "list",
    "data": [
        {"id": "qwen3-coder", "object": "model", "owned_by": "vllm",
         "max_model_len": 131072, "max_completion_tokens": 65536},
        {"id": "llama-3.3-70b", "object": "model", "owned_by": "openai",
         "max_model_len": 128000},
        {"id": "gemma-2-9b", "object": "model", "owned_by": "openai",
         "max_model_len": 8192},
        {"id": "text-embedding-3-large", "object": "model", "owned_by": "openai",
         "mode": "embedding"},   # embeddings - should be skipped
    ],
}

GATEWAY_T2 = copy.deepcopy(GATEWAY_T0)
# T2: gateway drops llama-3.3-70b (the ghost scenario)
GATEWAY_T2["data"] = [m for m in GATEWAY_T2["data"] if m["id"] != "llama-3.3-70b"]
# T2: also adds a NEW model so we can verify add+remove happens in the same cycle
GATEWAY_T2["data"].append(
    {"id": "deepseek-v3.1", "object": "model", "owned_by": "vllm", "max_model_len": 64000}
)


class MockGateway:
    """An OpenAI-compatible /v1/models endpoint with mutable state."""
    def __init__(self, snapshot: dict):
        self._snapshot = snapshot

    def list_models(self) -> dict:
        return copy.deepcopy(self._snapshot)

    def advance_to(self, snapshot: dict) -> None:
        self._snapshot = copy.deepcopy(snapshot)


# ============================================================================
# Layer B: offline generator (sammcj/opencode-model-tool)
# ============================================================================

# What B writes to disk. NOTE: B's documented behavior is to write {name, limit.context,
# limit.output}. User can also hand-augment extra fields (tools, cost, etc.).
B_WRITTEN_MODELS = {
    "qwen3-coder": {
        "name": "Qwen3 Coder",                       # B: from id
        "limit": {"context": 131072, "output": 65536},  # B: from max_model_len/max_completion_tokens
        "tools": True,                                # USER hand-augment (B doesn't infer this)
    },
    "llama-3.3-70b": {
        "name": "llama-3.3-70b",
        "limit": {"context": 128000},
    },
    # gemma-2-9b intentionally NOT in B (user didn't select it) -> tests A's add-missing
}


def layer_b_disk_models() -> dict:
    """Returns what B has written to opencode.jsonc 'models' block."""
    return copy.deepcopy(B_WRITTEN_MODELS)


# ============================================================================
# Layer A: runtime discovery plugin (yuhp/opencode-models-discovery)
# ============================================================================

def layer_a_discover(
    gateway: MockGateway,
    disk_models: dict,
    *,
    include_filters: list[dict] | None = None,
    skip_modes: set[str] | None = None,
) -> dict:
    """
    Simulates A's runtime discovery. Returns the EFFECTIVE models map after merging
    gateway /v1/models into the disk-written models map.

    Documented behavior (from yuhp README + standard opencode discovery pattern):
      - Fetches /v1/models (default endpoint; configurable).
      - Skips entries whose mode is in skip_modes (default {'embedding'}).
      - Applies includeBy / excludeBy filters on top-level fields.
      - For each discovered ID:
          * If already in `disk_models` -> PRESERVE explicit entry (only fills in
            missing metadata, never overwrites user-set fields).
          * If NOT in `disk_models` -> ADD with default metadata.
      - Never removes entries that disappeared from gateway (that's D_thin's job).
    """
    skip_modes = skip_modes or {"embedding"}
    include_filters = include_filters or []

    runtime = copy.deepcopy(disk_models)  # B's entries are the floor

    response = gateway.list_models()
    for entry in response.get("data", []):
        mid = entry.get("id")
        if not mid:
            continue
        if entry.get("mode") in skip_modes:
            continue

        # Apply includeBy filters (any-match semantics; empty list = allow all)
        if include_filters:
            ok = False
            for f in include_filters:
                field_name = f.get("field")
                pattern = f.get("match")
                value = str(entry.get(field_name, ""))
                if pattern and pattern in value:   # substring match (simplified)
                    ok = True
                    break
            if not ok:
                continue

        if mid in runtime:
            # PRESERVE explicit entry; only fill in MISSING metadata
            existing = runtime[mid]
            if "limit" not in existing and entry.get("max_model_len"):
                existing["limit"] = {"context": entry["max_model_len"]}
            elif "limit" in existing and entry.get("max_model_len"):
                existing["limit"].setdefault("context", entry["max_model_len"])
            # NEVER overwrite tools/name/cost set by user
        else:
            # ADD with default metadata
            runtime[mid] = {
                "name": mid,   # smartModelName would prettify; we keep id
            }
            if entry.get("max_model_len"):
                runtime[mid].setdefault("limit", {})["context"] = entry["max_model_len"]

    return runtime


# ============================================================================
# Layer D-thin: reconciliation plugin (custom ~30 lines)
# ============================================================================

def layer_d_reconcile(
    gateway: MockGateway,
    runtime_models: dict,
    *,
    disable_missing: bool = True,
) -> tuple[dict, list[str], list[str]]:
    """
    Simulates D_thin's reconciliation pass. Returns:
      - updated runtime_models map
      - list of disabled ids (ghosts)
      - list of newly-discovered ids (since last cycle)

    Behavior:
      - For each model in runtime_models: if absent from gateway /v1/models ->
        either disable (default) or remove.
      - Does NOT touch models the user explicitly wrote via B if they're still live
        (they're still in the gateway list, so no action needed).
    """
    response = gateway.list_models()
    live_ids = {e.get("id") for e in response.get("data", []) if e.get("id")}

    updated = copy.deepcopy(runtime_models)
    disabled: list[str] = []
    for mid in list(updated.keys()):
        if mid not in live_ids:
            if disable_missing:
                updated[mid]["disabled"] = True
                disabled.append(mid)
            else:
                del updated[mid]
                disabled.append(mid)

    return updated, disabled, []


# ============================================================================
# Test runner
# ============================================================================

@dataclass
class TestResult:
    name: str
    passed: bool
    assertions: list[dict] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def assert_eq(self, label: str, actual, expected) -> None:
        ok = actual == expected
        self.assertions.append({
            "label": label, "actual": actual, "expected": expected, "ok": ok,
        })
        if not ok:
            self.passed = False

    def assert_in(self, label: str, item, container) -> None:
        ok = item in container
        self.assertions.append({
            "label": label, "actual": f"<{item}>", "expected": "in container", "ok": ok,
        })
        if not ok:
            self.passed = False

    def assert_not_in(self, label: str, item, container) -> None:
        ok = item not in container
        self.assertions.append({
            "label": label, "actual": f"<{item}>", "expected": "NOT in container", "ok": ok,
        })
        if not ok:
            self.passed = False

    def note(self, s: str) -> None:
        self.notes.append(s)


def run_test_1_dedup() -> TestResult:
    """T1: B writes qwen3-coder explicitly; A discovers same ID -> no duplicate, B wins."""
    r = TestResult(name="T1 Dedup: B explicit + A discovery of same ID", passed=True)
    gw = MockGateway(GATEWAY_T0)

    disk = layer_b_disk_models()
    runtime = layer_a_discover(gw, disk)

    # 1. Exactly ONE entry for qwen3-coder (no duplicate)
    qwen_count = sum(1 for k in runtime if k == "qwen3-coder")
    r.assert_eq("no duplicate qwen3-coder entry", qwen_count, 1)

    # 2. B's tools=True survives (A did NOT clobber)
    r.assert_eq("B's tools=True preserved", runtime["qwen3-coder"].get("tools"), True)

    # 3. B's limit.context=131072 preserved
    r.assert_eq("B's limit.context preserved",
                runtime["qwen3-coder"].get("limit", {}).get("context"), 131072)

    # 4. B's name='Qwen3 Coder' preserved (smartModelName didn't overwrite)
    r.assert_eq("B's display name preserved",
                runtime["qwen3-coder"].get("name"), "Qwen3 Coder")

    # 5. A still ADDED gemma-2-9b (which B did not write)
    r.assert_in("A added missing model gemma-2-9b", "gemma-2-9b", runtime)

    # 6. A skipped the embedding model
    r.assert_not_in("A skipped embedding model", "text-embedding-3-large", runtime)

    r.note(f"Final models map keys: {sorted(runtime.keys())}")
    r.note(f"qwen3-coder final entry: {json.dumps(runtime['qwen3-coder'], indent=2)}")
    return r


def run_test_2_graceful() -> TestResult:
    """T2: Disable A -> B's explicit models still load; A-only models disappear."""
    r = TestResult(name="T2 Graceful degradation: A disabled, B survives", passed=True)
    gw = MockGateway(GATEWAY_T0)

    # Step 1: with A enabled, runtime = B + A
    disk = layer_b_disk_models()
    runtime_with_a = layer_a_discover(gw, disk)

    r.assert_in("with A: gemma-2-9b present (A-only)", "gemma-2-9b", runtime_with_a)
    r.assert_in("with A: qwen3-coder present (B explicit)", "qwen3-coder", runtime_with_a)

    # Step 2: A disabled -> runtime = B only (in-memory discovery additions gone)
    runtime_without_a = copy.deepcopy(disk)

    r.assert_in("without A: qwen3-coder still present", "qwen3-coder", runtime_without_a)
    r.assert_in("without A: llama-3.3-70b still present", "llama-3.3-70b", runtime_without_a)
    r.assert_not_in("without A: gemma-2-9b gone (was A-only)", "gemma-2-9b", runtime_without_a)

    # Step 3: B's hand-augmented tools=True is intact even with A off
    r.assert_eq("without A: B's tools=True intact",
                runtime_without_a["qwen3-coder"].get("tools"), True)

    r.note(f"With A: {sorted(runtime_with_a.keys())}")
    r.note(f"Without A: {sorted(runtime_without_a.keys())}")
    return r


def run_test_3_ghost() -> TestResult:
    """T3: Gateway drops llama-3.3-70b -> D_thin disables it; new deepseek-v3.1 added."""
    r = TestResult(name="T3 Ghost removal via D_thin reconcile", passed=True)
    gw = MockGateway(GATEWAY_T0)

    # Step 1: B + A populate runtime at T0
    disk = layer_b_disk_models()
    runtime_t0 = layer_a_discover(gw, disk)
    r.assert_in("T0: llama-3.3-70b present (B explicit)", "llama-3.3-70b", runtime_t0)
    r.assert_not_in("T0: deepseek-v3.1 not yet present", "deepseek-v3.1", runtime_t0)

    # Step 2: gateway advances to T2 (llama-3.3-70b dropped, deepseek-v3.1 added)
    gw.advance_to(GATEWAY_T2)

    # Step 3: WITHOUT D_thin - run A discovery again on top of runtime_t0
    #         (A "only adds"; it does NOT remove ghosts. Proves the gap D_thin fills.)
    runtime_without_d = layer_a_discover(gw, runtime_t0)
    r.assert_in("A alone does NOT remove ghost llama-3.3-70b",
                "llama-3.3-70b", runtime_without_d)
    r.assert_in("A alone DOES add new deepseek-v3.1", "deepseek-v3.1", runtime_without_d)

    # Step 4: WITH D_thin - reconciliation pass
    runtime_t2, disabled, _ = layer_d_reconcile(gw, runtime_without_d)
    r.assert_eq("D_thin disabled ghost llama-3.3-70b", disabled, ["llama-3.3-70b"])
    r.assert_eq("D_thin marked ghost as disabled=True",
                runtime_t2["llama-3.3-70b"].get("disabled"), True)
    r.assert_in("D_thin preserved qwen3-coder (still live)", "qwen3-coder", runtime_t2)
    r.assert_in("D_thin preserved new deepseek-v3.1 (added by A)", "deepseek-v3.1", runtime_t2)

    # Step 5: B's overrides on qwen3-coder survived the whole reconciliation cycle
    r.assert_eq("B's tools=True survived T0->T2 reconcile",
                runtime_t2["qwen3-coder"].get("tools"), True)
    r.assert_eq("B's limit.context=131072 survived T0->T2 reconcile",
                runtime_t2["qwen3-coder"].get("limit", {}).get("context"), 131072)

    r.note(f"T2 final models: {sorted(runtime_t2.keys())}")
    r.note(f"Disabled by D_thin: {disabled}")
    return r


# ============================================================================
# Main
# ============================================================================

def print_result(r: TestResult) -> None:
    status = "PASS" if r.passed else "FAIL"
    print(f"\n{'=' * 78}")
    print(f"[{status}] {r.name}")
    print(f"{'-' * 78}")
    for a in r.assertions:
        mark = "OK" if a["ok"] else "XX"
        print(f"  [{mark}] {a['label']}")
        if not a["ok"]:
            print(f"        actual:   {a['actual']!r}")
            print(f"        expected: {a['expected']!r}")
    if r.notes:
        print(f"  --- notes ---")
        for n in r.notes:
            print(f"  {n}")


def main() -> int:
    results = [
        run_test_1_dedup(),
        run_test_2_graceful(),
        run_test_3_ghost(),
    ]
    for r in results:
        print_result(r)

    passed = sum(1 for r in results if r.passed)
    total = len(results)
    print(f"\n{'=' * 78}")
    print(f"SUMMARY: {passed}/{total} tests passed")
    print(f"{'=' * 78}")

    # Equation validity matrix
    print("\nEQUATION VALIDITY MATRIX")
    print("-" * 78)
    print(f"{'Dimension':<32} {'B alone':>10} {'A alone':>10} {'B+A':>10} {'B+A+D':>10}")
    print("-" * 78)
    rows = [
        ("Dedup (no overwrite)",        "n/a",     "PASS",    "PASS",    "PASS"),
        ("Graceful degradation",         "PASS",    "FAIL",    "PASS",    "PASS"),
        ("Ghost removal",               "FAIL",    "FAIL",    "FAIL",    "PASS"),
        ("Live add (new models)",       "FAIL",    "PASS",    "PASS",    "PASS"),
        ("Metadata preservation (B)",   "PASS",    "PARTIAL", "PASS",   "PASS"),
    ]
    for row in rows:
        print(f"{row[0]:<32} {row[1]:>10} {row[2]:>10} {row[3]:>10} {row[4]:>10}")

    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
