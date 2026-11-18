import { generateText } from 'ai';

// VERCEL AI GATEWAY — primary configuration
//
// This is the canonical Vercel AI Gateway setup as documented at
// https://ai-sdk.dev/providers/ai-sdk-providers/moonshotai
//
// The `ai` package (v7+) routes bare model strings like 'moonshotai/kimi-k3'
// through the Vercel AI Gateway automatically when AI_GATEWAY_API_KEY is set.
//
// STATUS (verified 2026-11-14):
//   - `ai` package installed: ai@7.0.173
//   - `@ai-sdk/gateway` pulled in automatically
//   - `.env.local` written with AI_GATEWAY_API_KEY (gitignored via .env*)
//   - Auth verified: gateway returns 403 (not 401) — key is valid
//   - Model recognized: gateway resolved 'moonshotai/kimi-k3' -> provider 'baseten'
//
// BLOCKER:
//   The Vercel team account has no AI Gateway credits. The gateway returns
//   `RestrictedModelsError` / `no_providers_available` with
//   `token_pass_not_entitled` skip reason for ALL models, including the
//   free-tier-eligible ones (`reflection/beam-free`, `nvidia/nemotron-3.5-lightning-free`).
//
// FIX:
//   Upgrade at https://vercel.com/[team]/~/ai?modal=top-up
//   Then re-run: `bun run index.ts`
//
// WORKAROUND (returns text now):
//   `bun run index.workaround.ts` — uses @ai-sdk/openai-compatible pointed at
//   the Z.AI OpenAI-compatible endpoint, demonstrating the same AI SDK pattern.

const { text } = await generateText({
  model: 'moonshotai/kimi-k3',
  prompt: 'Invent a new holiday and describe its traditions.',
});

console.log(text);
