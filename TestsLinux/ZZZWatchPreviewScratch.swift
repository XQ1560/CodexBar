import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

#if os(Linux)
struct ZZZWatchPreviewScratch {
    private static func slot(_ dayKey: String, _ total: Int, in i: Int, out o: Int, read r: Int, write w: Int, today: Bool = false) -> CostUsageDaySlot {
        CostUsageDaySlot(
            dayKey: dayKey, date: Date(timeIntervalSince1970: 0),
            totalTokens: total, inputTokens: i, outputTokens: o, cacheReadTokens: r, cacheCreationTokens: w,
            costUSD: Double(total) / 100_000, isToday: today, isFuture: false)
    }

    @Test
    func `preview week and heatmap`() {
        let week = [
            Self.slot("2026-07-13", 3_200_000, in: 400_000, out: 300_000, read: 2_400_000, write: 100_000),
            Self.slot("2026-07-14", 8_100_000, in: 900_000, out: 700_000, read: 6_300_000, write: 200_000),
            Self.slot("2026-07-15", 5_000_000, in: 600_000, out: 500_000, read: 3_800_000, write: 100_000, today: true),
            CostUsageDaySlot(dayKey: "2026-07-16", date: Date(timeIntervalSince1970: 0), totalTokens: nil, costUSD: nil, isToday: false, isFuture: true),
            CostUsageDaySlot(dayKey: "2026-07-17", date: Date(timeIntervalSince1970: 0), totalTokens: nil, costUSD: nil, isToday: false, isFuture: true),
            CostUsageDaySlot(dayKey: "2026-07-18", date: Date(timeIntervalSince1970: 0), totalTokens: nil, costUSD: nil, isToday: false, isFuture: true),
            CostUsageDaySlot(dayKey: "2026-07-19", date: Date(timeIntervalSince1970: 0), totalTokens: nil, costUSD: nil, isToday: false, isFuture: true),
        ]
        print("\n===== WEEK (no color) =====")
        for line in CLIWatchTrendRenderer.renderWeek(title: "Claude · this week", slots: week, height: 8, useColor: false, enhanced: false) {
            print(line)
        }

        // 26-week grid with some activity, narrow width forces band wrapping.
        var grid: [[CostUsageDaySlot]] = []
        for wk in 0..<26 {
            var col: [CostUsageDaySlot] = []
            for d in 0..<7 {
                let t = ((wk * 7 + d) % 9) * 400_000
                col.append(Self.slot("2026-\(String(format: "%02d", (wk / 4) + 1))-\(String(format: "%02d", d + 1))", t, in: t / 5, out: t / 6, read: t * 2 / 3, write: t / 20))
            }
            grid.append(col)
        }
        print("\n===== HEATMAP width=48 (wraps into bands) =====")
        for line in CLIWatchTrendRenderer.renderHeatmap(title: "Codex + Claude · usage heatmap", grid: grid, width: 48, useColor: false, enhanced: false) {
            print(line)
        }
    }
}
#endif
