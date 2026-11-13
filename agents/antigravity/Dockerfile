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

# Pure Antigravity (agy) agent image for AX: no AX runner baked in.
#
# By default (PREINSTALL_AGY=false), the built image contains only Debian
# packages, /usr/local/share/ax/install-agy.sh, and /usr/local/bin/ax-harness,
# which installs Antigravity CLI on startup when missing. Pass
# --build-arg PREINSTALL_AGY=true for local or airgapped builds where agy
# should be pre-installed at build time.
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

# "latest" or an exact released version such as 1.5.7.
ARG AGY_VERSION=latest
ARG PREINSTALL_AGY=false

COPY install-agy.sh /usr/local/share/ax/install-agy.sh
RUN chmod 0755 /usr/local/share/ax/install-agy.sh \
    && if [ "${PREINSTALL_AGY}" = "true" ]; then \
        /usr/local/share/ax/install-agy.sh "${AGY_VERSION}" /usr/local/bin \
        && agy --version; \
    fi

ENV AGY_CLI_DISABLE_AUTO_UPDATE=true \
    AGY_VERSION="${AGY_VERSION}"

COPY ax-harness /usr/local/bin/ax-harness
RUN chmod 0755 /usr/local/bin/ax-harness
