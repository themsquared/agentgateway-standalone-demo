#!/usr/bin/env python3
"""
A deliberately small OpenAI-compatible upstream.

Why this exists: the demo should run on a laptop or in an air-gapped sandbox
with no cloud credentials, so a reviewer can try it on day one rather than
after a procurement conversation. This stands in for a provider; the same
config swaps to a real one by changing the backend host.

It also makes the failover scene deterministic. Evicting a real provider
endpoint live is not something to depend on in front of an audience.

Endpoints:
  POST /v1/chat/completions   OpenAI-shaped completion, with real-ish usage counts
  GET  /health                liveness
  POST /control/fail          start returning 503 (arms the failover scene)
  POST /control/heal          stop returning 503
"""
import json
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME = os.environ.get("UPSTREAM_NAME", "mock")
PORT = int(os.environ.get("PORT", "8080"))
LATENCY_MS = int(os.environ.get("LATENCY_MS", "40"))

_state = {"failing": os.environ.get("START_FAILING", "false").lower() == "true"}
_lock = threading.Lock()


def _tokens(text: str) -> int:
    # Good enough for a demo: ~4 characters per token, floored at 1.
    return max(1, len(text) // 4)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter compose logs
        pass

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            with _lock:
                failing = _state["failing"]
            self._json(503 if failing else 200, {"upstream": NAME, "failing": failing})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"

        if self.path == "/control/fail":
            with _lock:
                _state["failing"] = True
            self._json(200, {"upstream": NAME, "failing": True})
            return
        if self.path == "/control/heal":
            with _lock:
                _state["failing"] = False
            self._json(200, {"upstream": NAME, "failing": False})
            return

        if not self.path.endswith("/chat/completions"):
            self._json(404, {"error": "not found"})
            return

        with _lock:
            if _state["failing"]:
                self._json(503, {"error": {"message": f"{NAME} upstream unavailable",
                                           "type": "server_error"}})
                return

        try:
            req = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"error": {"message": "invalid JSON"}})
            return

        messages = req.get("messages") or []
        prompt = " ".join(str(m.get("content", "")) for m in messages)
        model = req.get("model") or "mock-model"

        time.sleep(LATENCY_MS / 1000.0)

        reply = (f"[{NAME}] Acknowledged {len(messages)} message(s). "
                 f"This response came from the {NAME} upstream.")
        prompt_tokens = _tokens(prompt)
        completion_tokens = _tokens(reply) + random.randint(0, 12)

        self._json(200, {
            "id": f"chatcmpl-{NAME}-{int(time.time()*1000)}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "system_fingerprint": f"fp_{NAME}",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": reply},
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
            },
        })


if __name__ == "__main__":
    print(f"mock provider '{NAME}' listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
