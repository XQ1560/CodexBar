#!/usr/bin/env bash
# Fork: download and install the Swift toolchain into ~/swift for WSL builds.
# Usage: bash Scripts/wsl/install-swift.sh   (no sudo required)
set -euo pipefail

SWIFT_TAG="${SWIFT_TAG:-swift-6.3.3-RELEASE}"
SWIFT_ROOT="${SWIFT_ROOT:-$HOME/swift}"
PLATFORM_DIR="ubuntu2404"
PLATFORM_SUFFIX="ubuntu24.04"

# WSL host proxy (mirrors bin/codexbar): route through the Windows host if no proxy is set.
if [[ -z "${HTTPS_PROXY:-}" && -z "${https_proxy:-}" ]]; then
    host_ip="$(ip -4 route show default | awk 'NR == 1 { print $3 }')"
    if [[ -n "${host_ip}" ]]; then
        port="${CODEXBAR_PROXY_PORT:-7897}"
        export HTTP_PROXY="http://${host_ip}:${port}"
        export HTTPS_PROXY="${HTTP_PROXY}"
        export http_proxy="${HTTP_PROXY}" https_proxy="${HTTPS_PROXY}"
    fi
fi

lower_tag="$(echo "${SWIFT_TAG}" | tr '[:upper:]' '[:lower:]')"
url="https://download.swift.org/${lower_tag}/${PLATFORM_DIR}/${SWIFT_TAG}/${SWIFT_TAG}-${PLATFORM_SUFFIX}.tar.gz"
archive="${SWIFT_ROOT}/${SWIFT_TAG}-${PLATFORM_SUFFIX}.tar.gz"

mkdir -p "${SWIFT_ROOT}"
if [[ ! -x "${SWIFT_ROOT}/${SWIFT_TAG}-${PLATFORM_SUFFIX}/usr/bin/swift" ]]; then
    echo "Downloading ${url}"
    curl -fL --retry 3 -C - -o "${archive}" "${url}"
    tar -xzf "${archive}" -C "${SWIFT_ROOT}"
    rm -f "${archive}"
fi

ln -sfn "${SWIFT_ROOT}/${SWIFT_TAG}-${PLATFORM_SUFFIX}" "${SWIFT_ROOT}/current"
"${SWIFT_ROOT}/current/usr/bin/swift" --version
echo "Swift installed at ${SWIFT_ROOT}/current"
