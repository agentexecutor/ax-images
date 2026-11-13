# mock-gemini

Lightweight, standard-library-only fake HTTP server implementing the Gemini API
(`generativelanguage.googleapis.com`). Designed to run outside the agent sandbox
so end-to-end tests can exercise real Antigravity CLI (`agy`) runs, tool
execution, retry handling, egress rules, and gateway credential injection
without live API keys or model spend.

## Configuration

| Environment variable | Default | Description |
| :--- | :--- | :--- |
| `EXPECTED_KEY` | `test-key` | Credential callers must send in `x-goog-api-key`, `?key=`, or `Authorization: Bearer <token>`. Missing keys return `401`; mismatched keys return `400`. |
| `REPLY_TEXT` | `MOCK_OK` | Model reply text returned by `:generateContent` and `:streamGenerateContent`. |
| `PORT` | `8080` | TCP port to listen on. |
| `FAULT` | `""` | Optional fault mode: `429` (rate limit with `Retry-After: 1`), `500` (internal error), `503` (service unavailable), `slow` (delayed response/SSE), or `truncated_sse` (drops stream mid-JSON). |
| `SLOW_DELAY` | `2.0` | Total delay in seconds when `FAULT=slow`. |
| `TOOL_WRITE_PATH` | `""` | When set, turn 1 returns a `write_file` `functionCall` writing `TOOL_WRITE_CONTENT` to this path; turn 2 (with `functionResponse`) returns `REPLY_TEXT`. |
| `TOOL_WRITE_CONTENT` | `MOCK_TOOL_OK` | File content used by `TOOL_WRITE_PATH`. |

## Supported Endpoints

- `GET /healthz` — Liveness and readiness check (`200 {"ok": true}`).
- `POST /v1beta/models/<model>:streamGenerateContent?alt=sse` — Gemini SSE stream reply.
- `POST /v1beta/models/<model>:generateContent` — Non-streaming JSON reply.
- `POST /v1beta/models/<model>:countTokens` — Token count stub (`{"totalTokens": 10}`).
- `GET /v1beta/models` — Model list stub.
- `GET /_mock/requests` — Recorded requests (`method`, `path`, `auth_ok`, `key_presented`, and `headers` with `x-goog-api-key`, `authorization`, and `?key=` redacted).
- `POST /_mock/config` — Runtime JSON override for `fault`, `slow_delay`, `tool_write_path`, and `tool_write_content` (no container restart needed).
- `POST /_mock/reset` — Clears recorded requests and resets runtime overrides back to startup environment defaults.

## Local Smoke Test

```bash
./fakes/mock-gemini/selftest.sh
docker build -t mock-gemini:dev ./fakes/mock-gemini
```
