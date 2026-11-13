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

# End-to-end verification of the pure agents/antigravity image on Agent
# Substrate (gVisor) with ax-task-runner mounted read-only at /opt/ax via
# ImageVolumeSource, tested against fakes/mock-gemini across 7 cases.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AX_DIR="${AX_DIR:-${REPO_ROOT}/../ax}"

if [[ -z "${KUBECONFIG:-}" && -f "${AX_DIR}/.tmp/e2e.env" ]]; then
  # shellcheck disable=SC1091
  source "${AX_DIR}/.tmp/e2e.env"
fi

export PATH="${GOPATH:-${HOME}/go}/bin:${PATH}"
KUBECTL_ATE="${KUBECTL_ATE:-$(command -v kubectl-ate || true)}"
if [[ -z "${KUBECTL_ATE}" ]]; then
  echo "error: kubectl-ate not found on PATH (or set KUBECTL_ATE)" >&2
  exit 1
fi
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "error: KUBECONFIG is not set and ${AX_DIR}/.tmp/e2e.env was not found" >&2
  exit 1
fi

KCTL=(kubectl --kubeconfig "${KUBECONFIG}")
KATE=("${KUBECTL_ATE}" --kubeconfig "${KUBECONFIG}")
LOCAL_REGISTRY="${LOCAL_REGISTRY:-localhost:5001}"
MOCK_URL="http://mock-gemini.ax-test.svc.cluster.local:8080"
EXPECTED_KEY="${EXPECTED_KEY:-test-key-e2e}"
PF_PORT="${PF_PORT:-18086}"
MOCK_LOCAL="http://127.0.0.1:${PF_PORT}"

# 1. Build/push local images if digests were not supplied.
if [[ -z "${MOCK_DIGEST:-}" ]]; then
  echo "==> Building and pushing mock-gemini to ${LOCAL_REGISTRY}..."
  docker build -t "${LOCAL_REGISTRY}/mock-gemini:e2e" "${REPO_ROOT}/fakes/mock-gemini" >/dev/null
  docker push "${LOCAL_REGISTRY}/mock-gemini:e2e" >/dev/null
  MOCK_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${LOCAL_REGISTRY}/mock-gemini:e2e" | head -n1)"
fi

if [[ -z "${AGY_DIGEST:-}" ]]; then
  echo "==> Building and pushing pure Antigravity image (PREINSTALL_AGY=true for airgapped E2E)..."
  docker build --build-arg PREINSTALL_AGY=true -t "${LOCAL_REGISTRY}/ax-antigravity:e2e" "${REPO_ROOT}/agents/antigravity" >/dev/null
  docker push "${LOCAL_REGISTRY}/ax-antigravity:e2e" >/dev/null
  AGY_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${LOCAL_REGISTRY}/ax-antigravity:e2e" | head -n1)"
fi

if [[ -z "${RUNNER_DIGEST:-}" ]]; then
  if [[ ! -d "${AX_DIR}" ]]; then
    echo "error: AX_DIR (${AX_DIR}) not found; set AX_DIR or RUNNER_DIGEST" >&2
    exit 1
  fi
  echo "==> Building and pushing static ax-task-runner volume image..."
  TMP_R="$(mktemp -d)"
  (cd "${AX_DIR}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o "${TMP_R}/ax-task-runner" ./cmd/ax-task-runner)
  printf 'FROM scratch\nCOPY ax-task-runner /ax-task-runner\n' >"${TMP_R}/Dockerfile"
  docker build -t "${LOCAL_REGISTRY}/ax-runner:e2e" "${TMP_R}" >/dev/null
  docker push "${LOCAL_REGISTRY}/ax-runner:e2e" >/dev/null
  rm -rf "${TMP_R}"
  RUNNER_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${LOCAL_REGISTRY}/ax-runner:e2e" | head -n1)"
fi

# 2. Deploy mock-gemini and port-forward for test inspection.
echo "==> Deploying mock-gemini (${MOCK_DIGEST})..."
sed "s|MOCK_GEMINI_IMAGE_PLACEHOLDER|${MOCK_DIGEST}|g" "${SCRIPT_DIR}/k8s/mock-gemini.yaml" | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n ax-test rollout status deployment/mock-gemini --timeout=60s >/dev/null

PF_LOG="$(mktemp)"
"${KCTL[@]}" port-forward -n ax-test svc/mock-gemini "${PF_PORT}:8080" >"${PF_LOG}" 2>&1 &
PF_PID=$!

CREATED_ACTORS=()
CREATED_TMPLS=()
cleanup() {
  for a in "${CREATED_ACTORS[@]:-}"; do
    [[ -n "${a}" ]] && "${KATE[@]}" delete actor "${a}" -a default >/dev/null 2>&1 || true
  done
  for t in "${CREATED_TMPLS[@]:-}"; do
    [[ -n "${t}" ]] && "${KATE[@]}" delete actor-template "${t}" -a default >/dev/null 2>&1 || true
  done
  kill "${PF_PID}" 2>/dev/null || true
  rm -f "${PF_LOG}"
}
trap cleanup EXIT

for _ in $(seq 1 30); do
  curl -fsS "${MOCK_LOCAL}/healthz" >/dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS "${MOCK_LOCAL}/healthz" >/dev/null

reset_mock() {
  curl -fsS -X POST "${MOCK_LOCAL}/_mock/reset" >/dev/null
}

get_requests() {
  curl -fsS "${MOCK_LOCAL}/_mock/requests"
}

wait_for_log() {
  local actor="$1"
  local timeout_s="${2:-120}"
  local logs=""
  for _ in $(seq 1 "${timeout_s}"); do
    logs="$("${KATE[@]}" logs actor "${actor}" -a default 2>&1 || true)"
    if echo "${logs}" | grep -qE "task command completed successfully|task command exited with error"; then
      echo "${logs}"
      return 0
    fi
    sleep 1
  done
  echo "${logs}"
  return 1
}

delete_case() {
  local suffix="$1"
  "${KATE[@]}" delete actor "agy-actor-${suffix}" -a default >/dev/null 2>&1 || true
  "${KATE[@]}" delete actor-template "agy-tmpl-${suffix}" -a default >/dev/null 2>&1 || true
}

start_mounted_case() {
  local suffix="$1"
  local policy_mode="$2"   # "http" | "inject" | "none"
  local goal="$3"
  local cfg_json="$4"
  local cmd_shell="$5"
  local extra_env_yaml="$6"
  local tmpl="agy-tmpl-${suffix}"
  local actor="agy-actor-${suffix}"
  CREATED_TMPLS+=("${tmpl}")
  CREATED_ACTORS+=("${actor}")

  local tmpl_file
  tmpl_file="$(mktemp)"
  cat >"${tmpl_file}" <<EOF
metadata:
  name: ${tmpl}
  atespace: default
containers:
- name: guest
  image: ${AGY_DIGEST}
  command:
  - /opt/ax/ax-task-runner
  env:
  - name: AX_WORKSPACE_YAML
    value: |
      apiVersion: ax.io/v1alpha1
      kind: Workspace
      metadata:
        name: ws-${suffix}
        atespace: default
      spec:
        files:
        - path: .ax/goal.md
          content: "${goal}"
        - path: .ax/config.json
          content: '${cfg_json}'
  - name: AX_TASK_YAML
    value: |
      apiVersion: ax.io/v1alpha1
      kind: Task
      metadata:
        name: ${actor}
        atespace: default
      spec:
        command:
        - /bin/bash
        - -c
        - '${cmd_shell}'
        env:
        - name: AX_GOAL_FILE
          value: /workspace/.ax/goal.md
        - name: AX_CONFIG_FILE
          value: /workspace/.ax/config.json
${extra_env_yaml}
  volumeMounts:
  - mountPath: /workspace
    name: workspace
  - mountPath: /opt/ax
    name: ax-runner
  wakeupProbe:
    httpGet:
      path: /readyz
      port: 80
    timeoutSeconds: 30
volumes:
- name: workspace
  durableDir: {}
- name: ax-runner
  image:
    reference: ${RUNNER_DIGEST}
resources:
  limits:
    cpuMillicores: "1000"
    memoryBytes: "2147483648"
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_VOLUMES
EOF

  "${KATE[@]}" create actor-template -f "${tmpl_file}" >/dev/null 2>&1
  rm -f "${tmpl_file}"
  "${KATE[@]}" create actor "${actor}" -a default --template "${tmpl}" >/dev/null 2>&1

  if [[ "${policy_mode}" == "http" ]]; then
    "${KATE[@]}" create egress-policy "${actor}" -a default -f "${SCRIPT_DIR}/k8s/egress-policy-http.yaml" >/dev/null 2>&1
  elif [[ "${policy_mode}" == "inject" ]]; then
    "${KATE[@]}" create egress-policy "${actor}" -a default -f "${SCRIPT_DIR}/k8s/egress-policy-inject.yaml" >/dev/null 2>&1
  fi

  "${KATE[@]}" resume actor "${actor}" -a default >/dev/null 2>&1
}

PASS=0
FAIL=0
check() {
  local name="$1"
  local ok="$2"
  local detail="$3"
  if [[ "${ok}" == "true" ]]; then
    echo "[PASS] ${name}: ${detail}"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${name}: ${detail}"
    FAIL=$((FAIL + 1))
  fi
}

STD_GOAL="Reply with exactly the text you receive from the model."
STD_CFG='{"prompt":"Reply with exactly the text you receive from the model."}'

echo "=== Case 1: Happy path (Gemini x-goog-api-key) ==="
reset_mock
start_mounted_case "happy-$$" "http" "${STD_GOAL}" "${STD_CFG}" "/usr/local/bin/ax-harness" \
"        - name: GOOGLE_GEMINI_BASE_URL
          value: ${MOCK_URL}
        - name: GEMINI_API_KEY
          value: ${EXPECTED_KEY}"
logs1="$(wait_for_log "agy-actor-happy-$$" 60 || true)"
reqs1="$(get_requests)"
ok1="$(python3 - "${reqs1}" "${logs1}" <<'EOF'
import json, sys
reqs, logs = json.loads(sys.argv[1]), sys.argv[2]
ok = ("MOCK_OK" in logs and "task command completed successfully" in logs
      and len(reqs) >= 1 and all(r["auth_ok"] for r in reqs)
      and any(":streamGenerateContent" in r["path"] for r in reqs))
print("true" if ok else "false")
EOF
)"
check "Case 1 (Happy path)" "${ok1}" "requests=$(python3 - "${reqs1}" <<'EOF'
import json, sys
r = json.loads(sys.argv[1])
print(len(r), [x["auth_ok"] for x in r])
EOF
)"
delete_case "happy-$$"

echo "=== Case 2: Wrong key (400) ==="
reset_mock
start_mounted_case "badkey-$$" "http" "${STD_GOAL}" "${STD_CFG}" "/usr/local/bin/ax-harness" \
"        - name: GOOGLE_GEMINI_BASE_URL
          value: ${MOCK_URL}
        - name: GEMINI_API_KEY
          value: wrong-key
        - name: AGY_CLI_MODEL_API_MAX_RETRIES
          value: \"0\""
logs2="$(wait_for_log "agy-actor-badkey-$$" 60 || true)"
reqs2="$(get_requests)"
ok2="$(python3 - "${reqs2}" "${logs2}" <<'EOF'
import json, sys
reqs, logs = json.loads(sys.argv[1]), sys.argv[2]
ok = ("task command exited with error" in logs
      and len(reqs) >= 1 and all(not r["auth_ok"] for r in reqs))
print("true" if ok else "false")
EOF
)"
check "Case 2 (Wrong key)" "${ok2}" "requests=$(python3 - "${reqs2}" <<'EOF'
import json, sys
r = json.loads(sys.argv[1])
print(len(r), [x["auth_ok"] for x in r])
EOF
)"
delete_case "badkey-$$"

echo "=== Case 3: Missing key ==="
reset_mock
NOKEY_CFG='{"prompt":"Reply with MOCK_OK.","settings":{"modelProvider":"gemini"}}'
start_mounted_case "nokey-$$" "http" "${STD_GOAL}" "${NOKEY_CFG}" "/usr/local/bin/ax-harness" \
"        - name: GOOGLE_GEMINI_BASE_URL
          value: ${MOCK_URL}"
logs3="$(wait_for_log "agy-actor-nokey-$$" 60 || true)"
reqs3="$(get_requests)"
ok3="$(python3 - "${reqs3}" "${logs3}" <<'EOF'
import json, sys
reqs, logs = json.loads(sys.argv[1]), sys.argv[2]
ok = ("task command exited with error" in logs and len(reqs) == 0)
print("true" if ok else "false")
EOF
)"
check "Case 3 (Missing key)" "${ok3}" "requests=$(python3 - "${reqs3}" <<'EOF'
import json, sys
print(len(json.loads(sys.argv[1])))
EOF
)"
delete_case "nokey-$$"

echo "=== Case 4: Egress denied (no EgressPolicy) ==="
reset_mock
NOEGRESS_CFG='{"prompt":"Reply with MOCK_OK.","printTimeout":"10s"}'
start_mounted_case "noegress-$$" "none" "${STD_GOAL}" "${NOEGRESS_CFG}" "/usr/local/bin/ax-harness" \
"        - name: GOOGLE_GEMINI_BASE_URL
          value: ${MOCK_URL}
        - name: GEMINI_API_KEY
          value: ${EXPECTED_KEY}
        - name: AGY_CLI_MODEL_API_MAX_RETRIES
          value: \"0\""
logs4="$(wait_for_log "agy-actor-noegress-$$" 90 || true)"
reqs4="$(get_requests)"
ok4="$(python3 - "${reqs4}" "${logs4}" <<'EOF'
import json, sys
reqs, logs = json.loads(sys.argv[1]), sys.argv[2]
ok = ("task command exited with error" in logs and len(reqs) == 0)
print("true" if ok else "false")
EOF
)"
check "Case 4 (Egress denied)" "${ok4}" "requests=$(python3 - "${reqs4}" <<'EOF'
import json, sys
print(len(json.loads(sys.argv[1])))
EOF
)"
delete_case "noegress-$$"

echo "=== Case 5: Gateway credential injection (plain HTTP + k8s.io) ==="
reset_mock
start_mounted_case "inject-$$" "inject" "${STD_GOAL}" "${STD_CFG}" \
"/usr/local/bin/ax-harness && if tr \"\\0\" \"\\n\" </proc/1/environ | grep -q \"${EXPECTED_KEY}\"; then echo SECRET_LEAKED=true; else echo SECRET_LEAKED=false; fi" \
"        - name: GOOGLE_GEMINI_BASE_URL
          value: ${MOCK_URL}
        - name: GEMINI_API_KEY
          value: placeholder"
logs5="$(wait_for_log "agy-actor-inject-$$" 60 || true)"
reqs5="$(get_requests)"
ok5="$(python3 - "${reqs5}" "${logs5}" <<'EOF'
import json, sys
reqs, logs = json.loads(sys.argv[1]), sys.argv[2]
ok = ("MOCK_OK" in logs and "SECRET_LEAKED=false" in logs
      and "task command completed successfully" in logs
      and len(reqs) >= 1 and all(r["auth_ok"] for r in reqs))
print("true" if ok else "false")
EOF
)"
check "Case 5 (Gateway injection)" "${ok5}" "requests=$(python3 - "${reqs5}" <<'EOF'
import json, sys
r = json.loads(sys.argv[1])
print(len(r), [x["auth_ok"] for x in r])
EOF
), secret_in_sandbox=false"
delete_case "inject-$$"

echo "=== Case 6: Scripted write_file functionCall + outputFile ==="
reset_mock
curl -fsS -X POST "${MOCK_LOCAL}/_mock/config" -H "content-type: application/json" \
  -d '{"tool_write_path":"/workspace/tool_ok.txt","tool_write_content":"HELLO_FROM_AGY_TOOL"}' >/dev/null
TOOL_CFG='{"prompt":"Write a file as instructed.","outputFile":"/workspace/answer.md"}'
start_mounted_case "tool-$$" "inject" "Write a file as instructed." "${TOOL_CFG}" \
"/usr/local/bin/ax-harness && printf \"TOOL_FILE_VALUE=%s\\nANSWER_FILE_VALUE=%s\\n\" \"\$(cat /workspace/tool_ok.txt)\" \"\$(cat /workspace/answer.md)\"" \
"        - name: GOOGLE_GEMINI_BASE_URL
          value: ${MOCK_URL}
        - name: GEMINI_API_KEY
          value: placeholder"
logs6="$(wait_for_log "agy-actor-tool-$$" 60 || true)"
reqs6="$(get_requests)"
ok6="$(python3 - "${reqs6}" "${logs6}" <<'EOF'
import json, sys
reqs, logs = json.loads(sys.argv[1]), sys.argv[2]
ok = ("MOCK_OK" in logs
      and "TOOL_FILE_VALUE=HELLO_FROM_AGY_TOOL" in logs
      and "ANSWER_FILE_VALUE=MOCK_OK" in logs
      and "task command completed successfully" in logs
      and len(reqs) >= 2 and all(r["auth_ok"] for r in reqs))
print("true" if ok else "false")
EOF
)"
check "Case 6 (Scripted write_file + outputFile)" "${ok6}" "turns=$(python3 - "${reqs6}" <<'EOF'
import json, sys
print(len(json.loads(sys.argv[1])))
EOF
)"
delete_case "tool-$$"

echo "=== Case 7: FAULT=503 retry and recovery ==="
reset_mock
curl -fsS -X POST "${MOCK_LOCAL}/_mock/config" -H "content-type: application/json" -d '{"fault":"503"}' >/dev/null
start_mounted_case "fault-$$" "inject" "Reply with MOCK_OK." "${STD_CFG}" "/usr/local/bin/ax-harness" \
"        - name: GOOGLE_GEMINI_BASE_URL
          value: ${MOCK_URL}
        - name: GEMINI_API_KEY
          value: placeholder"
for _ in $(seq 1 40); do
  reqs_now="$(get_requests)"
  cnt="$(python3 - "${reqs_now}" <<'EOF'
import json, sys
print(len(json.loads(sys.argv[1])))
EOF
)"
  if [[ "${cnt}" -ge 1 ]]; then
    break
  fi
  sleep 0.5
done
curl -fsS -X POST "${MOCK_LOCAL}/_mock/config" -H "content-type: application/json" -d '{"fault":""}' >/dev/null
logs7="$(wait_for_log "agy-actor-fault-$$" 60 || true)"
reqs7="$(get_requests)"
ok7="$(python3 - "${reqs7}" "${logs7}" <<'EOF'
import json, sys
reqs, logs = json.loads(sys.argv[1]), sys.argv[2]
ok = ("MOCK_OK" in logs and "task command completed successfully" in logs
      and len(reqs) >= 2 and all(r["auth_ok"] for r in reqs))
print("true" if ok else "false")
EOF
)"
check "Case 7 (FAULT=503 recovery)" "${ok7}" "requests=$(python3 - "${reqs7}" <<'EOF'
import json, sys
print(len(json.loads(sys.argv[1])))
EOF
)"
delete_case "fault-$$"
reset_mock

echo ""
echo "Summary: ${PASS} passed, ${FAIL} failed"
test "${FAIL}" -eq 0
