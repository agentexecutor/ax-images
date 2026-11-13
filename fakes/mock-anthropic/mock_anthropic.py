#!/usr/bin/env python3

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Minimal fake of the Anthropic Messages API and Vertex AI rawPredict routes.

Used for end-to-end testing of Claude Code deployments without real API keys or
model spend. Relies only on the Python standard library.

Environment variables:
  EXPECTED_KEY  Credential callers must present via x-api-key or Bearer token
                (default: "test-key").
  REPLY_TEXT    Canned assistant text reply (default: "MOCK_OK").
  PORT          TCP port to listen on (default: 8080).

Inspection endpoints:
  GET  /healthz         Liveness/readiness probe.
  GET  /_mock/requests  JSON list of recorded requests (auth headers redacted).
  POST /_mock/reset     Clears recorded requests.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import threading

EXPECTED_KEY = os.environ.get("EXPECTED_KEY", "test-key")
REPLY_TEXT = os.environ.get("REPLY_TEXT", "MOCK_OK")
PORT = int(os.environ.get("PORT", "8080"))

_LOCK = threading.Lock()
_LOG = []


def presented_key(headers):
    """Extracts the API credential from x-api-key or Authorization: Bearer."""
    if headers.get("x-api-key"):
        return headers["x-api-key"]
    auth = headers.get("authorization", "")
    return auth[7:] if auth.lower().startswith("bearer ") else None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, code, obj, extra_headers=None):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _sse_events(self, events):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        for name, data in events:
            payload = f"event: {name}\ndata: {json.dumps(data)}\n\n".encode("utf-8")
            self.wfile.write(payload)
            self.wfile.flush()
        self.close_connection = True

    def _text_events(self, model):
        return [
            (
                "message_start",
                {
                    "type": "message_start",
                    "message": {
                        "id": "msg_mock",
                        "type": "message",
                        "role": "assistant",
                        "model": model,
                        "content": [],
                        "stop_reason": None,
                        "stop_sequence": None,
                        "usage": {"input_tokens": 1, "output_tokens": 1},
                    },
                },
            ),
            (
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
            ),
            (
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": REPLY_TEXT},
                },
            ),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            (
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": 2},
                },
            ),
            ("message_stop", {"type": "message_stop"}),
        ]

    def _record(self, ok):
        entry = {
            "method": self.command,
            "path": self.path,
            "auth_ok": ok,
            "headers": {
                k.lower(): v
                for k, v in self.headers.items()
                if k.lower() not in ("x-api-key", "authorization")
            },
            "key_presented": presented_key(self.headers) is not None,
        }
        with _LOCK:
            _LOG.append(entry)

    def _auth_error(self):
        self._json(
            401,
            {
                "type": "error",
                "error": {
                    "type": "authentication_error",
                    "message": "invalid x-api-key",
                },
            },
        )

    def do_GET(self):
        if self.path == "/_mock/requests":
            with _LOCK:
                snapshot = list(_LOG)
            return self._json(200, snapshot)
        if self.path in ("/healthz", "/"):
            return self._json(200, {"ok": True})

        ok = presented_key(self.headers) == EXPECTED_KEY
        self._record(ok)
        if not ok:
            return self._auth_error()

        if self.path.startswith("/v1/models"):
            return self._json(
                200,
                {
                    "data": [
                        {"id": "claude-mock", "type": "model", "display_name": "Mock"}
                    ],
                    "has_more": False,
                },
            )
        self._json(
            404,
            {
                "type": "error",
                "error": {"type": "not_found_error", "message": self.path},
            },
        )

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b"{}"

        if self.path == "/_mock/reset":
            with _LOCK:
                _LOG.clear()
            return self._json(200, {"ok": True})

        ok = presented_key(self.headers) == EXPECTED_KEY
        self._record(ok)
        if not ok:
            return self._auth_error()

        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}

        path = self.path.split("?")[0]
        model = body.get("model", "claude-mock")

        if path.endswith("/count_tokens") or path.endswith(":countTokens"):
            return self._json(200, {"input_tokens": 10})

        is_vertex = ":rawPredict" in path or ":streamRawPredict" in path
        if path.startswith("/v1/messages") or is_vertex:
            if body.get("stream") or path.endswith(":streamRawPredict"):
                return self._sse_events(self._text_events(model))
            return self._json(
                200,
                {
                    "id": "msg_mock",
                    "type": "message",
                    "role": "assistant",
                    "model": model,
                    "content": [{"type": "text", "text": REPLY_TEXT}],
                    "stop_reason": "end_turn",
                    "stop_sequence": None,
                    "usage": {"input_tokens": 1, "output_tokens": 2},
                },
            )

        self._json(
            404,
            {
                "type": "error",
                "error": {"type": "not_found_error", "message": path},
            },
        )


if __name__ == "__main__":
    print(
        f"mock anthropic on :{PORT}, expecting key {EXPECTED_KEY[:4]}...",
        flush=True,
    )
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
