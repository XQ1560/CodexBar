# CodexBar 🎚️ — May your tokens never run out.

> Every AI coding limit, in your menu bar.

[![Latest release](https://img.shields.io/github/v/release/steipete/CodexBar?style=flat-square&color=0a0a0c)](https://github.com/steipete/CodexBar/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/steipete/CodexBar/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-steipete%2Ftap%2Fcodexbar-orange?style=flat-square)](https://github.com/steipete/homebrew-tap)
[![AUR](https://img.shields.io/aur/version/codexbar-cli?style=flat-square&color=1793d1)](https://aur.archlinux.org/packages/codexbar-cli)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)
[![Site](https://img.shields.io/badge/site-codexbar.app-16d3b4?style=flat-square)](https://codexbar.app)

<a href="https://codexbar.app"><img src="docs/social.png" alt="CodexBar — every AI coding limit in your menu bar. 61 providers." width="100%" /></a>

Tiny macOS 14+ menu bar app that keeps **AI coding-provider limits visible** and shows when each window resets. Codex, OpenAI, Claude, Cursor, Gemini, Copilot, Grok, GroqCloud, ElevenLabs, Deepgram, z.ai, MiniMax, Kiro, Zed, Vertex AI, Augment, OpenRouter, LiteLLM, LLM Proxy, Codebuff, Command Code, ClinePass, AWS Bedrock, and many newer coding providers. One status item per provider, or Merge Icons mode with a provider switcher. No Dock icon, minimal UI, dynamic bar icons.

<img src="docs/codexbar.png" alt="CodexBar menu popover with provider tiles, usage bars, and reset countdowns" width="520" />

## 第一章：本机 WSL 部署与配置（Fork）

本 fork 在 Windows + WSL2（Ubuntu 24.04）下把 `CodexBarCLI` 部署为终端用量看板，并对卡片渲染做了少量改动（见下文"Fork 改动"）。

### 目录约定

- 源码仓库：`E:\CodexBar`（WSL 内为 `/mnt/e/CodexBar`）
- 运行时根目录：`D:\CodexBar`（WSL 内为 `/mnt/d/CodexBar`），结构如下：

```
D:\CodexBar
├── bin\codexbar          # 启动器：设置环境变量与代理后 exec 对应版本的 CodexBarCLI
├── app\v<版本>[-fork]\   # 各版本的 CodexBarCLI 二进制 + VERSION
├── config\config.json    # CODEXBAR_CONFIG（provider 开关、API key）
├── codex-home\           # CODEX_HOME
├── cache\ data\ tmp\     # XDG_CACHE_HOME / XDG_DATA_HOME / TMPDIR
```

`bin/codexbar` 会在未设置代理时自动使用 Windows 宿主机代理 `http://<宿主IP>:7897`（可用 `CODEXBAR_PROXY_PORT` 覆盖）。

### 从源码构建并部署（WSL）

一次性准备（安装系统依赖需 sudo；Swift 工具链装到 `~/swift`，不需要 sudo）：

```bash
sudo apt-get install -y binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 \
  libgcc-13-dev libpython3-dev libsqlite3-0 libsqlite3-dev libstdc++-13-dev \
  libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev
bash /mnt/e/CodexBar/Scripts/wsl/install-swift.sh
```

每次改完代码后构建 + 部署（源码会先 rsync 到 WSL 原生文件系统再编译，避免 drvfs 拖慢构建）：

```bash
bash /mnt/e/CodexBar/Scripts/wsl/deploy.sh          # 默认部署到 /mnt/d/CodexBar
```

脚本会把产物装到 `app/v<版本>-fork/` 并自动把 `bin/codexbar` 指向新版本。

### 终端看板（cardswatch）

`~/.bashrc` 中的 `cardswatch` 函数每隔 N 秒重新拉取一次卡片（通过 pty 保留 truecolor）：

```bash
cardswatch() {
    local interval="${1:-60}" out
    shift 2>/dev/null
    while :; do
        out=$(script -qec "codexbar cards $*" /dev/null)
        printf '\e[H\e[2J%s\n' "$out"
        sleep "$interval"
    done
}
```

`codexbar` 需在 PATH 中（如 `ln -s /mnt/d/CodexBar/bin/codexbar ~/.local/bin/codexbar`）。一次完整抓取约 30–50 秒，刷新间隔建议 ≥60 秒。

### Fork 改动（相对上游）

均位于 `Sources/CodexBarCLI/CLIRenderer.swift`，带 `// Fork:` 注释，便于合并上游：

1. Codex 卡片列出每张 Limit Reset Credit 的到期时间（`Reset 1: 7/27 08:02`）。
2. Claude 卡片渲染模型限定的额外窗口（如 Fable 周额度），标签取自窗口标题（"Fable only" → "Fable"）。
3. Claude 主窗口标签 `Session` → `5h`。
4. z.ai 三个窗口按 Token-Tracker 顺序显示：`5h` → `Weekly` → `Tools`。
5. Codex 卡片默认不再显示 `Credits` 行（Limit Reset Credits 保留）。
6. 构建/部署脚本：`Scripts/wsl/install-swift.sh`、`Scripts/wsl/deploy.sh`。

## Why

- **Plan around resets.** Per-provider session, weekly, and monthly windows with countdowns to the next reset — stop guessing whether to start that long task.
- **Credits, spend, and cost scans.** Credit balances, Admin API spend dashboards, provider billing summaries, and local cost scans where the source exposes enough detail.
- **Live status.** Provider status polling surfaces incident badges in the menu and an indicator overlay on the bar icon.
- **Privacy-first.** Reuses existing provider sessions — OAuth, device flow, API keys, browser cookies, local files — so no passwords are stored.

## Install

### Requirements
- macOS 14+ (Sonoma)

### GitHub Releases
Download: <https://github.com/steipete/CodexBar/releases>

### Homebrew
```bash
brew install --cask codexbar
```

### CLI Tarballs (macOS/Linux)
Homebrew formula (Linux today):
```bash
brew install steipete/tap/codexbar
```
Arch Linux AUR package:
```bash
yay -S codexbar-cli
```
Or download release tarballs from GitHub Releases:
- macOS: `CodexBarCLI-v<tag>-macos-arm64.tar.gz`, `CodexBarCLI-v<tag>-macos-x86_64.tar.gz`
- Linux (glibc): `CodexBarCLI-v<tag>-linux-aarch64.tar.gz`, `CodexBarCLI-v<tag>-linux-x86_64.tar.gz`
- Linux (static musl): `CodexBarCLI-v<tag>-linux-musl-aarch64.tar.gz`, `CodexBarCLI-v<tag>-linux-musl-x86_64.tar.gz`

### First run
- Open Settings → Providers and enable what you use.
- Install/sign in to the provider sources you rely on: CLIs, browser sessions, OAuth/device flow, API keys, local app files, or provider apps depending on the provider.
- Optional: Settings → Providers → Codex → OpenAI cookies (Automatic or Manual) to add dashboard extras.

### Set API keys from the CLI
Provider toggles and API keys live in the resolved CodexBar config file. New installs use
`~/.config/codexbar/config.json`; existing `~/.codexbar/config.json` installs still load from the legacy path. You can
script the same provider list that Settings → Providers uses:

```bash
codexbar config providers
codexbar config enable --provider grok
codexbar config disable --provider cursor
```

For API-key providers, store a key without opening Settings:

```bash
printf '%s' "$ELEVENLABS_API_KEY" | codexbar config set-api-key --provider elevenlabs --stdin
```

`set-api-key` trims the piped value, stores it with restrictive config-file permissions, and enables the provider by default. Use `--no-enable` to only save the key, or `--api-key <key>` for one-off local scripts where shell history is not a concern.
See [CLI configuration](docs/cli-configuration.md) for the full flow.

## Providers

- [Codex](docs/codex.md) — OAuth API or local Codex CLI, plus optional OpenAI web dashboard extras.
- [OpenAI](docs/openai.md) — Admin API key usage/cost graphs with legacy credit-balance fallback.
- [Azure OpenAI](docs/azure-openai.md) — API key, endpoint, and deployment validation probe.
- [Claude](docs/claude.md) — OAuth API, browser cookies, or CLI PTY fallback; session and weekly usage where available.
- [Cursor](docs/cursor.md) — Browser session cookies for plan + usage + billing resets.
- [OpenCode](docs/opencode.md) — Browser cookies for workspace subscription usage.
- [OpenCode Go](docs/opencode.md) — Browser or local SQLite data for Go usage windows.
- [Alibaba Coding Plan](docs/alibaba-coding-plan.md) — Web cookies or API key for coding-plan quotas.
- [Alibaba Token Plan](docs/alibaba-token-plan.md) — Bailian browser/manual cookies for token-plan credits.
- [Gemini](docs/gemini.md) — OAuth-backed quota API using Gemini CLI credentials (no browser cookies).
- [Antigravity](docs/antigravity.md) — Local language server probe (experimental); no external auth.
- [Droid](docs/factory.md) — Browser cookies + WorkOS token flows for Factory usage + billing.
- [Copilot](docs/copilot.md) — GitHub device flow + Copilot internal usage API.
- [Devin](docs/devin.md) — Chrome localStorage session or manual Bearer token for daily and weekly quotas.
- [z.ai](docs/zai.md) — API token for personal/team quota, MCP, 5-hour, and hourly usage windows.
- [Manus](docs/manus.md) — Browser `session_id` auth for credit balance, monthly credits, and daily refresh tracking.
- [MiniMax](docs/minimax.md) — API token, cookie header, or browser cookies for coding-plan usage.
- [T3 Chat](docs/t3chat.md) — Browser cookies capture for Base and Overage usage buckets.
- [Kimi](docs/kimi.md) — Auth token (JWT from `kimi-auth` cookie) for weekly quota + 5‑hour rate limit.
- [Kilo](docs/kilo.md) — API token with CLI-auth fallback for Kilo Pass usage.
- [Kiro](docs/kiro.md) — CLI-based usage; monthly credits + bonus credits.
- [Vertex AI](docs/vertexai.md) — Google Cloud gcloud OAuth with token cost tracking from local Claude logs.
- [Augment](docs/augment.md) — Augment CLI or browser cookies for credits tracking and usage monitoring.
- [Amp](docs/amp.md) — Browser cookie-based authentication with Amp Free usage tracking.
- [Ollama](docs/ollama.md) — API key access plus browser cookies for Ollama Cloud usage windows.
- [Synthetic](docs/synthetic.md) — API key quota endpoint for rolling five-hour, weekly token, and search-hourly usage.
- [JetBrains AI](docs/jetbrains.md) — Local XML-based quota from JetBrains IDE configuration; monthly credits tracking.
- [Warp](docs/warp.md) — API token for GraphQL request limits and monthly credits.
- [ElevenLabs](docs/elevenlabs.md) — API key for character credits and voice slot usage.
- [OpenRouter](docs/openrouter.md) — API token for credit-based usage tracking across multiple AI providers.
- [Windsurf](docs/windsurf.md) — Browser localStorage session import or local SQLite cache for plan usage.
- [Zed](docs/zed.md) — Zed editor Keychain session for plan, edit-prediction quota, billing cycle, and overdue invoices.
- [Perplexity](docs/perplexity.md) — Account usage credits from Perplexity usage data.
- [Xiaomi MiMo](docs/mimo.md) — Browser cookies for balance and token-plan usage.
- [Doubao](docs/doubao.md) — API key for Volcengine Ark request-limit probes.
- [Sakana AI](docs/sakana.md) — Manual Cookie header for 5-hour and weekly quota windows.
- [Abacus AI](docs/abacus.md) — Browser cookie auth for ChatLLM/RouteLLM compute credit tracking.
- [Mistral](docs/mistral.md) — Browser cookies for API spend, credit balance, and monthly-plan usage.
- [DeepSeek](docs/deepseek.md) — API key for credit balance tracking (paid vs. granted breakdown).
- [Moonshot / Kimi API](docs/moonshot.md) — API key for Moonshot/Kimi API account balance tracking.
- [Venice](docs/venice.md) — API key for DIEM or USD balance tracking.
- [Codebuff](docs/codebuff.md) — API token (or `~/.config/manicode/credentials.json`) for credit balance + weekly rate limit.
- [Crof](docs/crof.md) — API key for dollar credit balance and request quota tracking.
- [Command Code](docs/command-code.md) — Browser or manual cookies for monthly USD credits from Command Code billing.
- [Qoder](docs/qoder.md) — Browser or manual cookies for Qoder big model credit usage.
- [StepFun](docs/stepfun.md) — Username + password login for Step Plan rate limits (5‑hour + weekly windows) and subscription plan name.
- [AWS Bedrock](docs/bedrock.md) — AWS access keys or a named AWS profile (SSO/assume-role via the AWS CLI) for Cost Explorer spend, monthly budgets, and optional CloudWatch Claude activity.
- [Grok](docs/grok.md) — Grok CLI billing RPC plus grok.com browser-session fallback.
- [GroqCloud](docs/groqcloud.md) — API key for Enterprise Prometheus request/token/cache-hit metrics.
- [LLM Proxy](docs/llm-proxy.md) — API key + base URL for aggregate proxy quota stats and provider breakdowns.
- [ClawRouter](docs/clawrouter.md) — API key for monthly budget, spend, requests, tokens, and routed-provider usage.
- [sub2api](docs/sub2api.md) — Self-hosted gateway key quota, subscription limits, wallet balance, and per-key usage.
- [Wayfinder](docs/wayfinder.md) — Local router gateway polling for health, per-route breakdown, savings, and decision latency.
- [LiteLLM](docs/litellm.md) — Virtual key + proxy URL for personal and team budget/spend tracking.
- [Deepgram](docs/deepgram.md) — API key usage summaries across speech, agent, token, and TTS metrics.
- [Poe](docs/poe.md) — API key for current point balance and recent points history.
- [Chutes](docs/chutes.md) — API key for subscription usage, rolling and monthly quota windows, and pay-as-you-go quotas.
- [Neuralwatt](docs/neuralwatt.md) — API key for subscription kWh usage and prepaid credit balance.
- [ZenMux](docs/zenmux.md) — Management API key for rolling five-hour and seven-day quota windows plus PAYG balance.
- Open to new providers: [provider authoring guide](docs/provider.md).

## Icon & Screenshot
The menu bar icon is a tiny usage meter. Bar meaning is provider-specific, and errors/stale data can dim the icon or
show an incident indicator.

## Features
- Multi-provider menu bar with per-provider toggles (Settings → Providers).
- Provider-specific usage meters with reset countdowns.
- Optional Codex web dashboard enrichments (code review remaining, usage breakdown, credits history).
- Inline spend and usage charts for API-backed providers such as OpenAI, Claude Admin API, OpenRouter, LiteLLM, z.ai, MiniMax, Mistral, and AWS Bedrock.
- Configurable cost-usage scans for Codex + Claude, plus reused chart UI for supported provider histories.
- A persistent Settings → Usage & Spend view for local 7/30-day estimates, grouped by native currency and limited to providers that expose cost history.
- Provider status polling with incident badges in the menu and icon overlay.
- Merge Icons mode to combine providers into one status item + switcher.
- Display controls for provider icons, labels, bars, reset-time style, and highest-usage auto-selection.
- Refresh cadence presets (manual, 1m, 2m, 5m, 15m).
- Bundled CLI (`codexbar`) for scripts and CI (including `codexbar cost --provider codex`, `claude`, or `both` for local cost usage); macOS and Linux CLI builds available.
- WidgetKit widgets for supported providers.
- Localized app and website with a shared 21-language catalog, automatic website detection, persistent pickers, and RTL support.
- Optional session quota notifications and weekly-reset confetti.
- Privacy-first: on-device parsing by default; browser cookies are opt-in and reused (no passwords stored).

## Privacy note
Wondering if CodexBar scans your disk? It doesn’t crawl your filesystem; it reads a small set of known locations (browser cookies/local storage, provider config files, local JSONL logs) when the related features are enabled. Provider tokens and token-account settings live in the CodexBar config file with restrictive file permissions. See the discussion and audit notes in [issue #12](https://github.com/steipete/CodexBar/issues/12).

## macOS permissions (why they’re needed)
- **Full Disk Access (optional)**: only required to read Safari cookies/local storage for web-based providers. If you don’t grant it, use another supported browser, manual cookies/API keys, OAuth, or CLI/local sources where that provider supports them.
- **Keychain access (prompted by macOS)**:
  - Chromium cookie import needs the browser “Safe Storage” key to decrypt cookies.
  - Claude OAuth bootstrap may read the Claude CLI Keychain item when CodexBar has no usable cached credentials.
  - CodexBar may use Keychain for browser cookie decryption, cached cookie headers, and OAuth/device-flow credentials where those sources require it.
  - **How do I prevent those keychain alerts?**
    - Open **Keychain Access.app** → login keychain → search the prompted item (for Claude OAuth, usually “Claude Code-credentials”).
    - Open the item → **Access Control** → add `CodexBar.app` under “Always allow access by these applications”.
    - Prefer adding just CodexBar (avoid “Allow all applications” unless you want it wide open).
    - Relaunch CodexBar after saving.
    - Reference screenshot: ![Keychain access control](docs/keychain-allow.png)
  - **How to do the same for the browser?**
    - Find the browser’s “Safe Storage” key (e.g., “Chrome Safe Storage”, “Brave Safe Storage”, “Microsoft Edge Safe Storage”).
    - Open the item → **Access Control** → add `CodexBar.app` under “Always allow access by these applications”.
    - This removes the prompt when CodexBar decrypts cookies for that browser.
  - **Last resort — stop all Keychain reads entirely**: if "Always Allow" doesn't stick (e.g., macOS resets the ACL after a Chromium update or a `partition_id` reset), open **CodexBar → Settings → Advanced → Keychain access** and enable **Disable Keychain access**. CodexBar will no longer touch the Keychain. Browser-cookie-based providers will be skipped, but Claude/Codex OAuth via the CLI still works (it reads `~/.codex` / `~/.claude` config files, not the Keychain).
  - **Prompt after uninstall?** Deleting the app prevents a new launch from that bundle, but an already-running CodexBar process can keep requesting Keychain access until it quits. Check for that process, a Login Item, another installed copy, or a prompt that names a different requesting binary/path. See [Keychain prompt troubleshooting](docs/keychain-prompts.md) for safe checks and what to include in a support report without sharing secrets.
- **Files & Folders prompts (folder/volume access)**: CodexBar launches provider CLIs and local probes for some providers. If those helpers read a project directory or external drive, macOS may ask CodexBar for that folder/volume (e.g., Desktop or an external volume). This is driven by the helper’s working directory, not background disk scanning.
- **What we do not request in the background**: no Screen Recording or Accessibility permissions; user-triggered helper actions may ask macOS for Automation permission to open Terminal. No passwords are stored (browser cookies are reused when you opt in).

## Docs
- Providers overview: [docs/providers.md](docs/providers.md)
- Provider authoring: [docs/provider.md](docs/provider.md)
- Issue labeling guide: [docs/ISSUE_LABELING.md](docs/ISSUE_LABELING.md)
- UI & icon notes: [docs/ui.md](docs/ui.md)
- CLI reference: [docs/cli.md](docs/cli.md)
- Configuration: [docs/configuration.md](docs/configuration.md)
- Keychain prompts: [docs/keychain-prompts.md](docs/keychain-prompts.md)
- CLI configuration: [docs/cli-configuration.md](docs/cli-configuration.md)
- Widgets: [docs/widgets.md](docs/widgets.md)
- Architecture: [docs/architecture.md](docs/architecture.md)
- Refresh loop: [docs/refresh-loop.md](docs/refresh-loop.md)
- Status polling: [docs/status.md](docs/status.md)
- Sparkle updates: [docs/sparkle.md](docs/sparkle.md)
- Packaging: [docs/packaging.md](docs/packaging.md)
- Development: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- Release checklist: [docs/RELEASING.md](docs/RELEASING.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)

## Getting started (dev)
- Clone the repo and open it in Xcode or run the scripts directly.
- Launch once, then toggle providers in Settings → Providers.
- Install/sign in to provider sources you rely on (CLIs, browser cookies, OAuth/device flow, API keys, or local app/config files).
- Optional: set OpenAI cookies (Automatic or Manual) for Codex dashboard extras.

## Build from source
Requires macOS 14+ and Swift 6.2+.

```bash
./Scripts/package_app.sh        # builds CodexBar.app in-place with ad-hoc signing
open CodexBar.app
```

Dev loop:
```bash
./Scripts/compile_and_run.sh
./Scripts/compile_and_run.sh --test  # also run the sharded test suite before packaging/relaunching
make check                           # SwiftFormat + SwiftLint
make docs-list                       # list docs with frontmatter summaries
```

CLI install:
```bash
# after installing CodexBar.app in /Applications
./bin/install-codexbar-cli.sh
```

## Related
- ✂️ [Trimmy](https://github.com/steipete/Trimmy) — “Paste once, run once.” Flatten multi-line shell snippets so they paste and run.
- 🧳 [MCPorter](https://mcporter.dev) — TypeScript toolkit + CLI for Model Context Protocol servers.
- 🧿 [oracle](https://askoracle.dev) — Ask the oracle when you're stuck. Invoke GPT-5 Pro with a custom context and files.

## Looking for a Windows version?
- [Win-CodexBar](https://github.com/Finesssee/Win-CodexBar)

## Linux desktop integration?
- [codexbar-waybar](https://github.com/Marouan-chak/codexbar-waybar) — Waybar custom module + GTK4 popover for Hyprland / Sway / other Wayland compositors, built on top of the bundled Linux CLI.
- [Codexbar GNOME](https://extensions.gnome.org/extension/9841/codexbar/) — GNOME Shell extension that brings CodexBar usage into the desktop panel.
- [codexbar-cinnamon-applet](https://github.com/jacobcalvert/codexbar-cinnamon-applet) — Linux Mint Cinnamon panel applet powered by CodexBar's JSON output.
- [noctalia-codex-usage](https://github.com/rayoplateado/noctalia-codex-usage) — Noctalia/Quickshell plugin that shows Codex 5-hour and weekly usage limits, built on top of the bundled Linux CLI.
- [KodexBar](https://github.com/tylxr59/KodexBar) — KDE Plasma widget that shows CodexBar usage in the Plasma panel, built on top of the bundled Linux CLI.
- [codexbar-plasmoid](https://github.com/psimaker/codexbar-plasmoid) — KDE Plasma 6 widget for CodexBar's meter icon, provider switcher, quota windows, pace, credits, local cost, and status, powered by the bundled Linux CLI.

## Status bar & terminal integration
- [showy-quota](https://github.com/enieuwy/showy-quota) — always-on AI plan quota strips for SketchyBar, tmux, and Zellij (standalone WASM plugin), built on `codexbar serve` / the bundled CLI.

## Credits
Inspired by [ccusage](https://github.com/ryoppippi/ccusage) (MIT), specifically the cost usage tracking.

## License
MIT • Peter Steinberger ([steipete](https://twitter.com/steipete))
