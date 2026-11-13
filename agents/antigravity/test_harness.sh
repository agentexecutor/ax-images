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

cat >"${TMP}/fake-agy" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
print(json.dumps(sys.argv[1:]))
sys.exit(int(os.environ.get("FAKE_AGY_EXIT", "0")))
EOF
chmod +x "${TMP}/fake-agy"

run_case() {
  local cfg="$1"
  shift
  printf 'Reply with MOCK_OK.' >"${TMP}/goal.md"
  printf '%s' "${cfg}" >"${TMP}/config.json"
  (
    cd "${TMP}"
    env -u GEMINI_API_KEY -u AGY_ADC_AUTH "$@" \
      AX_GOAL_FILE="${TMP}/goal.md" \
      AX_CONFIG_FILE="${TMP}/config.json" \
      AGY_BIN="${TMP}/fake-agy" \
      "${DIR}/ax-harness"
  )
}

check_eq() {
  python3 - "$1" "$2" "$3" <<'EOF'
import json, sys
name, got, want = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
assert got == want, f"{name}:\n got  {got!r}\n want {want!r}"
EOF
}

# 1. Defaults: skip permissions, workspace registered via --add-dir, goal as --print.
check_eq "defaults" "$(run_case '{"prompt":"Reply with MOCK_OK."}')" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"

# 2. Config keys map to sorted flags; false booleans pass =false explicitly.
check_eq "flags" "$(run_case '{"prompt":"x","model":"gemini-mock","printTimeout":"15m","outputFormat":"json","dangerouslySkipPermissions":false,"addDir":["/a","/b"]}')" \
  '["--add-dir=/a", "--add-dir=/b", "--dangerously-skip-permissions=false", "--model=gemini-mock", "--output-format=json", "--print-timeout=15m", "--print=Reply with MOCK_OK."]'

# 3. GEMINI_API_KEY opts into {"modelProvider":"gemini"} and merges user settings.
check_eq "gemini-api-key" "$(run_case '{"settings":{"customModelsConfig":{"customModels":{"m":{"modelName":"m"}}}}}' GEMINI_API_KEY=k)" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--settings={\\\"modelProvider\\\":\\\"gemini\\\",\\\"customModelsConfig\\\":{\\\"customModels\\\":{\\\"m\\\":{\\\"modelName\\\":\\\"m\\\"}}}}\", \"--print=Reply with MOCK_OK.\"]"

# 4. AGY_ADC_AUTH=true suppresses modelProvider:gemini even if GEMINI_API_KEY is set.
check_eq "adc" "$(run_case '{}' GEMINI_API_KEY=k AGY_ADC_AUTH=true)" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"

# 5. outputFile tees stdout to file and preserves agy's exit status.
set +e
out="$(run_case '{"outputFile":"out/answer.txt"}' FAKE_AGY_EXIT=3)"
status=$?
set -e
test "${status}" -eq 3
check_eq "outputFile stdout" "${out}" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"
check_eq "outputFile file" "$(cat "${TMP}/out/answer.txt")" "${out}"

# 6. No outputFile leaves workspace untouched.
run_case '{}' >/dev/null
test ! -e "${TMP}/ax-output.md"

# 7. Runtime install fallback installs into $HOME/.local/bin when missing.
FAKE_HOME="${TMP}/home"
mkdir -p "${FAKE_HOME}"
cat >"${TMP}/mock-install-agy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$2"
printf '%s' "$1" > "${HOME}/installed_version.txt"
cat > "$2/agy-runtime-test" <<'INNER'
#!/usr/bin/env python3
import json, sys
print(json.dumps(sys.argv[1:]))
INNER
chmod +x "$2/agy-runtime-test"
EOF
chmod +x "${TMP}/mock-install-agy.sh"

printf 'Reply with MOCK_OK.' >"${TMP}/goal.md"
got_rt="$(
  cd "${TMP}"
  env -u GEMINI_API_KEY -u AGY_ADC_AUTH \
    HOME="${FAKE_HOME}" \
    AX_GOAL_FILE="${TMP}/goal.md" \
    AGY_BIN="agy-runtime-test" \
    AGY_VERSION="1.5.7" \
    AGY_INSTALL_SCRIPT="${TMP}/mock-install-agy.sh" \
    "${DIR}/ax-harness" 2>/dev/null
)"
test "$(cat "${FAKE_HOME}/installed_version.txt")" = "1.5.7"
check_eq "runtime-install" "${got_rt}" \
  "[\"--add-dir=${TMP}\", \"--dangerously-skip-permissions\", \"--print=Reply with MOCK_OK.\"]"

# 8. Empty goal file fails with exit code 2.
: >"${TMP}/empty.md"
set +e
AX_GOAL_FILE="${TMP}/empty.md" AGY_BIN="${TMP}/fake-agy" \
  "${DIR}/ax-harness" >/dev/null 2>&1
rc=$?
set -e
test "${rc}" -eq 2

echo "ALL AX-HARNESS TESTS PASSED"
