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
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

printf 'Reply with MOCK_OK.' >"${TMP}/goal.md"
cat >"${TMP}/config.json" <<'EOF'
{
  "prompt": "Reply with MOCK_OK.",
  "model": "claude-mock",
  "maxTurns": 3,
  "dangerouslySkipPermissions": true,
  "verbose": false,
  "allowedTools": ["Bash", "Edit"],
  "settings": {"includeCoAuthoredBy": false}
}
EOF

# 1. Pre-installed binary: translates spec.config into sorted claude --print flags
cat >"${TMP}/fake-claude" <<'EOF'
#!/usr/bin/env python3
import json, sys
print(json.dumps(sys.argv[1:]))
EOF
chmod +x "${TMP}/fake-claude"

got="$(AX_GOAL_FILE="${TMP}/goal.md" AX_CONFIG_FILE="${TMP}/config.json" \
  CLAUDE_BIN="${TMP}/fake-claude" "${DIR}/ax-harness")"

python3 - "${got}" <<'EOF'
import json, sys
got = json.loads(sys.argv[1])
want = [
    "--print",
    "--allowed-tools=Bash",
    "--allowed-tools=Edit",
    "--dangerously-skip-permissions",
    "--max-turns=3",
    "--model=claude-mock",
    '--settings={"includeCoAuthoredBy":false}',
    "--",
    "Reply with MOCK_OK.",
]
assert got == want, f"got {got!r}, want {want!r}"
EOF

# 2. Runtime install fallback: installs into $HOME/.local/bin when missing
FAKE_HOME="${TMP}/home"
mkdir -p "${FAKE_HOME}"
cat >"${TMP}/mock-install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${HOME}/.local/bin"
printf '%s' "${1:-}" > "${HOME}/installed_version.txt"
cat > "${HOME}/.local/bin/claude-runtime-test" <<'INNER'
#!/usr/bin/env python3
import json, sys
print(json.dumps(sys.argv[1:]))
INNER
chmod +x "${HOME}/.local/bin/claude-runtime-test"
EOF

got_rt="$(HOME="${FAKE_HOME}" \
  AX_GOAL_FILE="${TMP}/goal.md" \
  CLAUDE_BIN="claude-runtime-test" \
  CLAUDE_CODE_VERSION="2.1.322" \
  CLAUDE_INSTALL_SCRIPT_URL="file://${TMP}/mock-install.sh" \
  "${DIR}/ax-harness" 2>/dev/null)"

test "$(cat "${FAKE_HOME}/installed_version.txt")" = "2.1.322"
python3 - "${got_rt}" <<'EOF'
import json, sys
got = json.loads(sys.argv[1])
want = ["--print", "--", "Reply with MOCK_OK."]
assert got == want, f"got {got!r}, want {want!r}"
EOF

# 3. Empty goal file fails with exit code 2
: >"${TMP}/empty.md"
set +e
AX_GOAL_FILE="${TMP}/empty.md" CLAUDE_BIN="${TMP}/fake-claude" \
  "${DIR}/ax-harness" >/dev/null 2>&1
rc=$?
set -e
test "${rc}" -eq 2

echo "ALL AX-HARNESS TESTS PASSED"
