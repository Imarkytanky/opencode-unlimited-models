// ============================================================================
// reconcile.ts — Layer D_thin: ghost reconciliation plugin for opencode v2
//
// Plugin ID: opencode.reconcile
// Package:   @opencode/plugin
// Source:    .opencode/plugins/reconcile.ts (project-local) OR
//            ~/.config/opencode/plugins/reconcile.ts (global)
//
// WHAT IT DOES
//
//   For every provider whose `settings.baseURL` points at a gateway that
//   exposes `/v1/models` (the OpenAI-compatible catalog endpoint), this
//   plugin periodically fetches the live catalog and reconciles the
//   runtime model registry against it:
//
//     - Models present in BOTH the gateway and opencode's registry:
//       PRESERVED VERBATIM. B's explicit overrides (tools, limit, name)
//       are never touched. This is the contract that verify-a-contract.sh
//       validates (assertion C2/C3/C7: "A only adds, never overwrites").
//
//     - Models present in opencode's registry but ABSENT from the gateway:
//       DISABLED (enabled = false). Never deleted — so the user can see
//       what was removed and re-enable manually if desired. This closes
//       the ghost-model gap (a model dropped from the gateway would
//       otherwise linger forever in opencode's model list).
//
//     - Models present in the gateway but ABSENT from opencode's registry:
//       NOT ADDED. That's Layer A's job (opencode-models-discovery or the
//       native discovery in PR #57161). D_thin is reconcile-only.
//
// WHY "DISABLE-NOT-DELETE"
//
//   Deletion is destructive: a model the user explicitly configured (Layer B
//   entry in opencode.json) might disappear from the gateway temporarily
//   during a deployment or outage. Deleting it would lose the user's
//   hand-set tools/limit overrides. Disabling keeps the entry intact and
//   just greyed-out in the model picker, so when the gateway re-adds it
//   the user's overrides are still there.
//
// CONFIGURATION
//
//   Activate in opencode.json:
//
//     {
//       "$schema": "https://opencode.ai/config.json",
//       "plugins": [
//         "./plugins/reconcile"          // project-local path
//         // OR: "opencode-reconcile"     // published package name
//       ],
//       "providers": {
//         "gateway": {
//           "package": "@opencode/ai/providers/openai-compatible",
//           "settings": {
//             "baseURL": "https://opencode.ai/inference/v1",
//             "apiKey": "{env:OPENCODE_API_KEY}"
//           },
//           "models": { /* Layer B entries */ }
//         }
//       }
//     }
//
//   Plugin options (optional, override via the object form):
//
//     "plugins": [
//       { "package": "./plugins/reconcile", "options": {
//           "intervalMs": 300000,         // refresh interval (default: 5 min)
//           "providers": ["gateway"],    // restrict to these provider IDs
//           "disableMissing": true,      // set false to log-only (dry-run)
//           "userAgent": "opencode/1.19.5"  // UA for /v1/models fetch
//       }}
//     ]
//
// COEXISTENCE
//
//   - With Layer A (opencode-models-discovery or PR #57161 native discovery):
//     compatible. Layer A adds missing models; D_thin disables ghosts.
//     Both run as separate transforms in registration order.
//
//   - With the Magiszonekk opencode-egress-router proxy on :8318:
//     compatible. D_thin reads the gateway's catalog directly; the proxy
//     rewrites individual chat requests. Different layers, no conflict.
//
//   - With the SphinX-lite shim:
//     compatible. The shim wraps the binary; D_thin runs inside the binary.
//
// CONTRACT
//
//   This plugin is the "D_thin" layer that verify-a-contract.sh's README
//   documents as Stage 2. The contract test's C2/C3/C7 assertions validate
//   that B's overrides survive reconciliation. If this plugin ever breaks
//   that contract, the test will catch it (verdict: FAIL).
// ============================================================================

import { Plugin } from "@opencode/plugin"

interface ReconcileOptions {
  intervalMs?: number         // default 300_000 (5 min)
  providers?: string[]         // default: all OpenAI-compatible providers
  disableMissing?: boolean     // default true; false = log-only dry-run
  userAgent?: string           // default "opencode/1.19.5"
}

const DEFAULT_INTERVAL_MS = 300_000
const DEFAULT_USER_AGENT = "opencode/1.19.5"

// OpenAI-compatible /v1/models response shape (minimal subset we read).
interface GatewayModel {
  id: string
  mode?: string  // "embedding" | "chat" | undefined
}
interface GatewayModelsResponse {
  data?: GatewayModel[]
}

export default Plugin.define({
  id: "opencode.reconcile",
  async setup(ctx) {
    const opts: ReconcileOptions = (ctx.options as ReconcileOptions) ?? {}
    const intervalMs = opts.intervalMs ?? DEFAULT_INTERVAL_MS
    const userAgent = opts.userAgent ?? DEFAULT_USER_AGENT
    const disableMissing = opts.disableMissing ?? true

    // Discover which providers to reconcile. Default: every provider whose
    // settings.baseURL is set (i.e., custom OpenAI-compatible gateways).
    // Built-in providers (anthropic, openai, google, etc.) have no
    // settings.baseURL override and are skipped.
    const providerFilter = opts.providers // undefined = all

    // Fetch a provider's /v1/models catalog. Returns a Set of model IDs
    // (excluding embeddings — those are irrelevant to chat model reconcile).
    // Returns null if the fetch failed (network error, 401, 404, etc.) —
    // we don't disable anything when we can't reach the gateway, because
    // a transient outage shouldn't grey out all models.
    async function fetchGatewayModelIDs(baseURL: string, apiKey: string): Promise<Set<string> | null> {
      try {
        // Normalize: ensure /v1 suffix
        const norm = baseURL.replace(/\/+$/, "")
        const url = norm.endsWith("/v1") ? `${norm}/models` : `${norm}/v1/models`
        const resp = await fetch(url, {
          headers: {
            "Authorization": `Bearer ${apiKey}`,
            "User-Agent": userAgent,
          },
          signal: AbortSignal.timeout(10_000),
        })
        if (!resp.ok) {
          console.warn(`[reconcile] ${url} -> HTTP ${resp.status}, skipping reconcile pass`)
          return null
        }
        const json = (await resp.json()) as GatewayModelsResponse
        const ids = new Set<string>()
        for (const m of json.data ?? []) {
          if (m.mode === "embedding") continue  // skip embeddings
          if (!m.id) continue
          ids.add(m.id)
        }
        return ids
      } catch (err) {
        console.warn(`[reconcile] fetch failed for ${baseURL}: ${err}`)
        return null
      }
    }

    // Resolve the actual apiKey value for a provider. opencode.json uses
    // `{env:VAR}` syntax; the runtime resolves it before exposing the
    // provider to plugins via ctx.provider.list() — but the resolved value
    // may be in `provider.settings.apiKey` or `provider.credentials.apiKey`
    // depending on the package version. We try both.
    function resolveApiKey(provider: any): string | undefined {
      return (
        provider?.settings?.apiKey ??
        provider?.credentials?.apiKey ??
        undefined
      )
    }

    // The reconcile transform. Synchronous; reads the current model
    // registry, compares against the gateway catalog, disables ghosts.
    async function reconcileOnce() {
      try {
        // ctx.provider.list() may return either a plain array or an object
        // with a .data field depending on the @opencode/plugin version.
        // Normalize to an array.
        const rawProviders: any = await ctx.provider.list()
        const providers: any[] = Array.isArray(rawProviders)
          ? rawProviders
          : Array.isArray(rawProviders?.data)
            ? rawProviders.data
            : Array.isArray(rawProviders?.providers)
              ? rawProviders.providers
              : Object.values(rawProviders ?? {})

        const targetProviders = providerFilter
          ? providers.filter((p: any) => providerFilter.includes(p.id))
          : providers

        for (const provider of targetProviders) {
          const baseURL: string | undefined = provider.settings?.baseURL
          if (!baseURL) continue  // built-in provider, skip

          const apiKey = resolveApiKey(provider)
          if (!apiKey) {
            console.warn(`[reconcile] no apiKey for ${provider.id}, skipping`)
            continue
          }

          const gatewayIDs = await fetchGatewayModelIDs(baseURL, apiKey)
          if (gatewayIDs === null) continue  // fetch failed; don't disable

          // Register the transform. The editor sees ALL models under this
          // provider (both B-explicit and A-discovered). We only touch
          // models ABSENT from the gateway — set enabled=false, never remove.
          await ctx.model.transform((editor: any) => {
            const models = editor.list(provider.id)
            let disabledCount = 0
            let preservedCount = 0
            for (const model of models) {
              if (gatewayIDs.has(model.id)) {
                preservedCount++
                continue  // model exists in gateway; preserve verbatim
              }
              // Ghost: present in opencode registry, absent from gateway.
              if (disableMissing) {
                editor.update(provider.id, model.id, (draft: any) => {
                  draft.enabled = false
                })
                disabledCount++
                console.log(`[reconcile] disabled ghost: ${provider.id}/${model.id}`)
              } else {
                console.log(`[reconcile] ghost detected (dry-run): ${provider.id}/${model.id}`)
              }
            }
            console.log(
              `[reconcile] ${provider.id}: ${preservedCount} preserved, ` +
              `${disabledCount} ${disableMissing ? "disabled" : "ghosts (dry-run)"} ` +
              `(gateway catalog: ${gatewayIDs.size} chat models)`
            )
          })
        }
      } catch (err) {
        console.error(`[reconcile] pass failed: ${err}`)
      }
    }

    // Run once at startup (after a short delay to let Layer A's discovery
    // plugin register its models first — transforms replay in registration
    // order, so D_thin should run AFTER A).
    const startupDelay = setTimeout(() => { void reconcileOnce() }, 5_000)

    // Periodic refresh. Captured inputs (the gateway catalog) are NOT
    // watched automatically; we re-fetch on the interval and call
    // ctx.model.reload() after the transform to re-trigger any downstream
    // transforms that depend on the model registry.
    const timer = setInterval(() => { void reconcileOnce() }, intervalMs)

    // Cleanup: clear timers when plugin unloads.
    return () => {
      clearTimeout(startupDelay)
      clearInterval(timer)
    }
  },
})
