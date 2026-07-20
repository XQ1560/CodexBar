#!/usr/bin/env bash
# Fork: build CodexBarCLI on WSL and deploy it into the CodexBar runtime root.
# Usage: bash Scripts/wsl/deploy.sh [runtime-root]   (default /mnt/d/CodexBar)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CODEXBAR_REPO:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
# Safety: refuse to run against anything that is not the CodexBar repo
# (protects the rsync --delete below from a mis-resolved path).
if [[ ! -f "${REPO_ROOT}/Package.swift" || ! -f "${REPO_ROOT}/version.env" ]]; then
    echo "error: ${REPO_ROOT} does not look like the CodexBar repo (set CODEXBAR_REPO)" >&2
    exit 1
fi
RUNTIME_ROOT="${1:-/mnt/d/CodexBar}"
BUILD_ROOT="${CODEXBAR_BUILD_ROOT:-$HOME/.cache/codexbar-wsl-build}"
SWIFT_BIN="${SWIFT_BIN:-$HOME/swift/current/usr/bin/swift}"

# Swift 6.3 links the narrow-char libncurses.so.6; Ubuntu 24.04 ships only the
# wide build. install-swift.sh shims it under ~/swift/shims; load it so swift
# starts (otherwise: "libncurses.so.6: cannot open shared object file").
if [[ -d "${HOME}/swift/shims" ]]; then
    export LD_LIBRARY_PATH="${HOME}/swift/shims:${LD_LIBRARY_PATH:-}"
fi

# WSL host proxy injection. Only inject when the user hasn't set one and the
# host's proxy port is actually reachable from the WSL subnet. Blind injection
# under default NAT WSL2 (proxy bound to 127.0.0.1 only) makes SwiftPM hangs on
# github.com. If the probe fails we warn and go direct.
codexbar_maybe_inject_proxy() {
    [[ -z "${HTTPS_PROXY:-}" && -z "${https_proxy:-}" ]] || return 0
    local host_ip port
    host_ip="$(ip -4 route show default | awk 'NR == 1 { print $3 }')"
    [[ -n "${host_ip}" ]] || return 0
    port="${CODEXBAR_PROXY_PORT:-7897}"
    if timeout 1 bash -c "</dev/tcp/${host_ip}/${port}" 2>/dev/null; then
        export HTTP_PROXY="http://${host_ip}:${port}"
        export HTTPS_PROXY="${HTTP_PROXY}"
        export http_proxy="${HTTP_PROXY}" https_proxy="${HTTPS_PROXY}"
        export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
        export no_proxy="${NO_PROXY}"
    else
        echo "codexbar: host proxy ${host_ip}:${port} not reachable from WSL; going direct (export HTTPS_PROXY to force, or open 'Allow LAN' in the proxy client)" >&2
    fi
}
codexbar_maybe_inject_proxy

# 1. Mirror the repo onto the WSL-native filesystem (drvfs builds are painfully slow).
mkdir -p "${BUILD_ROOT}/src"
rsync -a --delete --exclude .git --exclude .build "${REPO_ROOT}/" "${BUILD_ROOT}/src/"

# 2. Build the Linux CLI.
"${SWIFT_BIN}" build \
    --package-path "${BUILD_ROOT}/src" \
    --product CodexBarCLI \
    -c release
BIN_PATH="$("${SWIFT_BIN}" build --package-path "${BUILD_ROOT}/src" --product CodexBarCLI -c release --show-bin-path)/CodexBarCLI"

# 3. Install under the runtime root as app/v<version>-fork.
VERSION="$(grep -oP '(?<=^MARKETING_VERSION=).*' "${REPO_ROOT}/version.env" | tr -d '\r')"
APP_DIR="${RUNTIME_ROOT}/app/v${VERSION}-fork"
mkdir -p "${APP_DIR}"
install -m 0755 "${BIN_PATH}" "${APP_DIR}/CodexBarCLI"
printf '%s-fork\n' "${VERSION}" > "${APP_DIR}/VERSION"

# 4. Install/update the launcher from the repo (it auto-resolves the latest version).
LAUNCHER="${RUNTIME_ROOT}/bin/codexbar"
LAUNCHER_SRC="${REPO_ROOT}/Scripts/wsl/codexbar.launcher.sh"
mkdir -p "${RUNTIME_ROOT}/bin"
install -m 0755 "${LAUNCHER_SRC}" "${LAUNCHER}"

echo "Deployed ${APP_DIR}/CodexBarCLI"
"${LAUNCHER}" --version
