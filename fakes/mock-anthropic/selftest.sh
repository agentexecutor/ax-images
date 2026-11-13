#!/usr/bin/env bash

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

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-18080}"
EXPECTED_KEY="${EXPECTED_KEY:-throwaway-test-key}"
BASE="http://127.0.0.1:${PORT}"
LOG_FILE="$(mktemp)"

PORT="${PORT}" EXPECTED_KEY="${EXPECTED_KEY}" REPLY_TEXT="MOCK_OK" \
  python3 "${DIR}/mock_anthropic.py" >"${LOG_FILE}" 2>&1 &
SERVER_PID=$!
trap 'kill "${SERVER_PID}" 2>/dev/null || true; rm -f "${LOG_FILE}"' EXIT

for _ in $(seq 1 30); do
  if curl -fsS "${BASE}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

curl -fsS "${BASE}/healthz" >/dev/null

# 1. Wrong key -> 401
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/v1/messages" \
  -H "x-api-key: wrong" -H "content-type: application/json" \
  -d '{"model":"claude-mock","messages":[{"role":"user","content":"hi"}]}')
test "${code}" = "401"

# 2. Missing key -> 401
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/v1/messages" \
  -H "content-type: application/json" \
  -d '{"model":"claude-mock","messages":[{"role":"user","content":"hi"}]}')
test "${code}" = "401"

# 3. Direct Anthropic SSE stream -> 200 + MOCK_OK
sse=$(curl -fsS -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" \
  -d '{"model":"claude-mock","stream":true,"messages":[{"role":"user","content":"hi"}]}')
python3 - "${sse}" << 'EOF'
import sys
data = sys.argv[1]
assert "event: message_start" in data
assert "MOCK_OK" in data
assert "event: message_stop" in data
EOF

# 4. Direct Anthropic non-stream JSON -> 200 + MOCK_OK
resp=$(curl -fsS -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" \
  -d '{"model":"claude-mock","stream":false,"messages":[{"role":"user","content":"hi"}]}')
python3 - "${resp}" << 'EOF'
import json, sys
d = json.load(sys.stdin) if len(sys.argv) < 2 else json.loads(sys.argv[1])
assert d["content"][0]["text"] == "MOCK_OK"
EOF

# 5. Vertex streamRawPredict & rawPredict with Bearer token -> 200 + MOCK_OK
vsse=$(curl -fsS -X POST "${BASE}/v1/projects/p/locations/global/publishers/anthropic/models/claude-mock:streamRawPredict" \
  -H "authorization: Bearer ${EXPECTED_KEY}" -H "content-type: application/json" \
  -d '{"messages":[{"role":"user","content":"hi"}]}')
python3 - "${vsse}" << 'EOF'
import sys
data = sys.argv[1]
assert "MOCK_OK" in data
assert "event: message_stop" in data
EOF

vjson=$(curl -fsS -X POST "${BASE}/v1/projects/p/locations/global/publishers/anthropic/models/claude-mock:rawPredict" \
  -H "authorization: Bearer ${EXPECTED_KEY}" -H "content-type: application/json" \
  -d '{"messages":[{"role":"user","content":"hi"}]}')
python3 - "${vjson}" << 'EOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["content"][0]["text"] == "MOCK_OK"
EOF

# 6. count_tokens and /v1/models
tok=$(curl -fsS -X POST "${BASE}/v1/messages/count_tokens" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" -d '{}')
python3 - "${tok}" << 'EOF'
import json, sys
assert json.loads(sys.argv[1])["input_tokens"] == 10
EOF

mods=$(curl -fsS "${BASE}/v1/models" -H "x-api-key: ${EXPECTED_KEY}")
python3 - "${mods}" << 'EOF'
import json, sys
assert json.loads(sys.argv[1])["data"][0]["id"] == "claude-mock"
EOF

# 7. Request log assertions (8 requests logged, auth headers redacted)
reqs=$(curl -fsS "${BASE}/_mock/requests")
python3 - "${reqs}" << 'EOF'
import json, sys
log = json.loads(sys.argv[1])
assert len(log) == 8, f"expected 8, got {len(log)}"
assert [r["auth_ok"] for r in log] == [False, False, True, True, True, True, True, True]
assert [r["key_presented"] for r in log] == [True, False, True, True, True, True, True, True]
for r in log:
    assert "x-api-key" not in r["headers"]
    assert "authorization" not in r["headers"]
EOF

# 8. Reset clears request log
curl -fsS -X POST "${BASE}/_mock/reset" >/dev/null
after=$(curl -fsS "${BASE}/_mock/requests")
test "${after}" = "[]"

echo "ALL SELFTEST CHECKS PASSED"
