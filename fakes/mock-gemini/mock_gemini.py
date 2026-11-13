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

"""Minimal mock of the Gemini API (generativelanguage.googleapis.com).

Used for end-to-end testing of Antigravity CLI (agy) deployments without real
API keys or model spend. Relies only on the Python standard library.

Environment variables:
  EXPECTED_KEY        Credential callers must present via x-goog-api-key,
                      ?key=, or Authorization: Bearer (default: "test-key").
  REPLY_TEXT          Canned model text reply (default: "MOCK_OK").
  PORT                TCP port to listen on (default: 8080).
  FAULT               Optional fault mode: "" | "429" | "500" | "503" | "slow" |
                      "truncated_sse".
  SLOW_DELAY          Seconds to delay in FAULT="slow" mode (default: 2.0).
  TOOL_WRITE_PATH     If non-empty, emit a write_file functionCall turn before
                      the final text reply.
  TOOL_WRITE_CONTENT  Content for the scripted write_file functionCall
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
from urllib.parse import parse_qs, urlparse

EXPECTED_KEY = os.environ.get("EXPECTED_KEY", "test-key")
REPLY_TEXT = os.environ.get("REPLY_TEXT", "MOCK_OK")
PORT = int(os.environ.get("PORT", "8080"))

VALID_FAULTS = ("", "429", "500", "503", "slow", "truncated_sse")
_DEFAULT_CONFIG = {
    "fault": os.environ.get("FAULT", ""),
    "slow_delay": float(os.environ.get("SLOW_DELAY", "2.0")),
    "tool_write_path": os.environ.get("TOOL_WRITE_PATH", ""),
    "tool_write_content": os.environ.get("TOOL_WRITE_CONTENT", "MOCK_TOOL_OK"),
}

_LOCK = threading.Lock()
_CONFIG = dict(_DEFAULT_CONFIG)
_LOG = []
_SECRET_HEADERS = ("x-goog-api-key", "authorization")


def presented_key(headers, query):
    if headers.get("x-goog-api-key"):
        return headers["x-goog-api-key"]
    if query.get("key"):
        return query["key"][0]
    auth = headers.get("authorization", "")
    return auth[7:] if auth.lower().startswith("bearer ") else None


def has_function_response(contents):
    """Returns True if any turn in contents carries a functionResponse."""
    for content in contents or []:
        for part in content.get("parts") or []:
            if isinstance(part, dict) and "functionResponse" in part:
                return True
    return False


def declared_write_tool(body):
    """Returns 'write_file' if declared in tools (or when tools is omitted)."""
    tools = body.get("tools")
    if not tools:
        return "write_file"
    for tool in tools:
        for decl in tool.get("functionDeclarations") or []:
            if decl.get("name") == "write_file":
                return "write_file"
    return None


def usage():
    return {
        "promptTokenCount": 1,
        "candidatesTokenCount": 1,
        "totalTokenCount": 2,
    }


def text_response(model):
    return {
        "candidates": [
            {
                "content": {"role": "model", "parts": [{"text": REPLY_TEXT}]},
                "finishReason": "STOP",
                "index": 0,
            }
        ],
        "usageMetadata": usage(),
        "modelVersion": model,
        "responseId": "mock-response",
    }


def tool_response(model, tool_name, cfg):
    args = {
        "Path": cfg["tool_write_path"],
        "Content": cfg["tool_write_content"],
        "Overwrite": True,
    }
    return {
        "candidates": [
            {
                "content": {
                    "role": "model",
                    "parts": [{"functionCall": {"name": tool_name, "args": args}}],
                },
                "finishReason": "STOP",
                "index": 0,
            }
        ],
        "usageMetadata": usage(),
        "modelVersion": model,
        "responseId": "mock-response-tool",
    }


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

    def _sse(self, chunks, delay=0.0, truncate=False):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        if truncate:
            self.wfile.write(b'data: {"candidates": [{"content": {"role": "mo')
            self.wfile.flush()
            self.close_connection = True
            return
        per_chunk = delay / max(len(chunks), 1) if delay > 0 else 0.0
        for chunk in chunks:
            if per_chunk > 0:
                time.sleep(per_chunk)
            self.wfile.write(f"data: {json.dumps(chunk)}\r\n\r\n".encode("utf-8"))
            self.wfile.flush()
        self.close_connection = True

    def _error(self, code, status, message, extra_headers=None):
        self._json(
            code,
            {"error": {"code": code, "message": message, "status": status}},
            extra_headers,
        )

    def _handle_http_fault(self, fault):
        if fault == "429":
            self._error(
                429,
                "RESOURCE_EXHAUSTED",
                "mock rate limit",
                extra_headers={"retry-after": "1"},
            )
            return True
        if fault == "500":
            self._error(500, "INTERNAL", "mock internal error")
            return True
        if fault == "503":
            self._error(503, "UNAVAILABLE", "mock service unavailable")
            return True
        return False

    def _record(self, ok, key, url):
        clean_path = url.path
        if url.query:
            filtered = [
                part
                for part in url.query.split("&")
                if not part.startswith("key=")
            ]
            if filtered:
                clean_path = f"{url.path}?{'&'.join(filtered)}"
        entry = {
            "method": self.command,
            "path": clean_path,
            "auth_ok": ok,
            "headers": {
                k.lower(): v
                for k, v in self.headers.items()
                if k.lower() not in _SECRET_HEADERS
            },
            "key_presented": key is not None,
        }
        with _LOCK:
            _LOG.append(entry)

    def _authorize(self, url):
        key = presented_key(self.headers, parse_qs(url.query))
        ok = key == EXPECTED_KEY
        self._record(ok, key, url)
        if not ok:
            self._error(
                401 if key is None else 400,
                "UNAUTHENTICATED" if key is None else "INVALID_ARGUMENT",
                "API key not valid. Please pass a valid API key.",
            )
        return ok

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/_mock/requests":
            with _LOCK:
                snapshot = list(_LOG)
            return self._json(200, snapshot)
        if url.path in ("/healthz", "/"):
            return self._json(200, {"ok": True})
        if not self._authorize(url):
            return
        if "/models" in url.path:
            return self._json(
                200,
                {
                    "models": [
                        {
                            "name": "models/gemini-mock",
                            "displayName": "Mock",
                            "supportedGenerationMethods": [
                                "generateContent",
                                "streamGenerateContent",
                                "countTokens",
                            ],
                        }
                    ]
                },
            )
        self._error(404, "NOT_FOUND", url.path)

    def do_POST(self):
        url = urlparse(self.path)
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if url.path == "/_mock/reset":
            with _LOCK:
                _LOG.clear()
                _CONFIG.clear()
                _CONFIG.update(_DEFAULT_CONFIG)
            return self._json(200, {"ok": True})

        if url.path == "/_mock/config":
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

        if not self._authorize(url):
            return
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}

        model, _, method = url.path.rsplit("/", 1)[-1].partition(":")
        if method == "countTokens":
            return self._json(200, {"totalTokens": 10})
        if method not in ("generateContent", "streamGenerateContent"):
            return self._error(404, "NOT_FOUND", url.path)

        with _LOCK:
            cfg = dict(_CONFIG)

        fault = cfg["fault"]
        if self._handle_http_fault(fault):
            return

        delay = cfg["slow_delay"] if fault == "slow" else 0.0
        tool_name = None
        if cfg["tool_write_path"] and not has_function_response(body.get("contents")):
            tool_name = declared_write_tool(body)

        resp = (
            tool_response(model, tool_name, cfg)
            if tool_name
            else text_response(model)
        )
        if method == "streamGenerateContent":
            return self._sse([resp], delay=delay, truncate=fault == "truncated_sse")
        if delay > 0:
            time.sleep(delay)
        self._json(200, resp)


if __name__ == "__main__":
    print(
        f"mock gemini on :{PORT}, expecting key {EXPECTED_KEY[:4]}…",
        flush=True,
    )
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
