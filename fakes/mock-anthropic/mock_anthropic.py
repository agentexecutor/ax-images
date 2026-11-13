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
  EXPECTED_KEY        Credential callers must present via x-api-key or Bearer
                      token (default: "test-key").
  REPLY_TEXT          Canned assistant text reply (default: "MOCK_OK").
  PORT                TCP port to listen on (default: 8080).
  FAULT               Optional fault mode: "" | "429" | "500" | "slow" |
                      "truncated_sse".
  SLOW_DELAY          Seconds to delay in FAULT="slow" mode (default: 2.0).
  TOOL_WRITE_PATH     If non-empty, emit a Write tool_use turn before the final
                      text reply.
  TOOL_WRITE_CONTENT  Content for the scripted Write tool_use
                      (default: "MOCK_TOOL_OK").

Inspection & control endpoints:
  GET  /healthz         Liveness/readiness probe.
  GET  /_mock/requests  JSON list of recorded requests (auth headers redacted).
  POST /_mock/config    Overrides fault/tool settings at runtime without restart.
  POST /_mock/reset     Clears recorded requests and restores startup config.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import threading
import time

EXPECTED_KEY = os.environ.get("EXPECTED_KEY", "test-key")
REPLY_TEXT = os.environ.get("REPLY_TEXT", "MOCK_OK")
PORT = int(os.environ.get("PORT", "8080"))

VALID_FAULTS = ("", "429", "500", "slow", "truncated_sse")
_DEFAULT_CONFIG = {
    "fault": os.environ.get("FAULT", ""),
    "slow_delay": float(os.environ.get("SLOW_DELAY", "2.0")),
    "tool_write_path": os.environ.get("TOOL_WRITE_PATH", ""),
    "tool_write_content": os.environ.get("TOOL_WRITE_CONTENT", "MOCK_TOOL_OK"),
}

_LOCK = threading.Lock()
_CONFIG = dict(_DEFAULT_CONFIG)
_LOG = []


def presented_key(headers):
    """Extracts the API credential from x-api-key or Authorization: Bearer."""
    if headers.get("x-api-key"):
        return headers["x-api-key"]
    auth = headers.get("authorization", "")
    return auth[7:] if auth.lower().startswith("bearer ") else None


def has_tool_result(messages):
    """Returns True if any message in the conversation carries a tool_result."""
    for msg in messages or []:
        content = msg.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    return True
    return False


def should_emit_tool_use(body, cfg):
    """Returns True on turn 1 when scripted Write tool_use is enabled."""
    if not cfg["tool_write_path"]:
        return False
    if has_tool_result(body.get("messages")):
        return False
    tools = body.get("tools")
    if isinstance(tools, list):
        return any(isinstance(t, dict) and t.get("name") == "Write" for t in tools)
    return True


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

    def _sse_events(self, events, delay=0.0, truncate=False):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        limit = 2 if truncate else len(events)
        per_event = delay / max(limit, 1) if delay > 0 else 0.0
        for name, data in events[:limit]:
            if per_event > 0:
                time.sleep(per_event)
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

    def _tool_events(self, model, cfg):
        tool_input = json.dumps(
            {
                "file_path": cfg["tool_write_path"],
                "content": cfg["tool_write_content"],
            }
        )
        return [
            (
                "message_start",
                {
                    "type": "message_start",
                    "message": {
                        "id": "msg_mock_tool",
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
                    "content_block": {
                        "type": "tool_use",
                        "id": "toolu_mock_01",
                        "name": "Write",
                        "input": {},
                    },
                },
            ),
            (
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "input_json_delta", "partial_json": tool_input},
                },
            ),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            (
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                    "usage": {"output_tokens": 10},
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

    def _handle_http_fault(self, fault):
        if fault == "429":
            self._json(
                429,
                {
                    "type": "error",
                    "error": {
                        "type": "rate_limit_error",
                        "message": "mock rate limit",
                    },
                },
                extra_headers={"retry-after": "1"},
            )
            return True
        if fault == "500":
            self._json(
                500,
                {
                    "type": "error",
                    "error": {
                        "type": "api_error",
                        "message": "mock internal error",
                    },
                },
            )
            return True
        return False

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
                _CONFIG.clear()
                _CONFIG.update(_DEFAULT_CONFIG)
            return self._json(200, {"ok": True})

        if self.path == "/_mock/config":
            try:
                patch = json.loads(raw or b"{}")
            except ValueError:
                return self._json(400, {"error": "invalid json"})
            if not isinstance(patch, dict):
                return self._json(400, {"error": "expected json object"})
            unknown = set(patch) - set(_DEFAULT_CONFIG)
            if unknown:
                return self._json(400, {"error": f"unknown keys: {sorted(unknown)}"})
            if "fault" in patch and patch["fault"] not in VALID_FAULTS:
                return self._json(400, {"error": f"invalid fault: {patch['fault']!r}"})
            with _LOCK:
                for key, val in patch.items():
                    _CONFIG[key] = float(val) if key == "slow_delay" else val
                snapshot = dict(_CONFIG)
            return self._json(200, snapshot)

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
            with _LOCK:
                cfg = dict(_CONFIG)

            fault = cfg["fault"]
            if self._handle_http_fault(fault):
                return

            use_tool = should_emit_tool_use(body, cfg)
            delay = cfg["slow_delay"] if fault == "slow" else 0.0
            truncate = fault == "truncated_sse"

            if body.get("stream") or path.endswith(":streamRawPredict") or truncate:
                events = (
                    self._tool_events(model, cfg)
                    if use_tool
                    else self._text_events(model)
                )
                return self._sse_events(events, delay=delay, truncate=truncate)

            if delay > 0:
                time.sleep(delay)

            if use_tool:
                return self._json(
                    200,
                    {
                        "id": "msg_mock_tool",
                        "type": "message",
                        "role": "assistant",
                        "model": model,
                        "content": [
                            {
                                "type": "tool_use",
                                "id": "toolu_mock_01",
                                "name": "Write",
                                "input": {
                                    "file_path": cfg["tool_write_path"],
                                    "content": cfg["tool_write_content"],
                                },
                            }
                        ],
                        "stop_reason": "tool_use",
                        "stop_sequence": None,
                        "usage": {"input_tokens": 1, "output_tokens": 10},
                    },
                )

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
