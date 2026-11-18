import { generateText } from 'ai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

// WORKAROUND — Vercel AI Gateway account has no credits.
//
// This file proves the AI SDK pattern (`generateText` from `ai`) works
// end-to-end by pointing `@ai-sdk/openai-compatible` at the Z.AI
// OpenAI-compatible endpoint, which is configured at /etc/.z-ai-config
// in this environment.
//
// Once Vercel AI Gateway credits are added, switch back to `index.ts`
// (which uses the bare-string `model: 'moonshotai/kimi-k3'` form that
// the `ai` package auto-routes through the Gateway).

interface ZaiConfig {
  baseUrl: string;
  apiKey: string;
  chatId?: string;
  userId?: string;
  token?: string;
}

function loadZaiConfig(): ZaiConfig {
  const candidates = [
    join(process.cwd(), '.z-ai-config'),
    join(homedir(), '.z-ai-config'),
    '/etc/.z-ai-config',
  ];
  for (const p of candidates) {
    try {
      const cfg = JSON.parse(readFileSync(p, 'utf-8'));
      if (cfg.baseUrl && cfg.apiKey) return cfg as ZaiConfig;
    } catch { /* try next */ }
  }
  throw new Error('Z.AI config not found. Expected .z-ai-config in cwd, home, or /etc.');
}

const zaiConfig = loadZaiConfig();

// The Z.AI internal endpoint authenticates via the X-Token header (the
// `apiKey` field is just the literal string "Z.ai"), plus the X-Z-AI-From,
// X-Chat-Id, and X-User-Id session headers that z-ai-web-dev-sdk sends.
const headers: Record<string, string> = {
  'X-Z-AI-From': 'Z',
};
if (zaiConfig.chatId) headers['X-Chat-Id'] = zaiConfig.chatId;
if (zaiConfig.userId) headers['X-User-Id'] = zaiConfig.userId;
if (zaiConfig.token)  headers['X-Token']   = zaiConfig.token;

const zai = createOpenAICompatible({
  name: 'zai',
  baseURL: zaiConfig.baseUrl,
  apiKey: zaiConfig.apiKey,  // sent as Authorization: Bearer <apiKey>
  headers,
});

const { text } = await generateText({
  model: zai('glm-4-plus'),
  prompt: 'Invent a new holiday and describe its traditions.',
});

console.log(text);
