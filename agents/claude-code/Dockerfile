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

# Pure Claude Code agent image for AX: no AX runner baked in.
#
# By default (PREINSTALL_CLAUDE=false), the built image contains only Debian
# packages and /usr/local/bin/ax-harness, which installs Claude Code on startup
# when missing. Pass --build-arg PREINSTALL_CLAUDE=true for local or airgapped
# builds where Claude Code should be pre-installed at build time.
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        openssh-client \
        procps \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# "stable", "latest", or an exact version such as 2.1.322.
ARG CLAUDE_CODE_VERSION=stable
ARG PREINSTALL_CLAUDE=false

# Note: install.sh executes claude during setup and aborts under QEMU emulation,
# so PREINSTALL_CLAUDE=true builds must run on native amd64 / arm64 runners.
RUN if [ "${PREINSTALL_CLAUDE}" = "true" ]; then \
        curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}" \
        && ln -s /root/.local/bin/claude /usr/local/bin/claude \
        && claude --version; \
    fi

ENV IS_SANDBOX=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION}"

COPY ax-harness /usr/local/bin/ax-harness
RUN chmod 0755 /usr/local/bin/ax-harness
