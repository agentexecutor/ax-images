# Claude Code + Mounted AX Runner E2E Suite (`e2e/claude-code`)

End-to-end test suite exercising the pure `agents/claude-code` image inside real
Agent Substrate gVisor sandboxes with a static `ax-task-runner` binary mounted
read-only at `/opt/ax` (`ImageVolumeSource`), tested against an in-cluster
`fakes/mock-anthropic` Deployment.

## Cases Covered

1. **Happy path (`x-api-key`):** Direct Anthropic `/v1/messages` SSE stream → `MOCK_OK`.
2. **Wrong key (`401`):** Rejected by `mock-anthropic`, command exits non-zero.
3. **Missing key:** Command exits non-zero without authenticated calls.
4. **Egress denied (no `EgressPolicy`):** Outbound DNS/HTTP blocked by Substrate (`0` requests reach `mock-anthropic`).
5. **Vertex AI path (`:streamRawPredict`):** `CLAUDE_CODE_USE_VERTEX=1` with Bearer auth → `MOCK_OK`.
6. **Gateway credential injection (`k8s.io`):** Sandbox holds only `ANTHROPIC_API_KEY=placeholder`; Substrate egress gateway injects `ax-test/mock-anthropic[key]`, and `/proc/1/environ` inside the sandbox is verified free of the secret.
7. **Scripted `Write` `tool_use`:** Multi-turn tool call writes `/workspace/tool_ok.txt` inside the durable workspace volume before returning `MOCK_OK`.
8. **`FAULT=500` retry & recovery:** Injects transient `500` errors, verifies SDK retry attempts, clears fault via `/_mock/config`, and verifies recovery to `MOCK_OK`.

## Prerequisites

- A KinD cluster with Agent Substrate (`gvisor` `WorkerPool`, `atenet` with `k8s.io` credential provider, and `k8s-credential-provider-namespace-policy` allowing `default` → `ax-test`), such as the cluster created by `ax`'s `hack/setup-e2e-kind.sh` (`localhost:5001` local registry).
- `kubectl` and `kubectl-ate` on `PATH` (or `KUBECTL_ATE` set).
- Either an adjacent `ax` checkout (`AX_DIR`, default `../ax`) to cross-compile the static `ax-task-runner`, or `RUNNER_DIGEST` pointing to a pre-pushed runner volume image.

## Running

```bash
./e2e/claude-code/run_e2e.sh
```

Optional environment overrides: `AX_DIR`, `KUBECONFIG`, `KUBECTL_ATE`,
`LOCAL_REGISTRY` (default `localhost:5001`), `MOCK_DIGEST`, `CC_DIGEST`, and
`RUNNER_DIGEST`.
