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
  EXPECTED_KEY  Credential callers must present via x-goog-api-key, ?key=, or
                Authorization: Bearer (default: "test-key").
  REPLY_TEXT    Canned model text reply (default: "MOCK_OK").
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
from urllib.parse import parse_qs, urlparse

EXPECTED_KEY = os.environ.get("EXPECTED_KEY", "test-key")
REPLY_TEXT = os.environ.get("REPLY_TEXT", "MOCK_OK")
PORT = int(os.environ.get("PORT", "8080"))

_LOCK = threading.Lock()
_LOG = []
_SECRET_HEADERS = ("x-goog-api-key", "authorization")


def presented_key(headers, query):
    if headers.get("x-goog-api-key"):
        return headers["x-goog-api-key"]
    if query.get("key"):
        return query["key"][0]
    auth = headers.get("authorization", "")
    return auth[7:] if auth.lower().startswith("bearer ") else None


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

    def _sse(self, chunks):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(f"data: {json.dumps(chunk)}\r\n\r\n".encode("utf-8"))
            self.wfile.flush()
        self.close_connection = True

    def _error(self, code, status, message, extra_headers=None):
        self._json(
            code,
            {"error": {"code": code, "message": message, "status": status}},
            extra_headers,
        )

    def _record(self, ok, key, url):
        # Strip ?key= from recorded paths so secrets never land in logs.
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
        if length:
             _ = self.rfile.read(length)
        if url.path == "/_mock/reset":
            with _LOCK:
                _LOG.clear()
            return self._json(200, {"ok": True})
        if not self._authorize(url):
            return

        model, _, method = url.path.rsplit("/", 1)[-1].partition(":")
        if method == "countTokens":
            return self._json(200, {"totalTokens": 10})
        if method == "streamGenerateContent":
            return self._sse([text_response(model)])
        if method == "generateContent":
            return self._json(200, text_response(model))
        self._error(404, "NOT_FOUND", url.path)


if __name__ == "__main__":
    print(
        f"mock gemini on :{PORT}, expecting key {EXPECTED_KEY[:4]}…",
        flush=True,
    )
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
