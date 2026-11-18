import { generateText } from 'ai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

// OPENCODE ZEN FREE TIER — via opencode-egress-router proxy
//
// Setup:
//   1. Build & run the proxy (scripts/launch-oc-proxy.sh)
//      → listens on 127.0.0.1:8318, forwards to https://opencode.ai/zen/v1
//      → for free-tier model IDs (*-free, big-pickle), rewrites the request
//        to pass Zen's "from within OpenCode" gate (TLS fingerprint spoofing,
//        session-id generation, bash/read tool stubs)
//      → for paid models with real oc_sk_ keys, passes through unchanged
//
//   2. Configure the AI SDK with createOpenAICompatible:
//        baseURL: http://127.0.0.1:8318
//        apiKey:  "public"   (free-tier routing; real keys also work for paid)
//
// Free-tier model IDs (no credits required):
//   - glm-5.3-flash-free, mimo-v2.6-flash-free, deepseek-v4.1-flash-free
//   - longcat-2.5-free, iceman-free, inkling-2-small-free, beam-free
//   - flint-40b-free, nemotron-3.5-super-vl-free, nemotron-3.5-lightning-free
//   - minimax-m3.1-flash-free, big-pickle

const zen = createOpenAICompatible({
  name: 'opencode-zen',
  baseURL: 'http://127.0.0.1:8318',
  apiKey: 'public',  // free-tier routing; real OPENCODE_API_KEY also works
});

const { text } = await generateText({
  model: zen('glm-5.3-flash-free'),
  prompt: 'Invent a new holiday and describe its traditions.',
});

console.log(text);
