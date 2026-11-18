#!/usr/bin/env python3
import json, sys, http.server, socketserver
PORT = int(sys.argv[1])
MODELS = {"object": "list", "data": [
  {"id": "qwen3-coder", "object": "model", "owned_by": "vllm",
   "max_model_len": 131072, "max_completion_tokens": 65536,
   "supports_tool_calls": True},
  {"id": "llama-3.3-70b", "object": "model", "owned_by": "openai",
   "max_model_len": 128000, "supports_tool_calls": False},
  {"id": "text-embedding-3-large", "object": "model", "owned_by": "openai",
   "mode": "embedding", "max_model_len": 8192},
]}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/health"):
            return self._send(200, {"status": "ok"})
        if self.path.startswith("/v1/models"):
            if self.headers.get("Authorization", "") != "Bearer sk-test-contract":
                return self._send(401, {"error": {"message": "bad bearer token"}})
            return self._send(200, MODELS)
        return self._send(404, {"error": "not found"})
    def do_POST(self):
        if self.path.startswith("/v1/chat/completions"):
            return self._send(200, {"id":"chatcmpl-stub","object":"chat.completion",
                "choices":[{"index":0,"message":{"role":"assistant","content":"ok"},
                            "finish_reason":"stop"}]})
        return self._send(404, {"error": "not found"})
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
socketserver.ThreadingTCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), H) as s:
    s.serve_forever()
