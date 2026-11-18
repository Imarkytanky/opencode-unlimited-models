// examples/index.oc-proxy-agent.ts — Strategic compose: Layer P + Layer W
//
// "Point a hosted agent at your Space and give it web research; the whole
// loop then runs off-box." This file is the client half of that compose:
// the model gateway is the hosted oc-proxy HF Space (Layer P), the research
// half is the deterministic browser-search skill (Layer W) — nothing here
// depends on a local model daemon, so this runs from any machine, CI, phone.
//
// Pipeline (identical contract to examples/index.layer-w.ts, remote gateway):
//   1. Layer W tier 1 (SearXNG): search the web for fresh URLs
//   2. Layer W tier 2 (smart-extract): pull clean text from the top result
//   3. Layer P (oc-proxy HF Space): grounded answer via a *-free model
//
// Prerequisites:
//   - oc-proxy deployed: HF_TOKEN=<PRO token> bash oc-proxy/deploy-oc-proxy-hf.sh
//     (or any host: node oc-proxy/server.js, then point OC_PROXY_HF_BASE at it)
//   - Layer W installed (cd browser-search && npm install && ensureBinary)
//   - SearXNG running (docker compose --profile search up -d OR native)
//
// Usage:
//   export OC_PROXY_KEY='<the GATEWAY_API_KEY printed by the deploy script>'
//   bun run examples/index.oc-proxy-agent.ts "What is the latest opencode version?"
//
// Costs:
//   - SearXNG search: $0 (self-hosted)
//   - CloakBrowser extraction: $0 (self-hosted, ~5 s)
//   - Model call (oc-proxy -> opencode free tier): $0
//   - Hosting: $0 on free VPS; HF Space requires PRO (see README-STACK.md)

import { generateText } from 'ai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BS = resolve(ROOT, 'browser-search');

// Layer P endpoint — the hosted gateway, not localhost.
// Default: this account's Space (https://<user>-<space>.hf.space).
const OC_BASE = process.env.OC_PROXY_HF_BASE ?? 'https://markywinning-oc-proxy.hf.space';
const OC_KEY = process.env.OC_PROXY_KEY;
if (!OC_KEY) {
  console.error('Set OC_PROXY_KEY to the GATEWAY_API_KEY configured on the Space.');
  console.error('  (deploy-oc-proxy-hf.sh prints it once after step 5)');
  process.exit(1);
}

// Model: any *-free id from GET $OC_BASE/v1/models (upstream rotates ids —
// the live catalog is the source of truth, muse-spark was retired 2026-11).
const MODEL = process.env.OC_PROXY_MODEL ?? 'glm-5.3-flash-free';

const question = process.argv[2] ?? 'What is the latest stable version of opencode?';

// -- Layer W tier 1: SearXNG search ------------------------------------------------
// Deterministic script, invoked verbatim — the model never types this command
// (anti-hallucination by design, unchanged from the layer-w example).
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
  process.exit(1);
}

// -- Layer W tier 2: extract content from the top URL ------------------------------
console.log(`\n[2/3] Layer W tier 2: extracting content from top URL via smart-extract`);
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

// -- Layer P: grounded answer through the hosted gateway -----------------------------
console.log(`\n[3/3] Layer P: grounded answer via ${MODEL} @ ${OC_BASE} (hosted, off-box)`);
const gateway = createOpenAICompatible({
  name: 'oc-proxy-hf',
  baseURL: `${OC_BASE.replace(/\/+$/, '')}/v1`,
  apiKey: OC_KEY,
});

const { text } = await generateText({
  model: gateway(MODEL),
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
console.log(`Model layer: ${MODEL} via oc-proxy (hosted gateway) — $0/req`);
console.log('The research + inference loop ran entirely off-box.');
