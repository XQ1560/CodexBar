#!/usr/bin/env bash
# Fork: WSL launcher for CodexBarCLI. Installed to <runtime-root>/bin/codexbar by
# Scripts/wsl/deploy.sh. Resolves the latest deployed version directory, points the
# local-log scanners at the real Windows client data, and forwards args to the CLI.
set -euo pipefail

# Runtime root: override with CODEXBAR_ROOT, default to the conventional D:\CodexBar.
readonly CODEXBAR_ROOT="${CODEXBAR_ROOT:-/mnt/d/CodexBar}"
export CODEXBAR_CONFIG="${CODEXBAR_ROOT}/config/config.json"
export CODEXBAR_HOME="${CODEXBAR_ROOT}"
export XDG_CACHE_HOME="${CODEXBAR_ROOT}/cache"
export XDG_DATA_HOME="${CODEXBAR_ROOT}/data"
export TMPDIR="${CODEXBAR_ROOT}/tmp"

# Isolated codex-home (WSL-only copy, used when CODEXBAR_KEEP_ISOLATED_HOME=1).
# By default we override CODEX_HOME below to point at the real Windows client data.
export CODEX_HOME="${CODEXBAR_ROOT}/codex-home"

# Resolve the latest deployed app version (v<version>-fork), falling back to any
# non-fork v<version> dir. Avoids hard-coding the version in this file.
codexbar_resolve_binary() {
    local app_dir="${CODEXBAR_ROOT}/app"
    [[ -d "${app_dir}" ]] || return 0
    # Prefer the highest fork version, then the highest non-fork version.
    local latest
    latest="$(ls -1d "${app_dir}"/v*-fork 2>/dev/null | sort -V | tail -1)"
    if [[ -z "${latest}" ]]; then
        latest="$(ls -1d "${app_dir}"/v* 2>/dev/null | sort -V | tail -1)"
    fi
    if [[ -n "${latest}" && -x "${latest}/CodexBarCLI" ]]; then
        printf '%s\n' "${latest}/CodexBarCLI"
    fi
}

readonly CODEXBAR_BIN="${CODEXBAR_BIN:-$(codexbar_resolve_binary)}"
if [[ -z "${CODEXBAR_BIN}" || ! -x "${CODEXBAR_BIN}" ]]; then
    echo "Error: CodexBarCLI not found under ${CODEXBAR_ROOT}/app/. Run Scripts/wsl/deploy.sh first." >&2
    exit 127
fi

# Fork: point the local-log scanners at the real Windows client data so the watch
# trend/heatmap views render actual Codex/Claude/ZCode token history (CLI + desktop
# both write to these dirs). Override with WIN_USER / the specific env var to use a
# different root, or set to empty to disable. We resolve the Windows home by scanning
# the filesystem (powershell/cmd interop is unreliable inside $() under WSL).
codexbar_resolve_win_home() {
    if [[ -n "${WIN_USER:-}" && -d "/mnt/c/Users/${WIN_USER}" ]]; then
        echo "/mnt/c/Users/${WIN_USER}"; return
    fi
    # Scan for the first user dir that actually has ZCode/Codex/Claude data.
    local candidate
    candidate="$(
        for d in /mnt/c/Users/*/; do
            [[ -d "${d}.zcode" || -d "${d}.codex" || -d "${d}.claude" ]] || continue
            # Skip Windows system / default profiles.
            case "${d}" in
                */"All Users/"|*/"Default/"|*/"Default User/"|*/"Public/"|*/"CodexSandboxOffline/") continue ;;
            esac
            printf '%s\n' "${d%/}"
            return
        done
    )"
    if [[ -n "${candidate}" ]]; then echo "${candidate}"; fi
}
readonly WIN_HOME="$(codexbar_resolve_win_home)"
if [[ -n "${WIN_HOME}" ]]; then
    # The scanners read CODEX_HOME / CLAUDE_CONFIG_DIR straight from ProcessInfo, so we
    # export them here to point at the real Windows logs. Set CODEXBAR_KEEP_ISOLATED_HOME=1
    # to keep the WSL-only codex-home behavior.
    if [[ -z "${CODEXBAR_KEEP_ISOLATED_HOME:-}" && -d "${WIN_HOME}/.codex/sessions" ]]; then
        export CODEX_HOME="${WIN_HOME}/.codex"
    fi
    if [[ -d "${WIN_HOME}/.claude/projects" ]]; then
        export CLAUDE_CONFIG_DIR="${WIN_HOME}/.claude"
    fi
    if [[ -z "${ZCODE_HOME:-}" && -d "${WIN_HOME}/.zcode/cli/agents" ]]; then
        export ZCODE_HOME="${WIN_HOME}/.zcode"
    fi
fi

if [[ -z "${HTTPS_PROXY:-}" && -z "${https_proxy:-}" ]]; then
    readonly WINDOWS_HOST="$(ip -4 route show default | awk 'NR == 1 { print $3 }')"
    if [[ -n "${WINDOWS_HOST}" ]]; then
        readonly CODEXBAR_PROXY_PORT="${CODEXBAR_PROXY_PORT:-7897}"
        export HTTP_PROXY="http://${WINDOWS_HOST}:${CODEXBAR_PROXY_PORT}"
        export HTTPS_PROXY="${HTTP_PROXY}"
        export http_proxy="${HTTP_PROXY}"
        export https_proxy="${HTTPS_PROXY}"
        export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
        export no_proxy="${NO_PROXY}"
    fi
fi

exec "${CODEXBAR_BIN}" "$@"
