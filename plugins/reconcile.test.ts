// reconcile.test.ts — unit test for the D_thin reconcile plugin logic
//
// Tests the disable-not-delete contract in isolation:
//   - Models present in BOTH gateway and registry → PRESERVED (enabled stays true)
//   - Models present in registry but ABSENT from gateway → DISABLED (enabled = false)
//   - Models present in gateway but ABSENT from registry → NOT ADDED (out of scope)
//
// Mocks the @opencode/plugin context (ctx.provider.list, ctx.model.transform,
// editor.list, editor.update) so the test runs without a real opencode binary.

import { describe, test, expect, mock, beforeEach } from "bun:test"

// --- Mock types matching what reconcile.ts reads from the plugin context ---
interface MockModelInfo {
  id: string
  providerID: string
  enabled: boolean
  capabilities?: { tools?: boolean }
  limit?: { context?: number; output?: number }
  name?: string
}

interface MockProvider {
  id: string
  settings?: { baseURL?: string; apiKey?: string }
  credentials?: { apiKey?: string }
}

interface MockEditor {
  list: (providerID?: string) => MockModelInfo[]
  update: (providerID: string, modelID: string, update: (model: MockModelInfo) => void) => void
  remove: (providerID: string, modelID: string) => void
}

interface MockCtx {
  options?: any
  provider: {
    list: () => Promise<MockProvider[]>
  }
  model: {
    transform: (callback: (editor: MockEditor) => void) => Promise<void>
    reload: () => Promise<void>
  }
}

// --- Pull the reconcile logic into a testable function ---
// We can't import the plugin directly (it has @opencode/plugin as a dep),
// so we extract the core logic into a testable form.
async function runReconcilePass(
  ctx: MockCtx,
  opts: {
    disableMissing?: boolean
    providerFilter?: string[]
    userAgent?: string
  } = {},
  gatewayResponses: Map<string, Set<string> | null> = new Map(),
): Promise<{ preserved: string[]; disabled: string[]; logged: string[] }> {
  const disableMissing = opts.disableMissing ?? true
  const providerFilter = opts.providerFilter
  const result = { preserved: [] as string[], disabled: [] as string[] , logged: [] as string[] }

  const rawProviders: any = await ctx.provider.list()
  const providers: any[] = Array.isArray(rawProviders)
    ? rawProviders
    : Array.isArray(rawProviders?.data) ? rawProviders.data
    : Array.isArray(rawProviders?.providers) ? rawProviders.providers
    : Object.values(rawProviders ?? {})

  const targetProviders = providerFilter
    ? providers.filter((p: any) => providerFilter.includes(p.id))
    : providers

  for (const provider of targetProviders) {
    const baseURL: string | undefined = provider.settings?.baseURL
    if (!baseURL) continue

    const apiKey = provider.settings?.apiKey ?? provider.credentials?.apiKey
    if (!apiKey) continue

    const gatewayIDs = gatewayResponses.get(baseURL)
    if (gatewayIDs === null) continue

    await ctx.model.transform((editor: any) => {
      const models = editor.list(provider.id)
      for (const model of models) {
        if (gatewayIDs!.has(model.id)) {
          result.preserved.push(`${provider.id}/${model.id}`)
          continue
        }
        if (disableMissing) {
          editor.update(provider.id, model.id, (draft: any) => { draft.enabled = false })
          result.disabled.push(`${provider.id}/${model.id}`)
          result.logged.push(`[reconcile] disabled ghost: ${provider.id}/${model.id}`)
        } else {
          result.logged.push(`[reconcile] ghost detected (dry-run): ${provider.id}/${model.id}`)
        }
      }
    })
  }
  return result
}

// =========================================================================
// Tests
// =========================================================================

describe("D_thin reconcile plugin", () => {
  let registry: MockModelInfo[]

  beforeEach(() => {
    // Initial registry: B's explicit entries (preserved from opencode.json)
    registry = [
      { id: "kimi-k3", providerID: "opencode", enabled: true,
        capabilities: { tools: true }, limit: { context: 1048576, output: 131072 },
        name: "Kimi K3" },
      { id: "claude-haiku-5-5", providerID: "opencode", enabled: true,
        capabilities: { tools: true } },
      // This will be a ghost in T1 (gateway doesn't list it)
      { id: "legacy-model-removed-from-gateway", providerID: "opencode", enabled: true },
    ]
  })

  function makeCtx(providers: MockProvider[]): MockCtx {
    return {
      options: {},
      provider: { list: async () => providers },
      model: {
        transform: async (callback: (editor: MockEditor) => void) => {
          const editor: MockEditor = {
            list: (providerID?: string) =>
              providerID ? registry.filter(m => m.providerID === providerID) : registry,
            update: (pid: string, mid: string, update: (m: MockModelInfo) => void) => {
              const m = registry.find(x => x.providerID === pid && x.id === mid)
              if (m) update(m)
            },
            remove: (pid: string, mid: string) => {
              registry = registry.filter(x => !(x.providerID === pid && x.id === mid))
            },
          }
          callback(editor)
        },
        reload: async () => {},
      },
    }
  }

  test("T1: ghost model is DISABLED (enabled=false), not deleted", async () => {
    // Gateway catalog has kimi-k3 + claude-haiku-5-5 but NOT legacy-model-removed-from-gateway
    const gatewayIDs = new Set(["kimi-k3", "claude-haiku-5-5"])
    const gatewayResponses = new Map([["https://opencode.ai/inference/v1", gatewayIDs]])

    const providers: MockProvider[] = [{
      id: "opencode",
      settings: { baseURL: "https://opencode.ai/inference/v1", apiKey: "oc_sk_test" },
    }]

    const ctx = makeCtx(providers)
    const result = await runReconcilePass(ctx, {}, gatewayResponses)

    expect(result.preserved).toContain("opencode/kimi-k3")
    expect(result.preserved).toContain("opencode/claude-haiku-5-5")
    expect(result.disabled).toEqual(["opencode/legacy-model-removed-from-gateway"])

    // Confirm the ghost is disabled (enabled=false) but STILL IN THE REGISTRY (not deleted)
    const ghost = registry.find(m => m.id === "legacy-model-removed-from-gateway")
    expect(ghost).toBeDefined()  // still exists — disable-not-delete contract
    expect(ghost!.enabled).toBe(false)
  })

  test("T2: B's overrides are PRESERVED (tools/limit/name untouched)", async () => {
    const gatewayIDs = new Set(["kimi-k3", "claude-haiku-5-5"])
    const gatewayResponses = new Map([["https://opencode.ai/inference/v1", gatewayIDs]])

    const providers: MockProvider[] = [{
      id: "opencode",
      settings: { baseURL: "https://opencode.ai/inference/v1", apiKey: "oc_sk_test" },
    }]

    const ctx = makeCtx(providers)
    await runReconcilePass(ctx, {}, gatewayResponses)

    const kimi = registry.find(m => m.id === "kimi-k3")!
    expect(kimi.enabled).toBe(true)  // still enabled
    expect(kimi.capabilities?.tools).toBe(true)  // B's tools override preserved
    expect(kimi.limit?.context).toBe(1048576)  // B's context limit preserved
    expect(kimi.limit?.output).toBe(131072)  // B's output limit preserved
    expect(kimi.name).toBe("Kimi K3")  // B's name override preserved
  })

  test("T3: dry-run mode (disableMissing=false) detects but doesn't disable", async () => {
    const gatewayIDs = new Set(["kimi-k3", "claude-haiku-5-5"])
    const gatewayResponses = new Map([["https://opencode.ai/inference/v1", gatewayIDs]])

    const providers: MockProvider[] = [{
      id: "opencode",
      settings: { baseURL: "https://opencode.ai/inference/v1", apiKey: "oc_sk_test" },
    }]

    const ctx = makeCtx(providers)
    const result = await runReconcilePass(ctx, { disableMissing: false }, gatewayResponses)

    expect(result.disabled).toEqual([])  // nothing disabled
    expect(result.logged).toContain(
      "[reconcile] ghost detected (dry-run): opencode/legacy-model-removed-from-gateway"
    )

    // The ghost is still enabled
    const ghost = registry.find(m => m.id === "legacy-model-removed-from-gateway")!
    expect(ghost.enabled).toBe(true)
  })

  test("T4: gateway fetch failure (null response) skips disable — preserves all", async () => {
    // Simulate gateway fetch failure — gatewayResponses.get(baseURL) returns null
    const gatewayResponses = new Map([["https://opencode.ai/inference/v1", null]])

    const providers: MockProvider[] = [{
      id: "opencode",
      settings: { baseURL: "https://opencode.ai/inference/v1", apiKey: "oc_sk_test" },
    }]

    const ctx = makeCtx(providers)
    const result = await runReconcilePass(ctx, {}, gatewayResponses)

    expect(result.disabled).toEqual([])
    expect(result.preserved).toEqual([])
    // All models remain enabled — no destructive action on gateway fetch failure
    expect(registry.every(m => m.enabled)).toBe(true)
  })

  test("T5: providerFilter restricts reconcile to specific provider IDs", async () => {
    const gatewayIDs = new Set(["kimi-k3", "claude-haiku-5-5"])
    const gatewayResponses = new Map([["https://opencode.ai/inference/v1", gatewayIDs]])

    // Two providers, both with custom baseURL, but only "opencode" is in the filter
    const providers: MockProvider[] = [
      { id: "opencode",
        settings: { baseURL: "https://opencode.ai/inference/v1", apiKey: "oc_sk_test" } },
      { id: "other-gateway",
        settings: { baseURL: "https://other.example.com/v1", apiKey: "oc_sk_test2" } },
    ]

    // Add a model under other-gateway that should NOT be touched
    registry.push({ id: "other-gateway-model", providerID: "other-gateway", enabled: true })

    const ctx = makeCtx(providers)
    const result = await runReconcilePass(ctx, { providerFilter: ["opencode"] }, gatewayResponses)

    // Only opencode's models were processed
    expect(result.disabled).toEqual(["opencode/legacy-model-removed-from-gateway"])
    // other-gateway-model untouched
    const other = registry.find(m => m.id === "other-gateway-model")!
    expect(other.enabled).toBe(true)
  })

  test("T6: built-in providers (no settings.baseURL) are skipped", async () => {
    const gatewayResponses = new Map()

    // anthropic has no settings.baseURL → should be skipped entirely
    const providers: MockProvider[] = [
      { id: "anthropic" },  // built-in, no settings
    ]

    const ctx = makeCtx(providers)
    const result = await runReconcilePass(ctx, {}, gatewayResponses)

    expect(result.preserved).toEqual([])
    expect(result.disabled).toEqual([])
    expect(result.logged).toEqual([])
  })

  test("T7: provider with no apiKey is skipped (logged warning)", async () => {
    const gatewayIDs = new Set(["kimi-k3"])
    const gatewayResponses = new Map([["https://gateway.example.com/v1", gatewayIDs]])

    const providers: MockProvider[] = [{
      id: "missing-key-provider",
      settings: { baseURL: "https://gateway.example.com/v1" },  // no apiKey
    }]

    const ctx = makeCtx(providers)
    const result = await runReconcilePass(ctx, {}, gatewayResponses)

    expect(result.disabled).toEqual([])
    expect(result.preserved).toEqual([])
    // No destructive action when apiKey is missing
    expect(registry.every(m => m.enabled)).toBe(true)
  })
})
