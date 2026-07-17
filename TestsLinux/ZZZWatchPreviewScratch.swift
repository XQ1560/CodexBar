import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

#if os(Linux)
struct ZZZWatchPreviewScratch {
    private static func segment(
        _ provider: UsageProvider, tokens: Int,
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
        cost: Double = 0) -> CostUsageStackedSegment
    {
        CostUsageStackedSegment(
            provider: provider, totalTokens: tokens,
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheCreationTokens: cacheWrite, costUSD: cost)
    }

    private static func stackedWeek() -> [CostUsageStackedDaySlot] {
        let keys = ["2026-07-13", "2026-07-14", "2026-07-15", "2026-07-16",
                    "2026-07-17", "2026-07-18", "2026-07-19"]
        return keys.enumerated().map { index, key in
            let isToday = index == 2
            let isFuture = index >= 3
            let segments: [CostUsageStackedSegment]
            if isFuture {
                segments = [Self.segment(.claude, tokens: 0), Self.segment(.codex, tokens: 0)]
            } else {
                segments = [
                    Self.segment(.claude, tokens: 3_200_000 + index * 800_000,
                                 input: 400_000, output: 300_000, cacheRead: 2_400_000, cacheWrite: 100_000,
                                 cost: Double(index) + 2),
                    Self.segment(.codex, tokens: 1_500_000 + index * 400_000,
                                 input: 200_000, output: 700_000, cacheRead: 550_000, cacheWrite: 50_000,
                                 cost: Double(index) + 1),
                ]
            }
            return CostUsageStackedDaySlot(
                dayKey: key, date: Date(timeIntervalSince1970: 0),
                segments: segments, isToday: isToday, isFuture: isFuture)
        }
    }

    private static func totals() -> [CostUsageStackedProviderTotals] {
        func make(_ provider: UsageProvider, tokens: Int, cost: Double,
                  models: [(String, Int, Double)]) -> CostUsageStackedProviderTotals
        {
            var t = CostUsageStackedProviderTotals(provider: provider)
            t.totalTokens = tokens
            t.costUSD = cost
            t.models = models.map { name, toks, c in
                var m = CostUsageModelBreakdownTotals(provider: provider, modelName: name)
                m.totalTokens = toks
                m.costUSD = c
                return m
            }
            return t
        }
        return [
            make(.claude, tokens: 12_000_000, cost: 36.0, models: [
                ("claude-sonnet", 9_000_000, 27.0),
                ("claude-haiku", 3_000_000, 9.0),
            ]),
            make(.codex, tokens: 5_000_000, cost: 10.0, models: [
                ("gpt-5-codex", 4_000_000, 8.0),
                ("gpt-5-mini", 1_000_000, 2.0),
            ]),
        ]
    }

    @Test
    func `preview stacked week no color`() {
        print("\n===== STACKED WEEK (no color) =====")
        for line in CLIWatchTrendRenderer.renderWeek(
            title: "this week", slots: Self.stackedWeek(), totals: Self.totals(),
            height: 8, width: 120, useColor: false, enhanced: false)
        {
            print(line)
        }
    }

    @Test
    func `preview stacked week with color`() {
        print("\n===== STACKED WEEK (truecolor) =====")
        for line in CLIWatchTrendRenderer.renderWeek(
            title: "this week", slots: Self.stackedWeek(), totals: Self.totals(),
            height: 8, width: 120, useColor: true, enhanced: true)
        {
            print(line)
        }
    }

    @Test
    func `preview thirty days stacked`() {
        let keys = (0..<30).map { offset -> String in
            "2026-06-\(String(format: "%02d", (offset % 28) + 1))"
        }
        let stacked = keys.enumerated().map { index, key in
            CostUsageStackedDaySlot(
                dayKey: key, date: Date(timeIntervalSince1970: 0),
                segments: [
                    Self.segment(.claude, tokens: 1_000_000 + index * 50_000),
                    Self.segment(.codex, tokens: 500_000 + index * 20_000),
                ], isToday: index == 29, isFuture: false)
        }
        print("\n===== STACKED 30D (width=80, no color) =====")
        for line in CLIWatchTrendRenderer.renderThirtyDays(
            title: "last 30 days", slots: stacked, totals: Self.totals(),
            width: 80, height: 8, useColor: false, enhanced: false)
        {
            print(line)
        }
    }
}
#endif
