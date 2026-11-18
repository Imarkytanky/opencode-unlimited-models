"""Weighted scorecard for opencode v2 'unlimited models' workarounds.

Dimensions and weights (sum = 1.0):
  reliability   0.25  - stability of the path on stock opencode v2
  freshness     0.20  - how quickly new gateway models appear
  metadata      0.20  - quality of limits/cost/capabilities per model
  maintenance   0.15  - inverse of upkeep burden (10 = zero burden)
  portability   0.10  - works with any OpenAI-compatible gateway
  futureproof   0.10  - alignment with upstream direction (PR #57161)
"""

W = {
    "reliability": 0.25,
    "freshness": 0.20,
    "metadata": 0.20,
    "maintenance": 0.15,
    "portability": 0.10,
    "futureproof": 0.10,
}

options = {
    "A: opencode-models-discovery plugin (runtime)": {
        "reliability": 6,   # 2 days old, unproven; plugin API itself is stable
        "freshness": 9,     # live runtime discovery + filters + cache
        "metadata": 6,      # smartModelName/modelInfoFormat, but /v1/models is thin
        "maintenance": 7,   # npm install; depend on external maintainer
        "portability": 9,   # endpoint configurable, any gateway
        "futureproof": 7,   # plugin API stable; still useful after E merges
    },
    "B: opencode-model-tool generator (offline)": {
        "reliability": 8,   # explicit config = most stable path
        "freshness": 4,     # stale until re-run
        "metadata": 7,      # writes limit.context/output from gateway metadata
        "maintenance": 8,   # own your config; script optional
        "portability": 9,   # any /v1/models endpoint
        "futureproof": 9,   # explicit models supported in every version, forever
    },
    "C: vllm provider ID + owned_by shim": {
        "reliability": 7,   # built-in, but silently drops non-vllm owned_by
        "freshness": 8,     # 30s poll
        "metadata": 3,      # tools-disabled defaults, placeholder limits
        "maintenance": 5,   # gateway-side owned_by fakery + /health endpoint
        "portability": 3,   # requires gateway control + spoof
        "futureproof": 4,   # hack; upstream may tighten/change filter
    },
    "D: custom plugin (model-transform API)": {
        "reliability": 7,   # you control it; you own the bugs
        "freshness": 9,     # you decide the poll interval
        "metadata": 8,      # only path to FULL metadata mapping
        "maintenance": 4,   # ~100+ lines you maintain
        "portability": 9,   # you write it
        "futureproof": 6,   # v2 plugin API new; ctx APIs may shift
    },
    "E: PR #57161 dev build + experimental flag": {
        "reliability": 5,   # unmerged; dev-build churn; flag off in releases
        "freshness": 9,     # 5-min refresh + config/credential triggers
        "metadata": 5,      # merges chat models only, placeholder metadata
        "maintenance": 2,   # build opencode from source, track PR
        "portability": 9,   # official, any OpenAI-compatible provider
        "futureproof": 10,  # this IS the upstream future
    },
}

print(f"{'Option':<48}", "  ".join(f"{k[:4]:>5}" for k in W), "  TOTAL")
print("-" * 90)
totals = {}
for name, scores in options.items():
    total = sum(scores[k] * W[k] for k in W)
    totals[name] = total
    print(f"{name:<48}", "  ".join(f"{scores[k]:>5}" for k in W), f"  {total:.2f}")

print("-" * 90)
rank = sorted(totals.items(), key=lambda kv: -kv[1])
for i, (name, t) in enumerate(rank, 1):
    print(f"#{i}  {t:.2f}  {name}")

# Synergy stack score: each layer covers another layer's weakest dimensions.
# Take per-dimension MAX across the stacked options (B + A + D-thin).
stack = ["B: opencode-model-tool generator (offline)",
         "A: opencode-models-discovery plugin (runtime)",
         "D: custom plugin (model-transform API)"]
print()
print("SYNERGY STACK  B + A + D-thin (per-dimension best-of):")
best = {k: max(options[s][k] for s in stack) for k in W}
total = sum(best[k] * W[k] for k in W)
print("  ".join(f"{k[:4]}={best[k]}" for k in W), f"  TOTAL = {total:.2f}")

# Penalty applied to the stack for integration friction (duplication risk,
# two moving parts, unverified dedup in the yuhp plugin): -0.8
penalty = 0.8
print(f"  integration-friction penalty: -{penalty:.2f}  ->  NET = {total - penalty:.2f}")
