# CodexBar 🎚️ — May your tokens never run out.

> Every AI coding limit, in your menu bar.

[![Latest release](https://img.shields.io/github/v/release/steipete/CodexBar?style=flat-square&color=0a0a0c)](https://github.com/steipete/CodexBar/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/steipete/CodexBar/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-steipete%2Ftap%2Fcodexbar-orange?style=flat-square)](https://github.com/steipete/homebrew-tap)
[![AUR](https://img.shields.io/aur/version/codexbar-cli?style=flat-square&color=1793d1)](https://aur.archlinux.org/packages/codexbar-cli)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)
[![Site](https://img.shields.io/badge/site-codexbar.app-16d3b4?style=flat-square)](https://codexbar.app)

<a href="https://codexbar.app"><img src="docs/social.png" alt="CodexBar — every AI coding limit in your menu bar. 63 providers." width="100%" /></a>

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

> **代理**：脚本会探测 WSL 宿主代理 `http://<宿主IP>:7897`（可用 `CODEXBAR_PROXY_PORT` 覆盖），**只在端口对 WSL 子网开放时才启用，否则自动直连并打印警告**。默认 NAT WSL2 下若 Windows 代理只监听 `127.0.0.1`，请在代理客户端开启 "Allow LAN / 允许局域网连接"，或显式 `export HTTPS_PROXY=...`。
>
> **libncurses**：Ubuntu 24.04 默认只有 wide 版 `libncursesw.so.6`，而 Swift 链接 narrow 版 `libncurses.so.6`。`install-swift.sh` 会在 `~/swift/shims/` 自动建软链，`deploy.sh` 会自动把该目录加到 `LD_LIBRARY_PATH`；手动调用 swift（如 `swift build` / `swift test`）时，请把下面这行加到 `~/.bashrc` 持久生效：
>
> ```bash
> export LD_LIBRARY_PATH="$HOME/swift/shims:${LD_LIBRARY_PATH:-}"
> ```

每次改完代码后构建 + 部署（源码会先 rsync 到 WSL 原生文件系统再编译，避免 drvfs 拖慢构建）：

```bash
bash /mnt/e/CodexBar/Scripts/wsl/deploy.sh          # 默认部署到 /mnt/d/CodexBar
```

脚本会把产物装到 `app/v<版本>-fork/` 并自动把 `bin/codexbar` 指向新版本。

> **不要用管道包裹 deploy.sh**（如 `bash deploy.sh 2>&1 | tail`）：管道会让子 shell 的 `set -e` 失效并吞掉 swift build 的真实退出码，导致"看着成功"的部署实际没装上。直接 `bash deploy.sh`，需要保存日志请用 `bash deploy.sh > deploy.log 2>&1`。

### 首次配置 provider

部署完成后，launcher 默认只启用 Codex（OAuth，无需 API key），其它 provider 全部禁用。首次使用时按需启用：

```bash
codexbar config providers                          # 列出全部 provider 及开关状态
codexbar config enable --provider claude           # 启用 Claude（OAuth，自动登录）
codexbar config enable --provider gemini           # 启用 Gemini
printf '%s' "$GROK_API_KEY" | codexbar config set-api-key --provider grok --stdin   # API-key 类 provider
```

配置写入 `${CODEXBAR_CONFIG}` （即 `D:\CodexBar\config\config.json`）；首次启用任意 provider 后该文件才会创建。各 provider 的鉴权方式见下文 [Providers](#providers) 章节。

### 终端看板（codexbar cards --watch）

内置的交互式全屏看板,按 interval 定时刷新,并用 vim 风格单键在多个视图间即时切换(切换只读缓存,不等待抓取):

```bash
codexbar cards --watch                       # 默认 60s 刷新
codexbar cards --watch --interval 90 --provider all
codexbar cards --watch --month 30            # month 视图显示最近 30 天(默认 15)
```

快捷键:

| 键 | 作用 |
|----|------|
| `w` | 本周 token 趋势(自然周,周一起,每天一根柱) |
| `m` | 最近 N 天 token 趋势(N 由 `--month` 指定,默认 15) |
| `h` | GitHub 风格用量热力图(默认最近 13 周) |
| `r` | 立即刷新(抓取进行中忽略) |
| `?` | 帮助浮层(任意键关闭) |
| `q` / `Ctrl-C` | 退出并恢复终端 |

再次按同一视图键(`w`/`m`/`h`)切回卡片视图。一次完整抓取约 30–50 秒,**倒计时从抓取完成起算**;`--interval` 最小 60 秒,低于则报错退出。原生 TTY 下 truecolor 自动生效,不再需要旧的 `script -qec` pty 包装。

**tmux 下真彩修复**:在 tmux 里运行 watch 时,tmux 默认不认为 `TERM=xterm-256color` 的外层终端(如 WezTerm)支持真彩——该 terminfo 没有 RGB 能力位,实测 `COLORTERM=truecolor` 也不会让 tmux 3.4 自动启用——于是所有 truecolor(`38;2;r;g;b`)在输出给客户端时被降采样成 256 色调色板(如 teal `38;2;90;220;200` → `38;5;80`),柱状渐变出现色带分段、热力图颜色跑偏。修复:在 WSL 的 `~/.tmux.conf` 加一行,然后重启 tmux server(`tmux kill-server` 后重开):

```tmux
set -as terminal-features ",xterm-256color:RGB"
```

验证:tmux 内执行 `tmux display -p '#{client_termfeatures}'`,输出应包含 `RGB`;此后 tmux 内外的 watch 配色完全一致。

token 消耗按天累积写入 `~/.config/codexbar/token-usage.sqlite3`(遵循 `XDG_CONFIG_HOME`)。由于本地会话日志通常只保留约 30 天,该 SQLite 库让趋势与热力图可以增长到超过日志窗口的历史范围,并为后续统计特性留出数据基础。`codexbar cost` 每次运行也会顺带写库。

`codexbar` 需在 PATH 中(如 `ln -s /mnt/d/CodexBar/bin/codexbar ~/.local/bin/codexbar`)。

### Fork 改动（相对上游）

卡片渲染改动位于 `Sources/CodexBarCLI/CLIRenderer.swift`,均带 `// Fork:` 注释,便于合并上游:

1. Codex 卡片列出每张 Limit Reset Credit 的到期时间（`Reset 1: 7/27 08:02`）。
2. Claude 卡片渲染模型限定的额外窗口（如 Fable 周额度），标签取自窗口标题（"Fable only" → "Fable"）。
3. Claude 主窗口标签 `Session` → `5h`。
4. z.ai 三个窗口按 Token-Tracker 顺序显示：`5h` → `Weekly` → `Tools`。
5. Codex 卡片默认不再显示 `Credits` 行（Limit Reset Credits 保留）。

交互式 watch 模式（vim 风格 TUI + 周/月/热力图趋势 + 多 provider 真实 token 历史):

- `Sources/CodexBarCLI/CLIWatchCommand.swift` — 主循环、后台刷新、帧组装、多 provider token 历史聚合。
- `Sources/CodexBarCLI/CLIWatchTerminal.swift` — raw mode / alternate screen / 终端恢复。
- `Sources/CodexBarCLI/CLIWatchInput.swift` — 键盘线程、tick、SIGWINCH。
- `Sources/CodexBarCLI/CLIWatchState.swift` — 视图状态机、键位映射、状态栏(纯逻辑)。
- `Sources/CodexBarCLI/CLIWatchTrendRenderer.swift` — 周柱状图、月视图、GitHub 风格热力图、帮助浮层;三个子视图与 card 模式共用同一视觉体系(圆角全宽卡片容器、紫标题 + 蓝 badge + 金色 TOTAL 头部、card 色系 provider 柱状渐变、teal 热力 ramp、today 紫色高亮)。
- `Sources/CodexBarCore/CostUsageTrendBuckets.swift` — 自然周/滚动 N 天/热力图周网格/堆叠分桶。
- `Sources/CodexBarCore/CostUsageSQLiteStore.swift` — token 用量 SQLite 持久化。
- `Sources/CodexBarCore/ZCodeLocalUsageScanner.swift` — 读取 ZCode (`~/.zcode/cli/agents`) transcript,按 turnId 关联 model + token 用量。
- `Sources/CodexBarCLI/CLICardsCommand.swift` — `runCards` 拆分为 plan/fetch/render + `--watch`/`--interval`/`--month` flag。
- `Sources/CodexBarCLI/CLICostCommand.swift` — cost 命令顺带写入 SQLite。

watch 趋势视图的数据来源(自动探测 Windows 客户端数据,CLI + Desktop 共用同一目录):

| provider | 本地数据路径 | 环境变量覆盖 |
|---|---|---|
| Codex (CLI+Desktop) | `~/.codex/sessions/**/*.jsonl` | `CODEXBAR_LOCAL_CODEX_HOME` |
| Claude (CLI+Desktop) | `~/.claude/projects/**/*.jsonl` | `CODEXBAR_LOCAL_CLAUDE_CONFIG_DIR` |
| ZCode (CLI+Desktop) | `~/.zcode/cli/agents/**/transcript.jsonl` | `ZCODE_HOME` |

`bin/codexbar` 启动器会自动扫描 `/mnt/c/Users/*/` 定位 Windows 用户目录并设置上述变量,使趋势视图直接读取真实 token 历史(无需 API key)。三个产品的 Desktop 都是 CLI 的 Electron/WebView 壳,token 数据统一写入各自的 CLI 目录。

构建/部署脚本：`Scripts/wsl/install-swift.sh`、`Scripts/wsl/deploy.sh`。

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
- [DeepInfra](docs/deepinfra.md) — API key for prepaid balance, current-month spend, and spending-limit tracking.
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
- Fresh installs default to Adaptive refresh. Existing users keep every valid stored choice, while legacy unset or
  invalid preferences resolve to 5 minutes. Manual and fixed 1m, 2m, 5m, 15m, and 30m alternatives remain available.
- Bundled CLI (`codexbar`) for scripts and CI (including `codexbar cost --provider codex`, `claude`, or `both` for local cost usage); macOS and Linux CLI builds available.
- WidgetKit widgets for supported providers.
- Localized app and website with a shared 21-language catalog, automatic website detection, persistent pickers, and RTL support.
- Optional session quota notifications and weekly-reset confetti.
- Privacy-first: on-device parsing by default; browser cookies are opt-in and reused (no passwords stored).

## Privacy note
Wondering if CodexBar scans your disk? It doesn’t crawl your filesystem; it reads a small set of known locations (browser cookies/local storage, provider config files, local JSONL logs) when the related features are enabled. Plain Adaptive refresh never inspects local agent activity. The separate Adaptive (agent-aware) option asks before inspecting the running-process list (including command lines) to identify Codex/Claude and reading bounded known-session metadata. Declining returns to plain Adaptive. When allowed with Agent Sessions hidden, CodexBar retains only the latest activity time and discards session paths and identities. Provider tokens and token-account settings live in the CodexBar config file with restrictive file permissions. See the discussion and audit notes in [issue #12](https://github.com/steipete/CodexBar/issues/12).

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
