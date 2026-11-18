// examples/index.layer-w-compare.ts — compare two models' answers on the same research
//
// Demonstrates the v12 stack's model-comparison capability: the same researched
// source text is fed to two different models (free vs paid, or two free models),
// and the outputs are printed side-by-side for quality comparison.
//
// Pipeline:
//   1. Layer W: SearXNG search + CloakBrowser extraction (once, shared)
//   2. Model A: glm-5.3-flash-free (Zen free, $0/req) — grounded answer
//   3. Model B: kimi-k3 (Console paid, ~$0.0006/req) — grounded answer
//   4. Side-by-side comparison
//
// Usage:
//   bun run examples/index.layer-w-compare.ts "What is the latest opencode version?"
//
// Prerequisites:
//   - Layer D proxy running on :8318
//   - OPENCODE_API_KEY in .env.local (for the paid model comparison)
//   - SearXNG running on :8080
//   - CloakBrowser Chromium binary installed
//
// Cost: ~$0.0006 (one paid kimi-k3 call; the free call and all research is $0)

import { generateText } from 'ai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { readFileSync } from 'node:fs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BS = resolve(ROOT, 'browser-search');

const question = process.argv[2] ?? 'What is the latest stable version of opencode?';

// Load .env.local for OPENCODE_API_KEY (paid model path)
try {
  const env = readFileSync(resolve(ROOT, '.env.local'), 'utf8');
  for (const line of env.split('\n')) {
    const m = line.match(/^OPENCODE_API_KEY=(.+)$/);
    if (m) process.env.OPENCODE_API_KEY = m[1].trim().replace(/^["']|["']$/g, '');
  }
} catch { /* .env.local may not exist in some environments */ }

// -- Layer W: search + extract (shared between both models) --------------------
console.log(`\n[1/4] Layer W: searching SearXNG for "${question}"`);
const searchOut = execSync(
  `node ${BS}/scripts/searxng/searxng.mjs search "${question.replace(/"/g, '\\"')}" --lang en --time-range month`,
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
);
const search = JSON.parse(searchOut);
const urls = (search.results ?? []).slice(0, 1).map((r: any) => r.url as string);
if (urls.length === 0) { console.error('No search results'); process.exit(1); }
console.log(`      top URL: ${urls[0]}`);

console.log(`\n[2/4] Layer W: extracting content via CloakBrowser`);
const extractOut = execSync(
  `node ${BS}/scripts/smart-extract.mjs --fallback "${urls[0]}"`,
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 120000 },
);
const extract = JSON.parse(extractOut);
const sourceText = extract.results?.[0]?.content?.slice(0, 4000) ?? '';
if (!sourceText) { console.error('Extraction failed'); process.exit(1); }
console.log(`      extracted ${sourceText.length} chars`);

const instructions =
  'You are a research assistant. Use ONLY the source text below to answer. ' +
  'If the answer is not in the source, say so explicitly. Never invent facts.\n\n' +
  `Source: ${urls[0]}\n\n--- SOURCE START ---\n${sourceText}\n--- SOURCE END ---`;

// -- Model A: free-tier (Zen bypass) -------------------------------------------
console.log(`\n[3/4] Model A: glm-5.3-flash-free via Zen ($0/req)`);
const zen = createOpenAICompatible({
  name: 'opencode-zen',
  baseURL: 'http://127.0.0.1:8318',
  apiKey: 'public',
});

let answerA: string;
try {
  const result = await generateText({
    model: zen('glm-5.3-flash-free'),
    instructions,
    prompt: question,
  });
  answerA = result.text;
  console.log(`      ${answerA.length} chars, $0 cost`);
} catch (e: any) {
  answerA = `[ERROR: ${e.message?.slice(0, 100)}]`;
  console.log(`      ${answerA}`);
}

// -- Model B: paid (Console gateway) -------------------------------------------
console.log(`\n[4/4] Model B: kimi-k3 via Console (~$0.0006/req)`);
let answerB: string;
if (process.env.OPENCODE_API_KEY) {
  const console = createOpenAICompatible({
    name: 'opencode-console',
    baseURL: 'https://opencode.ai/inference/v1',
    apiKey: process.env.OPENCODE_API_KEY,
  });
  try {
    const result = await generateText({
      model: console('kimi-k3'),
      // kimi-k3 accepts system messages (unlike Zen free-tier)
      messages: [
        { role: 'system', content: instructions },
        { role: 'user', content: question },
      ],
    });
    answerB = result.text;
    console.log(`      ${answerB.length} chars, ~$0.0006 cost`);
  } catch (e: any) {
    answerB = `[ERROR: ${e.message?.slice(0, 100)}]`;
    console.log(`      ${answerB}`);
  }
} else {
  answerB = '[SKIPPED: OPENCODE_API_KEY not set in .env.local]';
  console.log(`      ${answerB}`);
}

// -- Side-by-side comparison ---------------------------------------------------
console.log('\n════════════════════════════════════════════════════════════════');
console.log('                    SIDE-BY-SIDE COMPARISON');
console.log('════════════════════════════════════════════════════════════════');
console.log(`\nQuestion: ${question}`);
console.log(`Source:   ${urls[0]}`);
console.log('\n┌─ Model A: glm-5.3-flash-free (Zen free, $0) ────────────────');
console.log(answerA);
console.log('└───────────────────────────────────────────────────────────────');
console.log('\n┌─ Model B: kimi-k3 (Console paid, ~$0.0006) ────────────────');
console.log(answerB);
console.log('└───────────────────────────────────────────────────────────────');
console.log('\n════════════════════════════════════════════════════════════════');
