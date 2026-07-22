import CodexBarCore
import Commander
import Foundation

struct CardsOptions: CommanderParsable {
    private static let sourceHelp: String = {
        #if os(macOS)
        "Data source: auto | web | cli | oauth | api (auto behavior is provider-specific)"
        #else
        "Data source: auto | web | cli | oauth | api (web/auto are macOS only for web-capable providers)"
        #endif
    }()

    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(
        name: .long("provider"),
        help: ProviderHelp.optionHelp)
    var provider: ProviderSelection?

    @Option(name: .long("account"), help: "Token account label to use (from config.json)")
    var account: String?

    @Option(name: .long("account-index"), help: "Token account index (1-based)")
    var accountIndex: Int?

    @Flag(name: .long("all-accounts"), help: "Fetch all token accounts, or all visible Codex accounts")
    var allAccounts: Bool = false

    @Flag(name: .long("no-credits"), help: "Skip Codex credits line")
    var noCredits: Bool = false

    @Flag(name: .long("no-color"), help: "Disable ANSI colors in text output")
    var noColor: Bool = false

    @Flag(name: .long("status"), help: "Fetch and include provider status")
    var status: Bool = false

    @Flag(name: .long("web"), help: "Alias for --source web")
    var web: Bool = false

    @Option(name: .long("source"), help: Self.sourceHelp)
    var source: String?

    @Option(name: .long("web-timeout"), help: "Web fetch timeout (seconds; source=auto or web)")
    var webTimeout: Double?

    @Flag(name: .long("web-debug-dump-html"), help: "Dump HTML snapshots to /tmp when Codex dashboard data is missing")
    var webDebugDumpHtml: Bool = false

    @Flag(name: .long("antigravity-plan-debug"), help: "Emit Antigravity planInfo fields (debug)")
    var antigravityPlanDebug: Bool = false

    @Flag(name: .long("augment-debug"), help: "Emit Augment API responses (debug)")
    var augmentDebug: Bool = false

    @Flag(name: .long("brief"), help: "Compact table layout instead of the card grid")
    var brief: Bool = false

    // Fork: interactive full-screen watch mode (vim-style single keys: w/m/h/r/?/q).
    @Flag(name: .long("watch"), help: "Interactive full-screen watch mode (q quit · r refresh · m month · h heatmap)")
    var watch: Bool = false

    // Fork: refresh interval for --watch (seconds; minimum 60).
    @Option(name: .long("interval"), help: "Watch refresh interval in seconds (default 60, minimum 60)")
    var interval: Int?

    // Fork: number of days the month (`m`) view spans (default 15, minimum 7, maximum 90).
    @Option(name: .long("month"), help: "Month view day count (default 15, minimum 7, maximum 90)")
    var month: Int?
}

// Fork: runCards is split into makeCardsRunPlan / fetchCardsOnce / renderCardsOutput so
// the interactive --watch loop can re-fetch and re-render without re-parsing argv. Plain
// `cards` behavior is unchanged: it just chains the three stages and exits once.
//
// @unchecked Sendable: every stored field is a value type or an already-Sendable fetcher
// (UsageFetcher/ClaudeUsageFetcher/BrowserDetection). The plan is built once and only read
// during the single-flight refresh, so passing it into the refresh Task is race-free.
struct CardsRunPlan: @unchecked Sendable {
    let output: CLIOutputPreferences
    let providerList: [UsageProvider]
    let includeStatus: Bool
    let claudeConfig: ProviderConfig?
    let parsedSourceMode: ProviderSourceMode?
    let tokenSelection: TokenAccountCLISelection
    let tokenContext: TokenAccountCLIContext
    let command: UsageCommandContext
    let useColor: Bool
    let brief: Bool
    let resetStyle: ResetTimeDisplayStyle
    let weeklyWorkDays: Int?
    // Fork: day count for the month (`m`) trend view.
    let monthDays: Int
}

extension CodexBarCLI {
    static func runCards(_ values: ParsedValues) async {
        let plan = Self.makeCardsRunPlan(values)
        let result = await Self.fetchCardsOnce(plan: plan)
        let rendered = Self.renderCardsOutput(
            cards: result.cards,
            failures: result.failures,
            plan: plan,
            terminalWidth: CLICardsRenderer.terminalColumnCount())
        if !rendered.isEmpty {
            print(rendered)
        }
        Self.exit(
            code: result.exitCode,
            output: plan.output,
            kind: result.exitCode == .success ? .runtime : .provider)
    }

    // Fork: argv parsing + context construction (validation errors exit before any TUI starts).
    static func makeCardsRunPlan(_ values: ParsedValues) -> CardsRunPlan {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)
        let provider = Self.decodeProvider(from: values, config: config)
        let includeCredits = !values.flags.contains("noCredits")
        let includeStatus = values.flags.contains("status")
        let sourceModeRaw = values.options["source"]?.last
        let parsedSourceMode = Self.decodeSourceMode(from: values)
        if sourceModeRaw != nil, parsedSourceMode == nil {
            Self.exit(
                code: .failure,
                message: "Error: --source must be auto|web|cli|oauth|api.",
                output: output,
                kind: .args)
        }
        let antigravityPlanDebug = values.flags.contains("antigravityPlanDebug")
        let augmentDebug = values.flags.contains("augmentDebug")
        let webDebugDumpHTML = values.flags.contains("webDebugDumpHtml")
        let webTimeout: TimeInterval
        do {
            webTimeout = try Self.decodeWebTimeout(from: values) ?? 60
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .args)
        }
        let verbose = values.flags.contains("verbose")
        let noColor = values.flags.contains("noColor")
        let useColor = Self.shouldUseColor(noColor: noColor, format: .text)
        let brief = values.flags.contains("brief")
        let resetStyle = Self.resetTimeDisplayStyleFromDefaults()
        let weeklyWorkDays = Self.weeklyProgressWorkDaysFromDefaults()
        let providerList = provider.asList
        let claudeConfig = config.providerConfig(for: .claude)

        let tokenSelection: TokenAccountCLISelection
        do {
            tokenSelection = try Self.decodeTokenAccountSelection(from: values)
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .args)
        }

        if tokenSelection.allAccounts, tokenSelection.label != nil || tokenSelection.index != nil {
            Self.exit(
                code: .failure,
                message: "Error: --all-accounts cannot be combined with --account or --account-index.",
                output: output,
                kind: .args)
        }

        if tokenSelection.usesOverride {
            guard providerList.count == 1 else {
                Self.exit(
                    code: .failure,
                    message: "Error: account selection requires a single provider.",
                    output: output,
                    kind: .args)
            }
            let supportsAllCodexAccounts = providerList[0] == .codex
                && tokenSelection.allAccounts
                && tokenSelection.label == nil
                && tokenSelection.index == nil
            guard supportsAllCodexAccounts || TokenAccountSupportCatalog.support(for: providerList[0]) != nil else {
                Self.exit(
                    code: .failure,
                    message: "Error: \(providerList[0].rawValue) does not support token accounts.",
                    output: output,
                    kind: .args)
            }
        }

        let browserDetection = BrowserDetection()
        let fetcher = UsageFetcher()
        let claudeFetcher = ClaudeUsageFetcher(browserDetection: browserDetection)
        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: tokenSelection,
                config: config,
                verbose: verbose)
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .config)
        }

        let command = UsageCommandContext(
            format: .text,
            includeCredits: includeCredits,
            sourceModeOverride: parsedSourceMode,
            antigravityPlanDebug: antigravityPlanDebug,
            augmentDebug: augmentDebug,
            webDebugDumpHTML: webDebugDumpHTML,
            webTimeout: webTimeout,
            verbose: verbose,
            useColor: useColor,
            resetStyle: resetStyle,
            weeklyWorkDays: weeklyWorkDays,
            jsonOnly: output.jsonOnly,
            includeAllCodexAccounts: tokenSelection.allAccounts && providerList == [.codex],
            fetcher: fetcher,
            claudeFetcher: claudeFetcher,
            browserDetection: browserDetection,
            cardsLayout: true)

        return CardsRunPlan(
            output: output,
            providerList: providerList,
            includeStatus: includeStatus,
            claudeConfig: claudeConfig,
            parsedSourceMode: parsedSourceMode,
            tokenSelection: tokenSelection,
            tokenContext: tokenContext,
            command: command,
            useColor: useColor,
            brief: brief,
            resetStyle: resetStyle,
            weeklyWorkDays: weeklyWorkDays,
            monthDays: Self.decodeMonthDays(values, output: output))
    }

    // Fork: decodes --month (month-view day count). Default 15, range [7, 90]. Anything
    // outside the range or non-integer exits with an args error before the TUI starts.
    static let defaultMonthDays = 15
    static let minMonthDays = 7
    static let maxMonthDays = 90

    static func decodeMonthDays(_ values: ParsedValues, output: CLIOutputPreferences) -> Int {
        guard let raw = values.options["month"]?.last else { return Self.defaultMonthDays }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let parsed = Int(trimmed) else {
            Self.exit(
                code: .failure,
                message: "Error: --month must be an integer number of days.",
                output: output,
                kind: .args)
        }
        if parsed < Self.minMonthDays || parsed > Self.maxMonthDays {
            Self.exit(
                code: .failure,
                message: "Error: --month must be between \(Self.minMonthDays) and \(Self.maxMonthDays) days.",
                output: output,
                kind: .args)
        }
        return parsed
    }

    // Fork: one full provider-fetch pass. Called once by `cards`, repeatedly by `--watch`.
    static func fetchCardsOnce(
        plan: CardsRunPlan) async -> (cards: [CLICardModel], failures: [CLICardFailure], exitCode: ExitCode)
    {
        var cards: [CLICardModel] = []
        var failures: [CLICardFailure] = []
        var exitCode: ExitCode = .success

        for provider in plan.providerList {
            let status = plan.includeStatus ? await Self.fetchStatus(for: provider) : nil
            let claudeSwapEligible = CLIClaudeSwapCards.isEligible(
                provider: provider,
                integrationEnabled: plan.claudeConfig?.claudeSwapEnabled == true,
                hasExplicitAccountSelection: plan.tokenSelection.usesOverride,
                sourceModeOverride: plan.parsedSourceMode)
            let result = await CLIClaudeSwapCards.fetch(
                eligible: claudeSwapEligible,
                executablePath: CLIClaudeSwapCards.executablePath(from: plan.claudeConfig),
                showSingleAccount: plan.claudeConfig?.claudeSwapShowSingleAccount == true,
                renderOptions: CLIClaudeSwapCardsRenderOptions(
                    status: status,
                    useColor: plan.useColor,
                    resetStyle: plan.resetStyle,
                    weeklyWorkDays: plan.weeklyWorkDays,
                    now: Date()),
                ambientFetch: {
                    await ProviderInteractionContext.$current.withValue(.background) {
                        await Self.fetchUsageOutputs(
                            provider: provider,
                            status: status,
                            tokenContext: plan.tokenContext,
                            command: plan.command)
                    }
                })
            if result.exitCode != .success { exitCode = result.exitCode }
            cards.append(contentsOf: result.cards)
            failures.append(contentsOf: result.cardFailures)
        }

        return (cards, failures, exitCode)
    }

    // Fork: render one frame from fetched cards. `terminalWidth` is a parameter so watch
    // can re-render at the current width after a SIGWINCH without re-fetching.
    static func renderCardsOutput(
        cards: [CLICardModel],
        failures: [CLICardFailure],
        plan: CardsRunPlan,
        terminalWidth: Int) -> String
    {
        let enhanced = CLITerminalCapabilities.supportsEnhancedCards(useColor: plan.useColor)
        if plan.brief {
            let rows = CLICardsBriefRenderer.makeRows(cards: cards)
            return CLICardsBriefRenderer.render(
                rows: rows,
                failures: failures,
                terminalWidth: terminalWidth,
                useColor: plan.useColor,
                enhanced: enhanced)
        }
        return CLICardsRenderer.render(
            cards: cards,
            failures: failures,
            terminalWidth: terminalWidth,
            useColor: plan.useColor,
            enhanced: enhanced)
    }
}
