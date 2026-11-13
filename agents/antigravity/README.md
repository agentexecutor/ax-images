# Antigravity Agent Image (`agents/antigravity`)

Pure mount-ready container image and launcher (`ax-harness`) for running
headless [Antigravity CLI (`agy`)](https://antigravity.google/docs/cli/install)
tasks under the AX in-container wrapper contract. Contains no AX runner binary
(`ax-task-runner` is mounted read-only by AX at `/opt/ax`).

## Launcher Contract (`/usr/local/bin/ax-harness`)

The mounted AX runner prepares `/workspace`, writes task inputs to files, and
invokes `/usr/local/bin/ax-harness` with `/workspace` as the working directory:

- `AX_GOAL_FILE` *(required)* — Path to the file holding the task prompt (`spec.config.prompt`).
- `AX_CONFIG_FILE` *(optional)* — Path to `spec.config` serialized as JSON. Every `camelCase` key maps to the matching `agy` `--kebab-case` CLI flag, with three special keys:
  - `prompt` — Passed via `--print=<goal>` from `AX_GOAL_FILE`.
  - `outputFile` — Optional path where `agy`'s answer is also written (in addition to stdout/logs), preserving `agy`'s exit code.
  - `settings` — Merged into `--settings=<JSON>`.
- **Defaults:** `--dangerously-skip-permissions` (headless runs cannot answer interactive prompts) and `--add-dir=<cwd>` (so relative file-tool paths resolve inside `/workspace`).
- **Authentication:**
  - When `GEMINI_API_KEY` is set (and `AGY_ADC_AUTH` is unset), `ax-harness` automatically sets `"modelProvider": "gemini"` in `--settings`; `GOOGLE_GEMINI_BASE_URL` optionally points requests at a gateway or mock endpoint.
  - When `AGY_ADC_AUTH=true`, `agy` authenticates via Application Default Credentials against `GOOGLE_CLOUD_PROJECT` (Vertex AI).

## Runtime vs. Pre-Installed Builds

- **Default (`PREINSTALL_AGY=false`):** Ships Debian packages, `/usr/local/share/ax/install-agy.sh`, and `/usr/local/bin/ax-harness` (no `agy` binary bundled in the image). When `agy` is missing at container startup, `ax-harness` installs `AGY_VERSION` (default `latest`) with SHA-512 verification.
- **Optional pre-installed build (`--build-arg PREINSTALL_AGY=true`):** Installs `agy` during `docker build` for local or airgapped E2E environments where internet egress is blocked.

## Local Test

```bash
./agents/antigravity/test_harness.sh
```
