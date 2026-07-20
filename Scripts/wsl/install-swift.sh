#!/usr/bin/env bash
# Fork: download and install the Swift toolchain into ~/swift for WSL builds.
# Usage: bash Scripts/wsl/install-swift.sh   (no sudo required)
set -euo pipefail

SWIFT_TAG="${SWIFT_TAG:-swift-6.3.3-RELEASE}"
SWIFT_ROOT="${SWIFT_ROOT:-$HOME/swift}"
PLATFORM_DIR="ubuntu2404"
PLATFORM_SUFFIX="ubuntu24.04"

# WSL host proxy injection. Only inject when the user hasn't set one and the
# host's proxy port is actually reachable from the WSL subnet. Under default
# NAT WSL2 a Windows proxy that only binds 127.0.0.1 is unreachable from the
# guest; injecting it blindly makes curl hang for minutes. If the probe fails
# we warn and go direct (download.swift.org is usually reachable anyway).
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

# Ubuntu 24.04 ships only the wide-char build (libncursesw.so.6); Swift 6.3
# links the narrow libncurses.so.6 at runtime. Shim the narrow SONAME onto the
# wide lib (ABI-compatible for Swift's usage). ldconfig -p covers both arches.
SHIM_DIR="${SWIFT_ROOT}/shims"
NCURSES_WIDE="$(ldconfig -p 2>/dev/null | awk '/libncursesw\.so\.6$/ {print $NF; exit}')"
if [[ -n "${NCURSES_WIDE}" ]] && ! ldconfig -p 2>/dev/null | grep -q '	libncurses\.so\.6 '; then
    mkdir -p "${SHIM_DIR}"
    ln -sf "${NCURSES_WIDE}" "${SHIM_DIR}/libncurses.so.6"
    TINFO_WIDE="$(ldconfig -p 2>/dev/null | awk '/libtinfow\.so\.6$/ {print $NF; exit}')"
    [[ -n "${TINFO_WIDE}" ]] && ln -sf "${TINFO_WIDE}" "${SHIM_DIR}/libtinfo.so.6"
    export LD_LIBRARY_PATH="${SHIM_DIR}:${LD_LIBRARY_PATH:-}"
    echo "note: shimmed libncurses.so.6 -> ${NCURSES_WIDE} at ${SHIM_DIR}"
    echo "note: deploy.sh auto-prepends this to LD_LIBRARY_PATH; for manual swift invocations add to ~/.bashrc:"
    echo "  export LD_LIBRARY_PATH=\"${SHIM_DIR}:\${LD_LIBRARY_PATH:-}\""
fi

"${SWIFT_ROOT}/current/usr/bin/swift" --version
echo "Swift installed at ${SWIFT_ROOT}/current"
