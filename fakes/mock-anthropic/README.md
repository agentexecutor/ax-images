# mock-anthropic

Lightweight, standard-library-only fake HTTP server implementing the Anthropic
Messages API and Vertex AI Anthropic `rawPredict` routes. Designed to run
outside the agent sandbox so end-to-end tests can exercise real Claude Code
runs, tool execution, retry handling, egress rules, and gateway credential
injection without live API keys or model spend.

## Configuration

| Environment variable | Default | Description |
| :--- | :--- | :--- |
| `EXPECTED_KEY` | `test-key` | Credential callers must send in `x-api-key` or `Authorization: Bearer <token>`. Mismatched or missing keys return `401`. |
| `REPLY_TEXT` | `MOCK_OK` | Assistant reply text returned by `/v1/messages` and `:rawPredict` / `:streamRawPredict`. |
| `PORT` | `8080` | TCP port to listen on. |
| `FAULT` | `""` | Optional fault mode: `429` (rate limit with `Retry-After: 1`), `500` (server error), `slow` (delayed response/SSE), or `truncated_sse` (drops stream before `message_stop`). |
| `SLOW_DELAY` | `2.0` | Total delay in seconds when `FAULT=slow`. |
| `TOOL_WRITE_PATH` | `""` | When set, turn 1 returns a `Write` `tool_use` call writing `TOOL_WRITE_CONTENT` to this path; turn 2 (with `tool_result`) returns `REPLY_TEXT`. |
| `TOOL_WRITE_CONTENT` | `MOCK_TOOL_OK` | File content used by `TOOL_WRITE_PATH`. |

## Supported Endpoints

- `GET /healthz` — Liveness and readiness check (`200 {"ok": true}`).
- `POST /v1/messages` — Direct Anthropic Messages API (JSON or SSE stream when `stream: true`).
- `POST .../publishers/anthropic/models/<model>:rawPredict` — Vertex AI non-streaming JSON reply.
- `POST .../publishers/anthropic/models/<model>:streamRawPredict` — Vertex AI SSE stream reply.
- `POST /v1/messages/count_tokens` (and `:countTokens`) — Token count stub (`{"input_tokens": 10}`).
- `GET /v1/models` — Model list stub.
- `GET /_mock/requests` — Recorded requests (`method`, `path`, `auth_ok`, `key_presented`, and `headers` with `x-api-key` and `authorization` redacted).
- `POST /_mock/config` — Runtime JSON override for `fault`, `slow_delay`, `tool_write_path`, and `tool_write_content` (no container restart needed).
- `POST /_mock/reset` — Clears recorded requests and resets runtime overrides back to startup environment defaults.

## Local Smoke Test

```bash
./fakes/mock-anthropic/selftest.sh
docker build -t mock-anthropic:dev ./fakes/mock-anthropic
```
