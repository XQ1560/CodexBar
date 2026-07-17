// Fork: the interactive `cards --watch` loop. Fetches on a fixed-delay timer in the
// background (so the ~30-50s fetch never blocks keys), switches views instantly from
// cache, and persists token history to SQLite each refresh.

import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    /// Providers that expose local token history (used for the trend/heatmap views + SQLite).
    static let watchCostProviders: Set<UsageProvider> = [.claude, .codex]
    /// How many days of history a refresh pulls — enough to fill the 26-week heatmap once
    /// SQLite has accumulated that much (the live log scan is bounded by log retention).
    static let watchHistoryDays = 183
    static let watchHeatmapWeeks = 26
    static let watchMinInterval = 60

    static func runCardsWatch(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let interval = Self.decodeWatchInterval(values, output: output)
        let plan = Self.makeCardsRunPlan(values)

        guard CLIWatchTerminal.isInteractive else {
            Self.exit(
                code: .failure,
                message: "Error: --watch requires an interactive terminal.",
                output: output,
                kind: .args)
        }

        // On Ctrl-C / SIGTERM / SIGHUP: restore the terminal first, then reraise.
        let signalMonitor = CLITerminationSignalMonitor { signalNumber in
            CLIWatchTerminal.restore()
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signalNumber)
        }
        defer { signalMonitor.cancel() }

        guard CLIWatchTerminal.enter() else {
            Self.exit(
                code: .failure,
                message: "Error: could not switch the terminal into raw mode.",
                output: output,
                kind: .runtime)
        }
        defer { CLIWatchTerminal.restore() }

        await Self.watchLoop(plan: plan, interval: interval)
    }

    /// Validates `--interval`: default 60, and refuses anything below 60 (a single fetch
    /// takes ~30-50s, so a shorter interval would overlap fetches).
    static func decodeWatchInterval(_ values: ParsedValues, output: CLIOutputPreferences) -> Int {
        guard let raw = values.options["interval"]?.last else { return Self.watchMinInterval }
        guard let parsed = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            Self.exit(
                code: .failure,
                message: "Error: --interval must be an integer number of seconds.",
                output: output,
                kind: .args)
        }
        if parsed < Self.watchMinInterval {
            Self.exit(
                code: .failure,
                message: "Error: --interval must be at least \(Self.watchMinInterval) seconds "
                    + "(a single fetch takes ~30-50s).",
                output: output,
                kind: .args)
        }
        return parsed
    }

    // MARK: - Event loop

    private static func watchLoop(plan: CardsRunPlan, interval: Int) async {
        let (stream, continuation) = AsyncStream<WatchEvent>.makeStream()
        let input = CLIWatchInput { event in continuation.yield(event) }
        defer {
            input.stop()
            continuation.finish()
        }

        var cache = WatchDataCache()
        var view = WatchViewState()

        func beginRefresh() {
            guard !cache.isFetching else { return }
            cache.isFetching = true
            cache.fetchStartedAt = Date()
            Task {
                let payload = await Self.performRefresh(plan: plan)
                continuation.yield(.refreshCompleted(payload))
            }
        }

        beginRefresh()
        Self.draw(plan: plan, cache: cache, view: view, interval: interval)

        for await event in stream {
            switch event {
            case let .key(byte):
                switch CLIWatchKeymap.handleKey(byte, view: view) {
                case .quit:
                    return
                case .refresh:
                    beginRefresh()
                case let .update(newView):
                    view = newView
                case .ignored:
                    continue
                }
            case .tick:
                cache.spinnerFrame &+= 1
                if !cache.isFetching, let next = cache.nextRefreshAt, Date() >= next {
                    beginRefresh()
                }
            case let .refreshCompleted(payload):
                cache.isFetching = false
                cache.latest = payload
                cache.lastError = nil
                cache.nextRefreshAt = payload.fetchedAt.addingTimeInterval(TimeInterval(interval))
            case let .refreshFailed(message):
                cache.isFetching = false
                cache.lastError = message
                cache.nextRefreshAt = Date().addingTimeInterval(TimeInterval(interval))
            case .resize:
                break
            }
            Self.draw(plan: plan, cache: cache, view: view, interval: interval)
        }
    }

    // MARK: - Data refresh

    /// One refresh pass: cards + token history, run concurrently. The token history is
    /// persisted to SQLite and merged with stored history so trends can outlive the log window.
    static func performRefresh(plan: CardsRunPlan) async -> WatchPayload {
        let start = Date()
        async let cardsResult = Self.fetchCardsOnce(plan: plan)
        let costProviders = plan.providerList.filter { Self.watchCostProviders.contains($0) }
        let dailyByProvider = await Self.fetchAndMergeTokenHistory(providers: costProviders)
        let cards = await cardsResult
        return WatchPayload(
            cards: cards.cards,
            failures: cards.failures,
            dailyByProvider: dailyByProvider,
            fetchedAt: Date(),
            duration: Date().timeIntervalSince(start))
    }

    private static func fetchAndMergeTokenHistory(
        providers: [UsageProvider]) async -> [UsageProvider: [CostUsageDailyReport.Entry]]
    {
        // Fork: demo injection — fake multi-provider, multi-model data so the stacked
        // trend views can be eyeballed without real credentials. Remove by clearing
        // CODEXBAR_WATCH_DEMO. Never touches the SQLite store.
        if Self.shouldInjectDemoData() {
            return Self.demoTokenHistory(for: providers)
        }
        guard !providers.isEmpty else { return [:] }
        let store = CostUsageSQLiteStore.defaultStore()
        let fetcher = CostUsageFetcher()
        var result: [UsageProvider: [CostUsageDailyReport.Entry]] = [:]
        // Fork: heatmap must cover every provider that ever wrote rows, not just the
        // currently-enabled set, so scan the SQLite store for all known providers first.
        let storedProviders = (try? store.allStoredProviders()) ?? []
        let providersToScan = Array(Set(providers + storedProviders)).sorted { $0.rawValue < $1.rawValue }
        for provider in providersToScan {
            do {
                let snapshot = try await fetcher.loadTokenSnapshot(
                    provider: provider,
                    forceRefresh: false,
                    historyDays: Self.watchHistoryDays,
                    refreshPricingInBackground: false)
                try? store.upsertDailyEntries(snapshot.daily, provider: provider)
                result[provider] = store.mergedDailyEntries(provider: provider, snapshotEntries: snapshot.daily)
            } catch {
                // Fall back to whatever history is already on disk.
                if let stored = try? store.loadDailyRows(provider: provider), !stored.isEmpty {
                    result[provider] = stored.map(\.asDailyEntry)
                }
            }
        }
        return result
    }

    // MARK: - Frame rendering

    private static func draw(plan: CardsRunPlan, cache: WatchDataCache, view: WatchViewState, interval: Int) {
        let (rows, cols) = CLIWatchTerminal.size()
        let bodyHeight = max(1, rows - 1)
        var body = Self.composeBody(plan: plan, cache: cache, view: view, cols: cols, height: bodyHeight)

        if view.helpVisible {
            body = Self.overlayHelp(base: bodyHeight, cols: cols, interval: interval)
        }

        var frame = ""
        for index in 0..<bodyHeight {
            let line = index < body.count ? body[index] : ""
            frame += line + "\u{001B}[K"
            if index < bodyHeight - 1 { frame += "\r\n" }
        }
        // Status bar occupies the final row.
        let status = Self.statusBar(
            cache: cache, view: view, cols: cols, interval: interval, monthDays: plan.monthDays)
        frame += "\r\n" + status + "\u{001B}[K"
        CLIWatchTerminal.render(frame)
    }

    private static func composeBody(
        plan: CardsRunPlan, cache: WatchDataCache, view: WatchViewState,
        cols: Int, height: Int) -> [String]
    {
        guard let payload = cache.latest else {
            return ["", "  Fetching usage… (first refresh can take 30-50s)"]
        }
        switch view.current {
        case .cards:
            let rendered = Self.renderCardsOutput(
                cards: payload.cards, failures: payload.failures, plan: plan, terminalWidth: cols)
            return rendered.isEmpty ? ["", "  No cards to display."] : rendered.components(separatedBy: "\n")
        case .week:
            return Self.composeStackedTrend(payload: payload, plan: plan, cols: cols, height: height, kind: .week)
        case .thirtyDays:
            return Self.composeStackedTrend(payload: payload, plan: plan, cols: cols, height: height, kind: .thirtyDays)
        case .heatmap:
            return Self.composeHeatmap(payload: payload, plan: plan, cols: cols)
        }
    }

    /// A single GitHub-style heatmap combining every provider's token history (one graph, not
    /// one per provider). Same-day entries from different providers are summed by the bucketer.
    private static func composeHeatmap(payload: WatchPayload, plan: CardsRunPlan, cols: Int) -> [String] {
        let useColor = plan.useColor
        let enhanced = CLITerminalCapabilities.supportsEnhancedCards(useColor: useColor)
        // Fork: heatmap covers every provider with token history, not just the plan's set.
        let providers = Self.activeTrendProviders(payload: payload, plan: plan)
        guard !providers.isEmpty else {
            return ["", "  No token history yet. Use Claude Code or Codex, then wait for a refresh."]
        }
        let combined = providers.flatMap { payload.dailyByProvider[$0] ?? [] }
        let names = providers
            .map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
            .joined(separator: " + ")
        let grid = CostUsageTrendBuckets.weekGridSlots(
            entries: combined, weeks: Self.watchHeatmapWeeks, endingAt: Date())
        return CLIWatchTrendRenderer.renderHeatmap(
            title: "\(names) · usage heatmap", grid: grid, width: cols,
            useColor: useColor, enhanced: enhanced)
    }

    /// Fork: one combined trend chart across every provider that has token history in the
    /// window. Each day is a single stacked column (per-provider colored band); a legend
    /// and a per-provider × per-model breakdown table follow the chart. Never one chart
    /// per provider.
    private static func composeStackedTrend(
        payload: WatchPayload, plan: CardsRunPlan, cols: Int, height: Int,
        kind: WatchViewKind) -> [String]
    {
        let useColor = plan.useColor
        let enhanced = CLITerminalCapabilities.supportsEnhancedCards(useColor: useColor)

        // Providers that actually have entries in the window, in the plan's order, then any
        // extra providers the SQLite store knows about (so the heatmap stays complete).
        let activeProviders = Self.activeTrendProviders(payload: payload, plan: plan)
        guard !activeProviders.isEmpty else {
            return ["", "  No token history yet. Use Claude Code or Codex, then wait for a refresh."]
        }

        let perProvider: [UsageProvider: [CostUsageDailyReport.Entry]] = Dictionary(
            uniqueKeysWithValues: activeProviders.map { ($0, payload.dailyByProvider[$0] ?? []) })
        let totals = CostUsageStackedAggregator.allProviderTotals(
            perProvider: perProvider, providers: activeProviders)
        guard !totals.isEmpty else {
            return ["", "  No token history yet. Use Claude Code or Codex, then wait for a refresh."]
        }

        let barHeight = min(10, max(4, height / 3))
        switch kind {
        case .week:
            let slots = CostUsageStackedBuckets.naturalWeekSlots(
                perProvider: perProvider, providers: activeProviders, containing: Date())
            return CLIWatchTrendRenderer.renderWeek(
                title: "this week", slots: slots, totals: totals,
                height: barHeight, width: cols, useColor: useColor, enhanced: enhanced)
        case .thirtyDays:
            // Fork: month view day count is configurable via --month (default 15). Wider
            // windows wrap into bands at narrow terminal widths (see daysPerBand).
            let monthDays = plan.monthDays
            let slots = CostUsageStackedBuckets.trailingDaySlots(
                perProvider: perProvider, providers: activeProviders, days: monthDays, endingAt: Date())
            return CLIWatchTrendRenderer.renderThirtyDays(
                title: "last \(monthDays) days", slots: slots, totals: totals, width: cols,
                height: barHeight, useColor: useColor, enhanced: enhanced)
        default:
            return []
        }
    }

    /// Providers to include in a trend view: the plan's providers that have entries, plus
    /// any provider the payload carries that the plan didn't list (heatmap completeness).
    static func activeTrendProviders(payload: WatchPayload, plan: CardsRunPlan) -> [UsageProvider] {
        var ordered = plan.providerList.filter { provider in
            (payload.dailyByProvider[provider] ?? []).contains { Self.hasUsage($0) }
        }
        for provider in payload.dailyByProvider.keys where !ordered.contains(provider) {
            if (payload.dailyByProvider[provider] ?? []).contains(where: Self.hasUsage(_:)) {
                ordered.append(provider)
            }
        }
        return ordered
    }

    private static func hasUsage(_ entry: CostUsageDailyReport.Entry) -> Bool {
        (entry.totalTokens ?? 0) > 0
            || (entry.inputTokens ?? 0) > 0
            || (entry.outputTokens ?? 0) > 0
            || (entry.costUSD ?? 0) > 0
    }

    // MARK: - Fork: demo data injection

    /// True when CODEXBAR_WATCH_DEMO is set to a truthy value. Lets the trend views be
    /// eyeballed with fabricated multi-provider data without real credentials.
    static func shouldInjectDemoData(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        guard let raw = environment["CODEXBAR_WATCH_DEMO"]?.lowercased() else { return false }
        return !["0", "false", "no", "off", ""].contains(raw)
    }

    /// Fabricated per-provider daily history with realistic per-model breakdowns, spanning
    /// the last ~40 days so the 30-day view and heatmap both show content. Pure function
    /// of the current date so frames are stable within a run.
    static func demoTokenHistory(for providers: [UsageProvider]) -> [UsageProvider: [CostUsageDailyReport.Entry]] {
        // Always show a fixed cast: Claude + Codex + Cursor regardless of the enabled set,
        // so the stacked chart has multiple colored bands.
        let cast: [UsageProvider] = [.claude, .codex, .cursor]
        var result: [UsageProvider: [CostUsageDailyReport.Entry]] = [:]
        let calendar = Self.demoCalendar
        let today = calendar.startOfDay(for: Date())
        for provider in cast {
            let entries = (0..<40).map { dayOffset -> CostUsageDailyReport.Entry in
                let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) ?? today
                return Self.demoEntry(provider: provider, date: date, dayOffset: dayOffset)
            }
            result[provider] = entries
        }
        _ = providers
        return result
    }

    private static let demoCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private static func demoEntry(provider: UsageProvider, date: Date, dayOffset: Int) -> CostUsageDailyReport.Entry {
        let dayKey = Self.demoDayKey(date)
        // Weekly-ish pattern: weekday peaks, weekend dip. Today partial. Seeded per day.
        let weekday = Self.demoCalendar.component(.weekday, from: date) // 1=Sun..7=Sat
        let weekend = weekday == 1 || weekday == 7
        let todayFactor = dayOffset == 0 ? 0.35 : 1.0
        let weekendFactor = weekend ? 0.25 : 1.0
        let wave = 1.0 + 0.3 * sin(Double(dayOffset) * 0.7) // slow oscillation
        let base = 1_000_000.0 * weekendFactor * todayFactor * wave

        let (input, output, cacheRead, cacheWrite, models) = Self.demoShape(
            provider: provider, base: base, dayOffset: dayOffset)
        let total = input + output + cacheRead + cacheWrite
        let cost = Self.demoCost(provider: provider, total: total)
        return CostUsageDailyReport.Entry(
            date: dayKey,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            totalTokens: total,
            requestCount: max(1, Int(total / 50_000)),
            costUSD: cost,
            modelsUsed: models.map(\.name),
            modelBreakdowns: models.map { breakdown in
                CostUsageDailyReport.ModelBreakdown(
                    modelName: breakdown.name,
                    costUSD: breakdown.cost,
                    totalTokens: breakdown.tokens,
                    requestCount: max(1, Int(breakdown.tokens / 50_000)))
            })
    }

    private static func demoDayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Self.demoCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Per-provider token component split + per-model shape for a base token volume.
    private static func demoShape(
        provider: UsageProvider,
        base: Double,
        dayOffset: Int) -> (input: Int, output: Int, cacheRead: Int, cacheWrite: Int,
            models: [(name: String, tokens: Int, cost: Double)])
    {
        switch provider {
        case .claude:
            // Cache-heavy coding workflow.
            let cacheRead = Int(base * 2.4)
            let cacheWrite = Int(base * 0.25)
            let input = Int(base * 0.6)
            let output = Int(base * 0.45)
            let sonnet = Int(Double(input + output) * 0.7)
            let haiku = (input + output) - sonnet
            let models: [(name: String, tokens: Int, cost: Double)] = [
                ("claude-sonnet", sonnet, Double(sonnet) / 3_000_000 * 15.0),
                ("claude-haiku", haiku, Double(haiku) / 3_000_000 * 0.75),
            ]
            return (input, output, cacheRead, cacheWrite, models)
        case .codex:
            // More output-heavy.
            let cacheRead = Int(base * 1.3)
            let cacheWrite = Int(base * 0.15)
            let input = Int(base * 0.5)
            let output = Int(base * 0.8)
            let gpt5 = Int(Double(input + output) * 0.8)
            let gpt5mini = (input + output) - gpt5
            let models: [(name: String, tokens: Int, cost: Double)] = [
                ("gpt-5-codex", gpt5, Double(gpt5) / 3_000_000 * 10.0),
                ("gpt-5-mini", gpt5mini, Double(gpt5mini) / 3_000_000 * 1.25),
            ]
            return (input, output, cacheRead, cacheWrite, models)
        case .cursor:
            // Lighter usage, mostly output.
            let cacheRead = Int(base * 0.3)
            let cacheWrite = Int(base * 0.05)
            let input = Int(base * 0.2)
            let output = Int(base * 0.4)
            let models: [(name: String, tokens: Int, cost: Double)] = [
                ("cursor-small", (input + output), Double(input + output) / 3_000_000 * 0.5),
            ]
            return (input, output, cacheRead, cacheWrite, models)
        default:
            let input = Int(base * 0.4)
            let output = Int(base * 0.4)
            let models: [(name: String, tokens: Int, cost: Double)] = [
                ("model-a", (input + output), Double(input + output) / 3_000_000 * 5.0),
            ]
            return (input, output, Int(base * 0.2), Int(base * 0.05), models)
        }
    }

    private static func demoCost(provider: UsageProvider, total: Int) -> Double {
        let perMillion: Double
        switch provider {
        case .claude: perMillion = 8.0
        case .codex: perMillion = 6.0
        case .cursor: perMillion = 1.0
        default: perMillion = 4.0
        }
        return Double(total) / 1_000_000.0 * perMillion
    }

    private static func overlayHelp(base bodyHeight: Int, cols: Int, interval: Int) -> [String] {
        let help = CLIWatchTrendRenderer.helpOverlayLines(interval: interval)
        let boxWidth = help.map(\.count).max() ?? 0
        let leftPad = max(0, (cols - boxWidth) / 2)
        let topPad = max(0, (bodyHeight - help.count) / 2)
        var lines = Array(repeating: "", count: bodyHeight)
        for (offset, helpLine) in help.enumerated() {
            let row = topPad + offset
            guard row < bodyHeight else { break }
            lines[row] = String(repeating: " ", count: leftPad) + helpLine
        }
        return lines
    }

    private static func statusBar(
        cache: WatchDataCache, view: WatchViewState, cols: Int, interval: Int, monthDays: Int) -> String
    {
        let seconds = cache.nextRefreshAt.map { Int($0.timeIntervalSinceNow.rounded()) }
        let info = WatchStatusInfo(
            view: view.current,
            isFetching: cache.isFetching,
            lastFetchedAt: cache.latest?.fetchedAt,
            lastDuration: cache.latest?.duration,
            secondsUntilRefresh: cache.isFetching ? nil : seconds,
            spinnerFrame: cache.spinnerFrame,
            lastError: cache.lastError,
            monthDays: monthDays)
        return CLIWatchStatusBar.render(
            info: info, width: cols, useColor: view.helpVisible ? false : true,
            timeString: { Self.watchClockFormatter.string(from: $0) })
    }

    private static let watchClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
