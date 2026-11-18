"use strict";

/* server.js — standalone adapter for oc-proxy (Layer P)
 *
 * oc-proxy upstream (MarkDev11/oc-proxy) ships Vercel serverless handlers
 * (api/*.js) that expect a Vercel-style `res.status(code).json(...)` surface
 * on top of Node's http primitives. This adapter provides exactly that
 * surface on a plain Node http server, so the same handler code runs on:
 *   - Hugging Face Spaces (Docker SDK, port 7860)  <- primary target
 *   - any VPS / local machine (node server.js)
 *   - Docker anywhere
 *
 * Routes (identical contract to the Vercel deployment):
 *   GET  /                     -> monitor dashboard (public/index.html)
 *   GET  /api/health           -> health check
 *   GET  /v1/models            -> live *-free model list (5 min cache)
 *   POST /v1/chat/completions  -> OpenAI-shaped chat (stream + non-stream)
 *   GET  /api/stats            -> in-memory stats snapshot (via chat handler)
 *
 * Environment:
 *   PORT                default 7860 (HF Spaces convention)
 *   HOST                default 0.0.0.0 (required for HF Spaces)
 *   OC_PROXY_UPSTREAM_DIR  default <server.js dir>/upstream (where install-oc-proxy.sh clones upstream)
 *   GATEWAY_API_KEY     optional; comma-separated keys; unset = open access
 *   PROXY_FALLBACK / PROXY_POOL_URL / PROXY_TIMEOUT_MS   optional (429 fallback)
 *   SOFT_DEADLINE_MS / ABSOLUTE_DEADLINE_MS  default 50000/55000 on Vercel;
 *                       on HF/VPS there is no platform hard-kill, so raise
 *                       them (e.g. 300000/330000) for long agentic runs.
 *
 * Zero npm dependencies (uses Node >= 18 native fetch).
 */

const http = require("http");
const fs = require("fs");
const path = require("path");

const HOST = process.env.HOST || "0.0.0.0";
const PORT = parseInt(process.env.PORT || "7860", 10) || 7860;

const UPSTREAM_ROOT = path.resolve(
  process.env.OC_PROXY_UPSTREAM_DIR || path.join(__dirname, "upstream")
);

// --- load upstream handlers (fail fast with a clear message) -----------------
let chatHandler, modelsHandler, healthHandler, corsFn;
try {
  chatHandler = require(path.join(UPSTREAM_ROOT, "api/v1/chat/completions.js"));
  modelsHandler = require(path.join(UPSTREAM_ROOT, "api/v1/models.js"));
  healthHandler = require(path.join(UPSTREAM_ROOT, "api/health.js"));
  corsFn = require(path.join(UPSTREAM_ROOT, "lib/opencode.js")).cors;
} catch (e) {
  console.error(
    `[oc-proxy] upstream handlers not found under ${UPSTREAM_ROOT}\n` +
      `[oc-proxy] run: bash install-oc-proxy.sh   (clones MarkDev11/oc-proxy into upstream/)\n` +
      `[oc-proxy] detail: ${e.message}`
  );
  process.exit(1);
}

// --- Vercel-style res helpers -------------------------------------------------
// Upstream handlers use res.status(code).json(obj) / res.status(code).end().
// Native ServerResponse lacks .status(); add a chainable shim.
function withStatusHelpers(res) {
  res.status = (code) => ({
    json: (obj) => {
      if (res.headersSent) {
        try { res.end(); } catch {}
        return res;
      }
      res.statusCode = code;
      if (!res.getHeader("Content-Type")) {
        res.setHeader("Content-Type", "application/json; charset=utf-8");
      }
      res.end(JSON.stringify(obj));
      return res;
    },
    end: () => {
      if (!res.headersSent) res.statusCode = code;
      res.end();
      return res;
    },
  });
  return res;
}

// --- static dashboard ----------------------------------------------------------
const INDEX_HTML = (() => {
  try {
    return fs.readFileSync(path.join(UPSTREAM_ROOT, "public", "index.html"));
  } catch {
    return Buffer.from(
      "<!doctype html><title>oc-proxy</title><h1>oc-proxy</h1><p>upstream dashboard file missing</p>"
    );
  }
})();

function serveDashboard(req, res) {
  corsFn(res);
  if (req.method === "OPTIONS") { res.statusCode = 200; return res.end(); }
  if (req.method !== "GET") {
    res.statusCode = 405;
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    return res.end(JSON.stringify({ error: { message: "method not allowed" } }));
  }
  res.statusCode = 200;
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(INDEX_HTML);
}

// --- router --------------------------------------------------------------------
const server = http.createServer((req, res) => {
  withStatusHelpers(res);
  const u = (req.url || "/").split("?")[0];

  try {
    if (u === "/" || u === "/index.html") return serveDashboard(req, res);
    if (u === "/api/health") return void healthHandler(req, res);
    if (u === "/v1/models") return void modelsHandler(req, res);
    if (u === "/v1/chat/completions" || u === "/api/stats") return void chatHandler(req, res);

    // 404 (JSON, CORS-friendly)
    corsFn(res);
    if (req.method === "OPTIONS") { res.statusCode = 200; return res.end(); }
    res.statusCode = 404;
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    res.end(JSON.stringify({ error: { message: `not found: ${u}` } }));
  } catch (e) {
    console.error(`[oc-proxy] handler error: ${e.message}`);
    if (!res.headersSent) {
      res.statusCode = 500;
      res.setHeader("Content-Type", "application/json; charset=utf-8");
      res.end(JSON.stringify({ error: { message: e.message } }));
    } else {
      try { res.end(); } catch {}
    }
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[oc-proxy] listening on http://${HOST}:${PORT}`);
  console.log(`[oc-proxy] dashboard  http://${HOST}:${PORT}/`);
  console.log(`[oc-proxy] health     http://${HOST}:${PORT}/api/health`);
  console.log(`[oc-proxy] models     http://${HOST}:${PORT}/v1/models`);
  console.log(`[oc-proxy] upstream   ${UPSTREAM_ROOT}`);
  console.log(
    `[oc-proxy] auth       ${process.env.GATEWAY_API_KEY ? "GATEWAY_API_KEY set" : "open (set GATEWAY_API_KEY before exposing publicly)"}`
  );
});

// HF Spaces restarts containers with SIGTERM — exit promptly.
process.on("SIGTERM", () => {
  console.log("[oc-proxy] SIGTERM — shutting down");
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
});
process.on("SIGINT", () => {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
});
