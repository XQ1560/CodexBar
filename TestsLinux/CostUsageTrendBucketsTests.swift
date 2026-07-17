import Foundation
import Testing
@testable import CodexBarCore

#if os(Linux)
struct CostUsageTrendBucketsTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private static func entry(_ date: String, tokens: Int?, cost: Double? = nil) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    @Test
    func `natural week starts on Monday and has seven slots`() {
        let wednesday = Self.date(2026, 7, 15)
        let slots = CostUsageTrendBuckets.naturalWeekSlots(
            entries: [Self.entry("2026-07-14", tokens: 100, cost: 2.5)],
            containing: wednesday,
            calendar: Self.calendar)

        #expect(slots.count == 7)
        #expect(slots.map(\.dayKey) == [
            "2026-07-13", "2026-07-14", "2026-07-15", "2026-07-16",
            "2026-07-17", "2026-07-18", "2026-07-19",
        ])
        #expect(slots[1].totalTokens == 100)
        #expect(slots[1].costUSD == 2.5)
        #expect(slots[0].totalTokens == nil)
        #expect(slots[2].isToday)
        #expect(!slots[1].isToday)
        #expect(slots[3].isFuture && slots[6].isFuture)
        #expect(!slots[2].isFuture)
    }

    @Test
    func `slot total falls back to component sum and carries the breakdown`() {
        // Source populated the breakdown but left totalTokens nil.
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-13",
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 30,
            cacheCreationTokens: 5,
            totalTokens: nil,
            requestCount: 1,
            costUSD: 1.0,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let slots = CostUsageTrendBuckets.naturalWeekSlots(
            entries: [entry], containing: Self.date(2026, 7, 15), calendar: Self.calendar)

        #expect(slots[0].dayKey == "2026-07-13")
        #expect(slots[0].totalTokens == 185) // 100 + 50 + 30 + 5
        #expect(slots[0].inputTokens == 100)
        #expect(slots[0].outputTokens == 50)
        #expect(slots[0].cacheReadTokens == 30)
    }

    @Test
    func `sunday belongs to the week that started the previous Monday`() {
        let sunday = Self.date(2026, 7, 19)
        let slots = CostUsageTrendBuckets.naturalWeekSlots(
            entries: [], containing: sunday, calendar: Self.calendar)

        #expect(slots.first?.dayKey == "2026-07-13")
        #expect(slots.last?.dayKey == "2026-07-19")
        #expect(slots.last?.isToday == true)
    }

    @Test
    func `natural week crosses month and year boundaries`() {
        let newYearsDay = Self.date(2026, 1, 1)
        let slots = CostUsageTrendBuckets.naturalWeekSlots(
            entries: [], containing: newYearsDay, calendar: Self.calendar)

        #expect(slots.first?.dayKey == "2025-12-29")
        #expect(slots.last?.dayKey == "2026-01-04")
    }

    @Test
    func `future days stay nil even when entries contain future data`() {
        let wednesday = Self.date(2026, 7, 15)
        let slots = CostUsageTrendBuckets.naturalWeekSlots(
            entries: [Self.entry("2026-07-18", tokens: 999)],
            containing: wednesday,
            calendar: Self.calendar)

        #expect(slots[5].dayKey == "2026-07-18")
        #expect(slots[5].totalTokens == nil)
    }

    @Test
    func `duplicate entries for the same day are summed`() {
        let slots = CostUsageTrendBuckets.naturalWeekSlots(
            entries: [
                Self.entry("2026-07-13", tokens: 100, cost: 1.0),
                Self.entry("2026-07-13T08:00:00Z", tokens: 50, cost: 0.5),
            ],
            containing: Self.date(2026, 7, 15),
            calendar: Self.calendar)

        #expect(slots[0].totalTokens == 150)
        #expect(slots[0].costUSD == 1.5)
    }

    @Test
    func `trailing slots end today and count back inclusively`() {
        let today = Self.date(2026, 7, 15)
        let slots = CostUsageTrendBuckets.trailingDaySlots(
            entries: [Self.entry("2026-06-16", tokens: 42)],
            days: 30,
            endingAt: today,
            calendar: Self.calendar)

        #expect(slots.count == 30)
        #expect(slots.first?.dayKey == "2026-06-16")
        #expect(slots.last?.dayKey == "2026-07-15")
        #expect(slots.first?.totalTokens == 42)
        #expect(slots.last?.isToday == true)
    }

    @Test
    func `concatenated provider entries sum per day in the week grid`() {
        // Combined heatmap: two providers' same-day usage must add up in one grid cell.
        let codex = [Self.entry("2026-07-13", tokens: 100), Self.entry("2026-07-15", tokens: 40)]
        let claude = [Self.entry("2026-07-13", tokens: 25), Self.entry("2026-07-14", tokens: 10)]
        let grid = CostUsageTrendBuckets.weekGridSlots(
            entries: codex + claude, weeks: 1, endingAt: Self.date(2026, 7, 15), calendar: Self.calendar)

        let week = grid[0]
        #expect(week[0].dayKey == "2026-07-13" && week[0].totalTokens == 125) // 100 + 25
        #expect(week[1].dayKey == "2026-07-14" && week[1].totalTokens == 10)
        #expect(week[2].dayKey == "2026-07-15" && week[2].totalTokens == 40)
    }

    @Test
    func `week grid has requested columns of full weeks ending with the current one`() {
        let today = Self.date(2026, 7, 15)
        let grid = CostUsageTrendBuckets.weekGridSlots(
            entries: [Self.entry("2026-04-20", tokens: 7)],
            weeks: 13,
            endingAt: today,
            calendar: Self.calendar)

        #expect(grid.count == 13)
        #expect(grid.allSatisfy { $0.count == 7 })
        #expect(grid.last?.first?.dayKey == "2026-07-13")
        #expect(grid.first?.first?.dayKey == "2026-04-20")
        #expect(grid.first?.first?.totalTokens == 7)
        #expect(grid.last?.contains { $0.isToday } == true)
        // Columns are consecutive Mondays.
        let mondays = grid.compactMap(\.first?.dayKey)
        #expect(mondays == mondays.sorted())
    }
}
#endif
