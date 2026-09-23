#!/usr/bin/env python3
"""
A minimal MCP server over streamable HTTP, with demo tools.

Two instances run in this demo, and the point of two is federation: agentgateway
multiplexes them behind one endpoint, prefixes the tool names, and becomes the
single governed door in front of whatever an agent can reach.

The tool sets are chosen for the story, not for realism of implementation:

  records        lookup_record        returns a record containing synthetic PII,
                                      so a guardrail scoped to toolOutput has
                                      something real to catch
                 search_orders        benign, stays allowed
                 export_record_table  the tool worth denying on stage

  platform-ops   get_service_health   benign
                 get_deploy_status    benign
                 restart_service      disruptive, gated by policy not by trust

Implements: initialize, notifications/initialized, tools/list, tools/call.
Responds as SSE when the client asks for text/event-stream, otherwise as JSON.

All data returned is invented. No real person or record is represented.
"""
import json
import os
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVER = os.environ.get("MCP_SERVER", "records")
PORT = int(os.environ.get("PORT", "9000"))
PROTOCOL = "2025-03-26"

TOOLSETS = {
    "records": [
        {
            "name": "lookup_record",
            "description": "Look up a customer record by id.",
            "inputSchema": {
                "type": "object",
                "properties": {"record_id": {"type": "string", "description": "Record id"}},
                "required": ["record_id"],
            },
        },
        {
            "name": "search_orders",
            "description": "Search recent orders by free text. Returns aggregate counts only.",
            "inputSchema": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "Search text"}},
                "required": ["query"],
            },
        },
        {
            "name": "export_record_table",
            "description": "Export a full customer table as CSV. Bulk data egress.",
            "inputSchema": {
                "type": "object",
                "properties": {"table": {"type": "string", "description": "Table name"}},
                "required": ["table"],
            },
        },
    ],
    "platform-ops": [
        {
            "name": "get_service_health",
            "description": "Return the health of a platform service.",
            "inputSchema": {
                "type": "object",
                "properties": {"service": {"type": "string"}},
                "required": ["service"],
            },
        },
        {
            "name": "get_deploy_status",
            "description": "Return the current deployment status for an environment.",
            "inputSchema": {
                "type": "object",
                "properties": {"environment": {"type": "string"}},
                "required": ["environment"],
            },
        },
        {
            "name": "restart_service",
            "description": "Restart a platform service. Disruptive.",
            "inputSchema": {
                "type": "object",
                "properties": {"service": {"type": "string"}},
                "required": ["service"],
            },
        },
    ],
}


def call_tool(name, args):
    if name == "lookup_record":
        rid = args.get("record_id", "ACCT-000000")
        # Deliberately contains synthetic PII. A request guard with
        # scope [messages, toolOutput] catches this on the way back to the model.
        return (f"record_id={rid} name=Jane Doe "
                f"email=jane.doe@example.com phone=555-0142 "
                f"tier=standard status=active")
    if name == "search_orders":
        q = args.get("query", "")
        return f"query={q!r} matched 42 orders across 3 categories. No customer detail returned."
    if name == "export_record_table":
        t = args.get("table", "customers")
        return f"exported table={t} rows=1084221 format=csv"
    if name == "get_service_health":
        s = args.get("service", "unknown")
        return f"service={s} status=healthy p99_ms=184 error_rate=0.02%"
    if name == "get_deploy_status":
        e = args.get("environment", "unknown")
        return f"environment={e} version=2026.9.3 state=stable last_deploy=2026-09-17T22:14Z"
    if name == "restart_service":
        s = args.get("service", "unknown")
        return f"service={s} restart issued"
    return f"unknown tool {name}"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, payload, session_id=None, code=200):
        wants_sse = "text/event-stream" in (self.headers.get("Accept") or "")
        if wants_sse:
            body = ("data: " + json.dumps(payload) + "\n\n").encode()
            ctype = "text/event-stream"
        else:
            body = json.dumps(payload).encode()
            ctype = "application/json"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if session_id:
            self.send_header("Mcp-Session-Id", session_id)
        self.end_headers()
        self.wfile.write(body)

    def _empty(self, code=202, session_id=None):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        if session_id:
            self.send_header("Mcp-Session-Id", session_id)
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({"server": SERVER, "ok": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self._empty(405)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._empty(400)
            return

        method = req.get("method")
        rid = req.get("id")
        session_id = self.headers.get("Mcp-Session-Id")

        if method == "initialize":
            session_id = session_id or str(uuid.uuid4())
            self._send({
                "jsonrpc": "2.0", "id": rid,
                "result": {
                    "protocolVersion": PROTOCOL,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": SERVER, "version": "1.0.0"},
                },
            }, session_id=session_id)
            return

        if method == "notifications/initialized":
            self._empty(202, session_id=session_id)
            return

        if method == "tools/list":
            self._send({"jsonrpc": "2.0", "id": rid,
                        "result": {"tools": TOOLSETS[SERVER]}}, session_id=session_id)
            return

        if method == "tools/call":
            params = req.get("params") or {}
            name = params.get("name", "")
            args = params.get("arguments") or {}
            text = call_tool(name, args)
            self._send({"jsonrpc": "2.0", "id": rid,
                        "result": {"content": [{"type": "text", "text": text}],
                                   "isError": False}}, session_id=session_id)
            return

        self._send({"jsonrpc": "2.0", "id": rid,
                    "error": {"code": -32601, "message": f"method not found: {method}"}},
                   session_id=session_id)


if __name__ == "__main__":
    print(f"mcp server '{SERVER}' listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
