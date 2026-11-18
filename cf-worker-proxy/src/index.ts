/**
 * cf-worker-proxy — Cloudflare Workers HTTP forward proxy
 *
 * Provider #10 from FREE-VPS-PROXY-GUIDE.md.
 *
 * What it does:
 *   - HTTP forward proxy at the Cloudflare edge (300+ locations)
 *   - Each request = different edge IP = automatic IP rotation
 *   - 100K requests/day free (enough for ~1000 LLM completions)
 *
 * Why special:
 *   - No credit card (unlike Oracle/GCP/AWS/Azure)
 *   - No VPS to manage (unlike sing-box)
 *   - No cold starts (unlike Koyeb/Render)
 *   - Automatic global IP rotation (unlike single VPS)
 *   - Deploys in 30 seconds
 *
 * Usage:
 *   1. Deploy: npx wrangler deploy
 *   2. URL: https://<worker-name>.<subdomain>.workers.dev
 *   3. Proxy: curl https://<worker>/proxy/https://opencode.ai/inference/v1/models
 *
 * Routes:
 *   GET  /            → health check with edge location
 *   GET  /proxy/<url> → proxy GET to target
 *   POST /proxy/<url> → proxy POST to target (forwards body)
 */

export interface Env {
  PROXY_API_KEY?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === '/' || url.pathname === '/health') {
      return new Response(JSON.stringify({
        ok: true,
        proxy: 'cf-worker-proxy',
        edge: (request as any).cf?.colo || 'unknown',
        country: (request as any).cf?.country || 'unknown',
        city: (request as any).cf?.city || 'unknown',
        timestamp: new Date().toISOString(),
      }), { headers: { 'Content-Type': 'application/json' } });
    }

    // Auth check
    if (env.PROXY_API_KEY) {
      const auth = request.headers.get('Authorization');
      if (auth !== `Bearer ${env.PROXY_API_KEY}`) {
        return new Response('Unauthorized', { status: 401 });
      }
    }

    // Proxy: /proxy/<target-url>
    if (url.pathname.startsWith('/proxy/')) {
      const targetUrl = url.pathname.replace('/proxy/', '');
      const fullTarget = targetUrl + (url.search || '');

      let parsedTarget: URL;
      try {
        parsedTarget = new URL(fullTarget);
      } catch {
        return new Response(JSON.stringify({ error: 'Invalid target URL', target: fullTarget }),
          { status: 400, headers: { 'Content-Type': 'application/json' } });
      }

      if (!['http:', 'https:'].includes(parsedTarget.protocol)) {
        return new Response(JSON.stringify({ error: 'Only http/https targets' }),
          { status: 400, headers: { 'Content-Type': 'application/json' } });
      }

      try {
        const proxyHeaders = new Headers(request.headers);
        proxyHeaders.delete('host');
        proxyHeaders.delete('connection');
        proxyHeaders.delete('proxy-connection');
        if (!proxyHeaders.has('User-Agent')) {
          proxyHeaders.set('User-Agent', 'opencode/1.19.5');
        }

        const proxyReq = new Request(fullTarget, {
          method: request.method,
          headers: proxyHeaders,
          body: request.method !== 'GET' && request.method !== 'HEAD' ? request.body : undefined,
          redirect: 'follow',
        });

        const response = await fetch(proxyReq);
        const respHeaders = new Headers(response.headers);
        respHeaders.set('X-Proxy-Edge', (request as any).cf?.colo || 'unknown');
        respHeaders.set('X-Proxy-Country', (request as any).cf?.country || 'unknown');
        respHeaders.set('X-Proxy-Target', fullTarget);
        respHeaders.set('Access-Control-Allow-Origin', '*');

        return new Response(response.body, {
          status: response.status,
          statusText: response.statusText,
          headers: respHeaders,
        });
      } catch (err) {
        return new Response(JSON.stringify({ error: 'Proxy fetch failed', target: fullTarget, message: String(err) }),
          { status: 502, headers: { 'Content-Type': 'application/json' } });
      }
    }

    return new Response(JSON.stringify({
      error: 'Not found',
      hint: 'Use /proxy/<target-url> or / for health check',
      example: `${url.origin}/proxy/https://opencode.ai/inference/v1/models`,
    }), { status: 404, headers: { 'Content-Type': 'application/json' } });
  },
};
