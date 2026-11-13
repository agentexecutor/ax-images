# mock-anthropic

Lightweight, standard-library-only fake HTTP server implementing the Anthropic
Messages API and Vertex AI Anthropic `rawPredict` routes. Designed to run
outside the agent sandbox so end-to-end tests can exercise real Claude Code
runs, egress rules, and gateway credential injection without live API keys or
model spend.

## Configuration

| Environment variable | Default | Description |
| :--- | :--- | :--- |
| `EXPECTED_KEY` | `test-key` | Credential callers must send in `x-api-key` or `Authorization: Bearer <token>`. Mismatched or missing keys return `401`. |
| `REPLY_TEXT` | `MOCK_OK` | Assistant reply text returned by `/v1/messages` and `:rawPredict` / `:streamRawPredict`. |
| `PORT` | `8080` | TCP port to listen on. |

## Supported Endpoints

- `GET /healthz` — Liveness and readiness check (`200 {"ok": true}`).
- `POST /v1/messages` — Direct Anthropic Messages API (JSON or SSE stream when `stream: true`).
- `POST .../publishers/anthropic/models/<model>:rawPredict` — Vertex AI non-streaming JSON reply.
- `POST .../publishers/anthropic/models/<model>:streamRawPredict` — Vertex AI SSE stream reply.
- `POST /v1/messages/count_tokens` (and `:countTokens`) — Token count stub (`{"input_tokens": 10}`).
- `GET /v1/models` — Model list stub.
- `GET /_mock/requests` — Recorded requests (`method`, `path`, `auth_ok`, `key_presented`, and `headers` with `x-api-key` and `authorization` redacted).
- `POST /_mock/reset` — Clears recorded requests.

## Local Smoke Test

```bash
./fakes/mock-anthropic/selftest.sh
docker build -t mock-anthropic:dev ./fakes/mock-anthropic
```
