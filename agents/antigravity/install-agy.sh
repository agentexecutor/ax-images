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

# Installs a released Antigravity CLI (agy) binary for the current Linux
# platform (glibc), verifying its SHA-512 checksum against the release manifest.
#
#   install-agy.sh [version|latest] [dest-dir]

set -euo pipefail

version="${1:-latest}"
dest="${2:-${HOME:-/root}/.local/bin}"
UPDATER="${AGY_RELEASE_BASE_URL:-https://antigravity-cli-auto-updater-974169037036.us-central1.run.app}"
GCS="${AGY_GCS_BASE_URL:-https://storage.googleapis.com/antigravity-public}"

case "$(uname -m)" in
  x86_64|amd64) platform="linux-x64" ;;
  aarch64|arm64) platform="linux-arm" ;;
  *)
    echo "install-agy: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

releases="$(curl -fsSL "${UPDATER}/releases")"
if [[ "${version}" == "latest" ]]; then
  entry="$(jq -c '.[0]' <<<"${releases}")"
else
  entry="$(jq -c --arg v "${version}" 'map(select(.version == $v)) | .[0]' <<<"${releases}")"
fi
if [[ -z "${entry}" || "${entry}" == "null" ]]; then
  echo "install-agy: version ${version} not found in ${UPDATER}/releases" >&2
  exit 1
fi

resolved_version="$(jq -r .version <<<"${entry}")"
execution_id="$(jq -r .execution_id <<<"${entry}")"

manifest="$(curl -fsSL "${GCS}/antigravity-cli/${resolved_version}-${execution_id}/${platform}/manifest.json")"
url="$(jq -r .url <<<"${manifest}")"
sha512="$(jq -r .sha512 <<<"${manifest}")"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

curl -fsSL -o "${tmp}/agy.tar.gz" "${url}"
echo "${sha512}  ${tmp}/agy.tar.gz" | sha512sum -c - >/dev/null
tar -xzf "${tmp}/agy.tar.gz" -C "${tmp}" antigravity

mkdir -p "${dest}"
install -m 0755 "${tmp}/antigravity" "${dest}/agy"
echo "install-agy: installed agy ${resolved_version} (${platform}) to ${dest}/agy" >&2
