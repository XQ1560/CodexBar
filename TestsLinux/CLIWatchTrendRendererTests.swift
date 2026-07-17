import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

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
    func `week view renders title bars and labels`() {
        let lines = CLIWatchTrendRenderer.renderWeek(
            title: "Claude · this week", slots: Self.weekSlots(),
            height: 8, useColor: false, enhanced: false)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("Claude · this week"))
        #expect(joined.contains("Mon"))
        #expect(joined.contains("Sun"))
        #expect(joined.contains("07-14"))
        #expect(joined.contains("tokens")) // total appended to the title
        #expect(joined.contains("in ") && joined.contains("out ")) // breakdown line
    }

    @Test
    func `heatmap renders weekday labels legend and summary`() {
        let grid = (0..<13).map { week in
            (0..<7).map { day in Self.slot("2026-04-\(String(format: "%02d", (week % 4) + day + 1))", tokens: (week * 7 + day) * 1000) }
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
        let slots = [
            Self.slot("2026-07-13", tokens: 300, input: 100, output: 50, cacheRead: 150, cacheCreation: 0),
            Self.slot("2026-07-14", tokens: 200, input: 80, output: 40, cacheRead: 80, cacheCreation: 0, today: true),
        ]
        let lines = CLIWatchTrendRenderer.renderWeek(
            title: "Claude · this week", slots: slots, height: 6, useColor: false, enhanced: false)
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
    func `color and no-color renders keep identical visible width`() {
        let slots = Self.weekSlots()
        let plain = CLIWatchTrendRenderer.renderWeek(
            title: "T", slots: slots, height: 8, useColor: false, enhanced: false)
        let colored = CLIWatchTrendRenderer.renderWeek(
            title: "T", slots: slots, height: 8, useColor: true, enhanced: true)
        #expect(plain.count == colored.count)
        for (plainLine, coloredLine) in zip(plain, colored) {
            #expect(CLIWatchText.visibleWidth(plainLine) == CLIWatchText.visibleWidth(coloredLine))
        }
    }

    @Test
    func `thirty day view falls back to sparkline when narrow`() {
        let slots = (0..<30).map { Self.slot("2026-06-\(String(format: "%02d", ($0 % 28) + 1))", tokens: $0 * 1000) }
        let narrow = CLIWatchTrendRenderer.renderThirtyDays(
            title: "30d", slots: slots, width: 40, height: 8, useColor: false, enhanced: false)
        // Title (with total) + one sparkline row + blank + breakdown line.
        #expect(narrow.contains { $0.contains("30d") })
        #expect(narrow.contains { $0.contains("cache-hit") })
        let wide = CLIWatchTrendRenderer.renderThirtyDays(
            title: "30d", slots: slots, width: 100, height: 8, useColor: false, enhanced: false)
        #expect(wide.count > narrow.count)
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
}
#endif
