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
d = json.loads(sys.argv[1])
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

# 8. Config validation & FAULT modes (429, 500, slow, truncated_sse)
bad_cfg=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/_mock/config" \
  -H "content-type: application/json" -d '{"fault":"unknown"}')
test "${bad_cfg}" = "400"

curl -fsS -X POST "${BASE}/_mock/config" -H "content-type: application/json" -d '{"fault":"429"}' >/dev/null
headers_429="$(mktemp)"
code=$(curl -s -D "${headers_429}" -o /dev/null -w "%{http_code}" -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" -d '{"messages":[{"role":"user","content":"hi"}]}')
test "${code}" = "429"
python3 - "${headers_429}" << 'EOF'
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    raw = f.read().lower()
assert "retry-after: 1" in raw, raw
EOF
rm -f "${headers_429}"

curl -fsS -X POST "${BASE}/_mock/config" -H "content-type: application/json" -d '{"fault":"500"}' >/dev/null
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" -d '{"messages":[{"role":"user","content":"hi"}]}')
test "${code}" = "500"

curl -fsS -X POST "${BASE}/_mock/config" -H "content-type: application/json" -d '{"fault":"slow","slow_delay":0.15}' >/dev/null
slow_resp=$(curl -fsS -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" -d '{"messages":[{"role":"user","content":"hi"}]}')
python3 - "${slow_resp}" << 'EOF'
import json, sys
assert json.loads(sys.argv[1])["content"][0]["text"] == "MOCK_OK"
EOF

curl -fsS -X POST "${BASE}/_mock/config" -H "content-type: application/json" -d '{"fault":"truncated_sse"}' >/dev/null
trunc=$(curl -s -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" -d '{"stream":true,"messages":[{"role":"user","content":"hi"}]}')
python3 - "${trunc}" << 'EOF'
import sys
d = sys.argv[1]
assert "event: message_start" in d
assert "event: message_stop" not in d
EOF

# 9. Scripted Write tool_use (turn 1 -> tool_use, turn 2 with tool_result -> MOCK_OK)
curl -fsS -X POST "${BASE}/_mock/reset" >/dev/null
curl -fsS -X POST "${BASE}/_mock/config" -H "content-type: application/json" \
  -d '{"tool_write_path":"/workspace/out.txt","tool_write_content":"HELLO_TOOL"}' >/dev/null

t1=$(curl -fsS -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" \
  -d '{"model":"claude-mock","stream":true,"tools":[{"name":"Write"}],"messages":[{"role":"user","content":"write file"}]}')
python3 - "${t1}" << 'EOF'
import sys
d = sys.argv[1]
assert "tool_use" in d
assert "/workspace/out.txt" in d
assert "HELLO_TOOL" in d
EOF

t1_json=$(curl -fsS -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" \
  -d '{"model":"claude-mock","stream":false,"tools":[{"name":"Write"}],"messages":[{"role":"user","content":"write file"}]}')
python3 - "${t1_json}" << 'EOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["stop_reason"] == "tool_use"
assert d["content"][0]["name"] == "Write"
assert d["content"][0]["input"]["file_path"] == "/workspace/out.txt"
EOF

t2=$(curl -fsS -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" \
  -d '{"model":"claude-mock","stream":true,"tools":[{"name":"Write"}],"messages":[{"role":"user","content":"write file"},{"role":"assistant","content":[{"type":"tool_use","id":"toolu_mock_01","name":"Write","input":{"file_path":"/workspace/out.txt","content":"HELLO_TOOL"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_mock_01","content":"ok"}]}]}')
python3 - "${t2}" << 'EOF'
import sys
d = sys.argv[1]
assert "MOCK_OK" in d
assert "event: message_stop" in d
EOF

# 10. Reset clears request log AND restores startup config (no tool_use or fault)
curl -fsS -X POST "${BASE}/_mock/reset" >/dev/null
after=$(curl -fsS "${BASE}/_mock/requests")
test "${after}" = "[]"
normal=$(curl -fsS -X POST "${BASE}/v1/messages" \
  -H "x-api-key: ${EXPECTED_KEY}" -H "content-type: application/json" \
  -d '{"model":"claude-mock","stream":false,"tools":[{"name":"Write"}],"messages":[{"role":"user","content":"hi"}]}')
python3 - "${normal}" << 'EOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["stop_reason"] == "end_turn"
assert d["content"][0]["text"] == "MOCK_OK"
EOF

echo "ALL SELFTEST CHECKS PASSED"
