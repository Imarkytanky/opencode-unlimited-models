import { generateText } from 'ai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

// OPENCODE INFERENCE GATEWAY — works with `oc_sk_` API keys
//
// Endpoint: https://opencode.ai/inference/v1   (OpenAI-compatible)
// Catalog:  https://opencode.ai/inference/v1/models  (52 models as of 2026-11-14)
//
// IMPORTANT: free-tier models (id ends in `-free`, e.g. `glm-5.3-flash-free`)
// return `FreeUsageLimitError` (HTTP 429) when called from external scripts.
// They only work from within the OpenCode TUI itself.
//
// To use a free model from a script, you need a paid/Go subscription.
// Paid models like `kimi-k3` work via this script and bill against your
// account balance ($0.0011 for a short prompt at time of writing).
//
// Set OPENCODE_API_KEY in .env.local (or your environment).

if (!process.env.OPENCODE_API_KEY) {
  throw new Error('OPENCODE_API_KEY env var is required (set in .env.local)');
}

const opencode = createOpenAICompatible({
  name: 'opencode',
  baseURL: 'https://opencode.ai/inference/v1',
  apiKey: process.env.OPENCODE_API_KEY,
});

const { text } = await generateText({
  model: opencode('kimi-k3'),
  prompt: 'Invent a new holiday and describe its traditions.',
});

console.log(text);
