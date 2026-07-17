import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

#if os(Linux)
struct CLIWatchTrendRendererTests {
    private static func slot(
        _ dayKey: String, tokens: Int?,
        input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheCreation: Int? = nil,
        today: Bool = false, future: Bool = false) -> CostUsageDaySlot
    {
        CostUsageDaySlot(
            dayKey: dayKey,
            date: Date(timeIntervalSince1970: 0),
            totalTokens: tokens,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            costUSD: tokens.map { Double($0) / 1000 },
            isToday: today,
            isFuture: future)
    }

    private static func weekSlots() -> [CostUsageDaySlot] {
        [
            slot("2026-07-13", tokens: 3_200_000),
            slot("2026-07-14", tokens: 8_100_000),
            slot("2026-07-15", tokens: 5_000_000, today: true),
            slot("2026-07-16", tokens: nil, future: true),
            slot("2026-07-17", tokens: nil, future: true),
            slot("2026-07-18", tokens: nil, future: true),
            slot("2026-07-19", tokens: nil, future: true),
        ]
    }

    // MARK: - Fork: stacked fixtures

    private static func segment(
        _ provider: UsageProvider, tokens: Int,
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
        cost: Double = 0) -> CostUsageStackedSegment
    {
        CostUsageStackedSegment(
            provider: provider,
            totalTokens: tokens,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            costUSD: cost)
    }

    /// Two providers (Claude + Codex) with overlapping activity so the stacked bars show
    /// more than one colored band per day.
    private static func stackedWeekSlots() -> [CostUsageStackedDaySlot] {
        let keys = ["2026-07-13", "2026-07-14", "2026-07-15", "2026-07-16",
                    "2026-07-17", "2026-07-18", "2026-07-19"]
        return keys.enumerated().map { index, key in
            let isToday = index == 2
            let isFuture = index >= 3
            let segments: [CostUsageStackedSegment]
            if isFuture {
                segments = [.claude, .codex].map { Self.segment($0, tokens: 0) }
            } else {
                segments = [
                    Self.segment(.claude, tokens: 2_000_000 + index * 100_000,
                                 input: 400_000, output: 300_000, cacheRead: 1_200_000, cacheWrite: 100_000,
                                 cost: Double(index) + 1),
                    Self.segment(.codex, tokens: 1_000_000 + index * 50_000,
                                 input: 200_000, output: 400_000, cacheRead: 350_000, cacheWrite: 50_000,
                                 cost: Double(index) + 0.5),
                ]
            }
            return CostUsageStackedDaySlot(
                dayKey: key, date: Date(timeIntervalSince1970: 0),
                segments: segments, isToday: isToday, isFuture: isFuture)
        }
    }

    private static func weekTotals() -> [CostUsageStackedProviderTotals] {
        [
            Self.makeTotals(provider: .claude, tokens: 8_400_000, models: [
                ("claude-sonnet", 6_000_000, 18.0, 60),
                ("claude-haiku", 2_400_000, 0.6, 40),
            ]),
            Self.makeTotals(provider: .codex, tokens: 3_900_000, models: [
                ("gpt-5-codex", 3_120_000, 10.4, 50),
                ("gpt-5-mini", 780_000, 0.3, 20),
            ]),
        ]
    }

    private static func makeTotals(
        provider: UsageProvider, tokens: Int,
        models: [(name: String, tokens: Int, cost: Double, reqs: Int)]) -> CostUsageStackedProviderTotals
    {
        var totals = CostUsageStackedProviderTotals(provider: provider)
        totals.totalTokens = tokens
        totals.costUSD = models.map(\.cost).reduce(0, +)
        totals.requestCount = models.map(\.reqs).reduce(0, +)
        totals.models = models.map {
            var model = CostUsageModelBreakdownTotals(provider: provider, modelName: $0.name)
            model.totalTokens = $0.tokens
            model.costUSD = $0.cost
            model.requestCount = $0.reqs
            return model
        }
        return totals
    }

    @Test
    func `quantile thresholds and heat levels bucket correctly`() {
        let values = [10, 20, 30, 40, 50, 60, 70, 80]
        let thresholds = CLIWatchTrendRenderer.quantileThresholds(values)
        #expect(thresholds.count == 3)

        // Zero is always level 0.
        #expect(CLIWatchTrendRenderer.heatLevel(for: 0, thresholds: thresholds) == 0)
        // A value above all thresholds is the max level (4).
        #expect(CLIWatchTrendRenderer.heatLevel(for: 1000, thresholds: thresholds) == 4)
        // A tiny non-zero value is at least level 1.
        #expect(CLIWatchTrendRenderer.heatLevel(for: 1, thresholds: thresholds) == 1)
    }

    @Test
    func `heat level is 1 when there are no thresholds`() {
        #expect(CLIWatchTrendRenderer.heatLevel(for: 5, thresholds: []) == 1)
        #expect(CLIWatchTrendRenderer.heatLevel(for: 0, thresholds: []) == 0)
    }

    @Test
    func `empty data yields no thresholds`() {
        #expect(CLIWatchTrendRenderer.quantileThresholds([0, 0, 0]).isEmpty)
        #expect(CLIWatchTrendRenderer.quantileThresholds([]).isEmpty)
    }

    @Test
    func `vertical bar is full at max and empty at zero`() {
        let full = CLIWatchTrendRenderer.verticalBar(value: 100, max: 100, height: 4)
        #expect(full == ["█", "█", "█", "█"])
        let empty = CLIWatchTrendRenderer.verticalBar(value: 0, max: 100, height: 4)
        #expect(empty == [" ", " ", " ", " "])
        // Half height fills the bottom half.
        let half = CLIWatchTrendRenderer.verticalBar(value: 50, max: 100, height: 4)
        #expect(half[0] == " " && half[3] == "█")
    }

    @Test
    func `week view renders title bars labels legend and breakdown`() {
        let stacked = Self.stackedWeekSlots()
        let lines = CLIWatchTrendRenderer.renderWeek(
            title: "Claude · this week", slots: stacked, totals: Self.weekTotals(),
            height: 8, width: 120, useColor: false, enhanced: false)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("Claude · this week"))
        #expect(joined.contains("Mon"))
        #expect(joined.contains("Sun"))
        #expect(joined.contains("07-14"))
        #expect(joined.contains("tokens")) // total appended to the title
        #expect(joined.contains("in ") && joined.contains("out ")) // breakdown line
        #expect(joined.contains("legend:")) // per-provider legend
        #expect(joined.contains("breakdown:")) // per-model detail table
    }

    @Test
    func `heatmap renders weekday labels legend and summary`() {
        let grid = (0..<13).map { week in
            (0..<7).map { day in
                let key = "2026-04-\(String(format: "%02d", (week % 4) + day + 1))"
                return Self.slot(key, tokens: (week * 7 + day) * 1000)
            }
        }
        let lines = CLIWatchTrendRenderer.renderHeatmap(
            title: "Claude heatmap", grid: grid, width: 80, useColor: false, enhanced: false)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("Claude heatmap"))
        #expect(joined.contains("Mon"))
        #expect(joined.contains("Fri"))
        #expect(joined.contains("Less"))
        #expect(joined.contains("More"))
        #expect(joined.contains("active days"))
    }

    @Test
    func `heatmap wraps columns into bands when narrow instead of dropping weeks`() {
        let grid = (0..<26).map { _ in (0..<7).map { _ in Self.slot("2026-07-13", tokens: 1000) } }
        // width 24: leftMargin 4 + cellWidth 2 → 10 columns per band → 26 weeks needs 3 bands.
        let lines = CLIWatchTrendRenderer.renderHeatmap(
            title: "x", grid: grid, width: 24, useColor: false, enhanced: false)
        // The heatmap grid rows (weekday-labeled bands) fit the width; only the free-text
        // legend/breakdown lines may run longer.
        let gridRows = lines.filter { line in
            ["Mon ", "Wed ", "Fri ", "Sun "].contains { line.hasPrefix($0) }
        }
        for line in gridRows {
            #expect(CLIWatchText.visibleWidth(line) <= 24)
        }
        // Multiple bands: the "Mon" weekday label appears once per band (26 weeks / 10 = 3 bands).
        let monBands = lines.filter { $0.hasPrefix("Mon ") }.count
        #expect(monBands >= 3)
    }

    @Test
    func `week view shows the total in the title and an input output cache breakdown`() {
        let stacked: [CostUsageStackedDaySlot] = [
            .init(dayKey: "2026-07-13", date: Date(timeIntervalSince1970: 0),
                  segments: [
                      Self.segment(.claude, tokens: 300,
                                   input: 100, output: 50, cacheRead: 150, cacheWrite: 0, cost: 0.3),
                  ], isToday: false, isFuture: false),
            .init(dayKey: "2026-07-14", date: Date(timeIntervalSince1970: 0),
                  segments: [
                      Self.segment(.claude, tokens: 200,
                                   input: 80, output: 40, cacheRead: 80, cacheWrite: 0, cost: 0.2),
                  ], isToday: true, isFuture: false),
        ]
        let totals: [CostUsageStackedProviderTotals] = [
            Self.makeTotals(provider: .claude, tokens: 500, models: [
                ("claude-sonnet", 500, 0.5, 5),
            ]),
        ]
        let lines = CLIWatchTrendRenderer.renderWeek(
            title: "Claude · this week", slots: stacked, totals: totals,
            height: 6, width: 120, useColor: false, enhanced: false)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("Claude · this week · 500 tokens")) // total in title
        #expect(joined.contains("in 180"))
        #expect(joined.contains("out 90"))
        #expect(joined.contains("cache-hit 230"))
    }

    @Test
    func `total falls back to component sum when totalTokens is nil`() {
        // A slot with no explicit total but populated components still counts.
        let slots = [Self.slot("2026-07-13", tokens: nil, input: 100, output: 50, cacheRead: 20)]
        let totals = CostUsageTokenTotals.from(slots: slots)
        #expect(totals.inputTokens == 100)
        #expect(totals.outputTokens == 50)
        #expect(totals.cacheReadTokens == 20)
    }

    @Test
    func `color and no-color stacked renders keep identical visible width`() {
        let stacked = Self.stackedWeekSlots()
        let totals = Self.weekTotals()
        let plain = CLIWatchTrendRenderer.renderWeek(
            title: "T", slots: stacked, totals: totals, height: 8, width: 120, useColor: false, enhanced: false)
        let colored = CLIWatchTrendRenderer.renderWeek(
            title: "T", slots: stacked, totals: totals, height: 8, width: 120, useColor: true, enhanced: true)
        #expect(plain.count == colored.count)
        for (plainLine, coloredLine) in zip(plain, colored) {
            #expect(CLIWatchText.visibleWidth(plainLine) == CLIWatchText.visibleWidth(coloredLine))
        }
    }

    @Test
    func `daysPerBand fits all days on a wide terminal and wraps on a narrow one`() {
        // dayWidth 7, 15 days: a 120-col terminal fits all 15 in one band.
        #expect(CLIWatchTrendRenderer.daysPerBand(dayWidth: 7, width: 120, dayCount: 15) == 15)
        // dayWidth 7, 15 days, narrow 40-col terminal: (40-2)/7 = 5 → minimum 5 per band.
        #expect(CLIWatchTrendRenderer.daysPerBand(dayWidth: 7, width: 40, dayCount: 15) == 5)
        // dayWidth 7, only 7 days: never returns more than the day count.
        #expect(CLIWatchTrendRenderer.daysPerBand(dayWidth: 7, width: 200, dayCount: 7) == 7)
    }

    @Test
    func `thirty day view wraps into multiple bands when narrow and one band when wide`() {
        let keys = (0..<15).map { offset in
            "2026-06-\(String(format: "%02d", (offset % 28) + 1))"
        }
        let stacked = keys.map { key in
            CostUsageStackedDaySlot(
                dayKey: key, date: Date(timeIntervalSince1970: 0),
                segments: [Self.segment(.claude, tokens: 1_000_000)], isToday: false, isFuture: false)
        }
        let totals: [CostUsageStackedProviderTotals] = [
            Self.makeTotals(provider: .claude, tokens: 15_000_000, models: [("claude-sonnet", 15_000_000, 45.0, 150)]),
        ]
        // Narrow width → multiple bands → more lines than a single-band wide render.
        let narrow = CLIWatchTrendRenderer.renderThirtyDays(
            title: "15d", slots: stacked, totals: totals, width: 24, height: 8, useColor: false, enhanced: false)
        #expect(narrow.contains { $0.contains("15d") })
        #expect(narrow.contains { $0.contains("cache-hit") })
        let wide = CLIWatchTrendRenderer.renderThirtyDays(
            title: "15d", slots: stacked, totals: totals, width: 120, height: 8, useColor: false, enhanced: false)
        // Narrow view wraps (more bands → more bar rows); wide fits one band (fewer rows).
        #expect(narrow.count > wide.count)
    }

    @Test
    func `help overlay lists every binding`() {
        let lines = CLIWatchTrendRenderer.helpOverlayLines(interval: 60)
        let joined = lines.joined(separator: "\n")
        for hint in ["cards view", "weekly token trend", "30-day token trend", "usage heatmap", "refresh now", "quit"] {
            #expect(joined.contains(hint))
        }
        #expect(joined.contains("60s"))
    }

    // MARK: - Fork: stacked rendering unit tests

    private static func rgbEqual(
        _ lhs: (r: Int, g: Int, b: Int)?,
        _ rhs: (r: Int, g: Int, b: Int)?) -> Bool
    {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (l?, r?): l.r == r.r && l.g == r.g && l.b == r.b
        default: false
        }
    }

    @Test
    func `provider palette assigns distinct colors to first providers`() {
        let palette = CLIWatchTrendRenderer.providerPalette(for: [.claude, .codex, .cursor])
        #expect(palette.count == 3)
        #expect(!Self.rgbEqual(palette[.claude], palette[.codex]))
        #expect(!Self.rgbEqual(palette[.codex], palette[.cursor]))
    }

    @Test
    func `provider palette falls back for extras beyond the swatch range`() {
        // More providers than palette slots: the last one must use the fallback color.
        let paletteSize = CLIWatchTrendRenderer.providerPaletteRGB.count
        var providers: [UsageProvider] = []
        // Reuse distinct enum cases cyclically; what matters is the count exceeds the palette.
        let pool: [UsageProvider] = [.claude, .codex, .cursor, .gemini, .copilot,
                                     .vertexai, .bedrock, .openai, .grok, .groq,
                                     .mistral, .deepseek, .kimi, .kiro, .zed]
        for index in 0..<(paletteSize + 3) {
            providers.append(pool[index % pool.count])
        }
        let palette = CLIWatchTrendRenderer.providerPalette(for: providers)
        // The last provider in the list is beyond the palette → fallback color.
        let last = providers.last!
        #expect(Self.rgbEqual(palette[last], CLIWatchTrendRenderer.providerFallbackRGB))
    }

    @Test
    func `distribute eighths sums exactly to the requested total`() {
        let segments = [10, 20, 30, 5]
        let total = 40
        let distributed = CLIWatchTrendRenderer.distributeEighths(segments: segments, total: total)
        #expect(distributed.reduce(0, +) == total)
        // Larger values get at least as many eighths as smaller ones.
        #expect(distributed[2] >= distributed[0])
    }

    @Test
    func `grouped day column paints nothing for a future day`() {
        let future = CostUsageStackedDaySlot(
            dayKey: "2026-07-20", date: Date(timeIntervalSince1970: 0),
            segments: [Self.segment(.claude, tokens: 0)], isToday: false, isFuture: true)
        let palette = CLIWatchTrendRenderer.providerPalette(for: [.claude])
        let layout = CLIWatchTrendRenderer.groupedBarLayout(providerCount: 1, compactDayGap: true)
        let column = CLIWatchTrendRenderer.groupedDayColumn(
            slot: future, providers: [.claude],
            maxValue: 1_000_000, palette: palette,
            height: 5, layout: layout, useColor: false, enhanced: false)
        #expect(column.count == 5)
        // Future day → every row is blank (spaces only).
        #expect(column.allSatisfy { $0.allSatisfy { $0 == " " } })
    }

    @Test
    func `grouped day column renders one bar per provider side by side`() {
        let slot = CostUsageStackedDaySlot(
            dayKey: "2026-07-14", date: Date(timeIntervalSince1970: 0),
            segments: [
                Self.segment(.claude, tokens: 500_000),
                Self.segment(.codex, tokens: 500_000),
            ], isToday: false, isFuture: false)
        let palette = CLIWatchTrendRenderer.providerPalette(for: [.claude, .codex])
        let layout = CLIWatchTrendRenderer.groupedBarLayout(providerCount: 2, compactDayGap: true)
        let column = CLIWatchTrendRenderer.groupedDayColumn(
            slot: slot, providers: [.claude, .codex],
            maxValue: 1_000_000, palette: palette,
            height: 8, layout: layout, useColor: false, enhanced: false)
        #expect(column.count == 8)
        // Both providers at half of the shared max → bottom rows carry full blocks.
        #expect(column.contains { $0.contains("█") })
        // Each row's visible width = 2 bars (compact day gap 0, inner gap 0 → bars touch).
        for row in column {
            #expect(CLIWatchText.visibleWidth(row) == 2)
        }
    }

    @Test
    func `global max is the single peak across every provider and day`() {
        let slots = [
            CostUsageStackedDaySlot(
                dayKey: "2026-07-13", date: Date(timeIntervalSince1970: 0),
                segments: [Self.segment(.claude, tokens: 100), Self.segment(.codex, tokens: 1_000)],
                isToday: false, isFuture: false),
            CostUsageStackedDaySlot(
                dayKey: "2026-07-14", date: Date(timeIntervalSince1970: 0),
                segments: [Self.segment(.claude, tokens: 500), Self.segment(.codex, tokens: 10)],
                isToday: false, isFuture: false),
        ]
        // Global max = 1000 (codex on day 1), not per-provider peaks.
        #expect(CLIWatchTrendRenderer.globalMax(slots: slots) == 1_000)
    }

    @Test
    func `legend line names every provider in the totals list`() {
        let totals = Self.weekTotals()
        let palette = CLIWatchTrendRenderer.providerPalette(for: [.claude, .codex])
        let lines = CLIWatchTrendRenderer.providerLegend(
            totals: totals, palette: palette, useColor: false, enhanced: false)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("Claude"))
        #expect(joined.contains("Codex"))
    }

    @Test
    func `breakdown table lists each provider and its models`() {
        let totals = Self.weekTotals()
        let lines = CLIWatchTrendRenderer.modelBreakdownTable(
            totals: totals, useColor: false, enhanced: false)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("breakdown:"))
        #expect(joined.contains("claude-sonnet"))
        #expect(joined.contains("claude-haiku"))
        #expect(joined.contains("gpt-5-codex"))
        #expect(joined.contains("gpt-5-mini"))
    }

    @Test
    func `heatmap ramp runs from dark green to bright mocha green`() {
        let bottom = CLIWatchTrendRenderer.heatGreenRGB(level: 1)
        let top = CLIWatchTrendRenderer.heatGreenRGB(level: 4)
        // Level 1 = dark green-gray #475951; level 4 = bright Mocha green #a6e3a1.
        #expect(bottom.r == 71 && bottom.g == 89 && bottom.b == 81)
        #expect(top.r == 166 && top.g == 227 && top.b == 161)
    }

    @Test
    func `grouped bar layout touches bars within a day and gaps days`() {
        // 2 providers, full day gap: 2 bars + 0 inner gap + 2-col day gap = 4.
        let two = CLIWatchTrendRenderer.groupedBarLayout(providerCount: 2, compactDayGap: false)
        #expect(two.innerGap == 0)
        #expect(two.dayGap == 2)
        #expect(two.dayWidth == 4)
        // Compact layout drops the day gap: 2 bars + 0 inner gap = 2.
        let compact = CLIWatchTrendRenderer.groupedBarLayout(providerCount: 2, compactDayGap: true)
        #expect(compact.dayWidth == 2)
    }

    @Test
    func `filling layout grows the day gap to span the terminal width`() {
        // 2 providers, 7 days, 120-col terminal.
        // bars/day = 2; usable = 118; bar total = 14; gap budget = 104; per-day gap = 14,
        // clamped to maxDayGap (8). So dayGap = 8, dayWidth = 2 + 8 = 10.
        let fill = CLIWatchTrendRenderer.groupedBarLayoutFilling(
            providerCount: 2, dayCount: 7, width: 120)
        #expect(fill.innerGap == 0) // bars still touch within a day
        #expect(fill.dayGap == CLIWatchTrendRenderer.maxDayGap)
        // dayWidth grew well beyond the fixed-layout 4, giving labels room.
        #expect(fill.dayWidth > 4)
    }

    @Test
    func `filling layout falls back to the base when width is tight`() {
        // 2 providers, 30 days, 40-col terminal → not enough room to grow; day gap stays
        // at the default (the base layout's minimum).
        let fill = CLIWatchTrendRenderer.groupedBarLayoutFilling(
            providerCount: 2, dayCount: 30, width: 40)
        #expect(fill.dayGap == CLIWatchTrendRenderer.defaultDayGap)
    }
}
#endif
