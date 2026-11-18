// examples/index.layer-w.ts — Layer W (browser-search) × model layer composition
//
// Demonstrates the core synergy of the v12 stack: the cheapest model in the
// stack (glm-5.3-flash-free, $0/req via Layer D Zen bypass) + the deterministic
// web research skill (Layer W) = verified live answers without hallucination.
//
// Pipeline:
//   1. Layer W tier 1 (SearXNG): search the web for fresh URLs
//   2. Layer W tier 2 (smart-extract): pull clean text from the top result
//   3. Model layer (Zen free / Console paid): answer the user's question,
//      grounded in the extracted source text
//
// This is the exact "search first, answer second" workflow the SKILL.md
// enforces — implemented here as a single TypeScript file for testing/demo.
//
// Prerequisites:
//   - Layer D proxy running (bash opencode-proxy/launch-oc-proxy.sh)
//   - Layer W installed (cd browser-search && npm install && ensureBinary)
//   - SearXNG running (docker compose --profile search up -d  OR  native)
//
// Usage:
//   bun run examples/index.layer-w.ts "What is the latest opencode version?"
//
// Costs:
//   - SearXNG search: $0 (self-hosted)
//   - CloakBrowser extraction: $0 (self-hosted, ~5 s)
//   - Model call (glm-5.3-flash-free via Zen): $0
//   - Total: $0

import { generateText } from 'ai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BS = resolve(ROOT, 'browser-search');

const question = process.argv[2] ?? 'What is the latest stable version of opencode?';

// -- Layer W tier 1: SearXNG search ------------------------------------------------
//
// Calls the deterministic script verbatim. The model never types this command
// — that is the whole point of the skill (anti-hallucination by design).
console.log(`\n[1/3] Layer W tier 1: searching SearXNG for "${question}"`);
const searchOut = execSync(
  `node ${BS}/scripts/searxng/searxng.mjs search "${question.replace(/"/g, '\\"')}" --lang en --time-range month`,
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
);
const search = JSON.parse(searchOut);
const urls = (search.results ?? []).slice(0, 3).map((r: any) => r.url as string);
console.log(`      found ${search.results?.length ?? 0} results, using top ${urls.length}:`);
for (const u of urls) console.log(`        - ${u}`);

if (urls.length === 0) {
  console.error('\nNo search results — is SearXNG running?');
  console.error('  docker compose --profile search up -d');
  console.error('  OR: see browser-search/README-STACK.md for native install');
  process.exit(1);
}

// -- Layer W tier 2: extract content from the top URL ------------------------------
console.log(`\n[2/3] Layer W tier 2: extracting content from top URL via CloakBrowser`);
const extractOut = execSync(
  `node ${BS}/scripts/smart-extract.mjs --fallback "${urls[0]}"`,
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 120000 },
);
const extract = JSON.parse(extractOut);
const result = extract.results?.[0];
if (!result?.ok) {
  console.error('\nExtraction failed:', result?.error ?? 'unknown');
  process.exit(1);
}
const sourceText = result.content.slice(0, 4000);  // truncate to fit context window
console.log(`      extracted ${result.chars} chars (${result.source}, mode=${extract.mode})`);

// -- Model layer: grounded answer --------------------------------------------------
console.log(`\n[3/3] Model layer: generating grounded answer via glm-5.3-flash-free ($0/req)`);
const zen = createOpenAICompatible({
  name: 'opencode-zen',
  baseURL: 'http://127.0.0.1:8318',
  apiKey: 'public',
});

const { text } = await generateText({
  model: zen('glm-5.3-flash-free'),
  // Some Zen free-tier models reject system messages; use `instructions` instead.
  instructions:
    'You are a research assistant. Use ONLY the source text below to answer. ' +
    'If the answer is not in the source, say so explicitly. Never invent facts.\n\n' +
    `Source: ${urls[0]}\n\n--- SOURCE START ---\n${sourceText}\n--- SOURCE END ---`,
  prompt: question,
});

console.log('\n--- Answer ---');
console.log(text);
console.log(`\n--- Source: ${urls[0]} ---`);
console.log(`Total cost: $0 (Zen free-tier + self-hosted SearXNG + self-hosted CloakBrowser)`);
