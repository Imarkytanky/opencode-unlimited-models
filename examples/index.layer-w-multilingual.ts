// examples/index.layer-w-multilingual.ts — multilingual research with Layer W
//
// Demonstrates that the same SearXNG + CloakBrowser pipeline works for
// non-English queries. The `--lang` flag in searxng.mjs controls which
// language version of each search engine is queried.
//
// Pipeline:
//   1. Layer W: SearXNG search in Japanese (--lang ja)
//   2. Layer W: extract top URL via CloakBrowser
//   3. Model layer: answer in the same language via Zen free-tier
//
// Usage:
//   bun run examples/index.layer-w-multilingual.ts
//   bun run examples/index.layer-w-multilingual.ts --lang ja "最新の opencode バージョンは？"
//   bun run examples/index.layer-w-multilingual.ts --lang zh "opencode 最新版本是什么？"
//
// Prerequisites: same as index.layer-w.ts
// Cost: $0 (all self-hosted + Zen free-tier)

import { generateText } from 'ai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BS = resolve(ROOT, 'browser-search');

// Parse args: optional --lang XX then the question
let lang = 'ja';
let question = '最新の opencode バージョンは？';  // default: Japanese
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--lang' && args[i + 1]) { lang = args[i + 1]; i++; }
  else { question = args[i]; }
}

console.log(`\n[1/3] Layer W: searching SearXNG (lang=${lang}) for: "${question}"`);
const searchOut = execSync(
  `node ${BS}/scripts/searxng/searxng.mjs search "${question.replace(/"/g, '\\"')}" --lang ${lang} --time-range month`,
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
);
const search = JSON.parse(searchOut);
const urls = (search.results ?? []).slice(0, 1).map((r: any) => r.url as string);
if (urls.length === 0) { console.error('No search results'); process.exit(1); }
console.log(`      found ${search.results?.length ?? 0} results, top: ${urls[0]}`);
for (const r of (search.results ?? []).slice(0, 3)) {
  console.log(`        - ${r.engine}: ${r.title?.slice(0, 60)}`);
}

console.log(`\n[2/3] Layer W: extracting content via CloakBrowser`);
const extractOut = execSync(
  `node ${BS}/scripts/smart-extract.mjs --fallback "${urls[0]}"`,
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 120000 },
);
const extract = JSON.parse(extractOut);
const sourceText = extract.results?.[0]?.content?.slice(0, 4000) ?? '';
console.log(`      extracted ${sourceText.length} chars (mode=${extract.mode})`);

console.log(`\n[3/3] Model layer: answering in ${lang} via glm-5.3-flash-free ($0/req)`);
const zen = createOpenAICompatible({
  name: 'opencode-zen',
  baseURL: 'http://127.0.0.1:8318',
  apiKey: 'public',
});

const { text } = await generateText({
  model: zen('glm-5.3-flash-free'),
  instructions:
    `You are a research assistant. Answer in the same language as the user's question. ` +
    `Use ONLY the source text below. If the answer is not in the source, say so explicitly.\n\n` +
    `Source: ${urls[0]}\n\n--- SOURCE START ---\n${sourceText}\n--- SOURCE END ---`,
  prompt: question,
});

console.log('\n--- Answer ---');
console.log(text);
console.log(`\n--- Source: ${urls[0]} ---`);
console.log(`Language: ${lang}`);
console.log(`Total cost: $0`);
