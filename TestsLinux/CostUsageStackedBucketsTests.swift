import CodexBarCore
import Foundation
import Testing

#if os(Linux)
struct CostUsageStackedBucketsTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func entry(
        _ date: String, tokens: Int?,
        input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil,
        cost: Double? = nil,
        models: [(name: String, tokens: Int, cost: Double)] = []) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            totalTokens: tokens,
            requestCount: nil,
            costUSD: cost,
            modelsUsed: models.map(\.name),
            modelBreakdowns: models.map { name, toks, c in
                CostUsageDailyReport.ModelBreakdown(modelName: name, costUSD: c, totalTokens: toks)
            })
    }

    // MARK: - Stacked bucketing

    @Test
    func `natural week splits each day per provider into segments`() {
        let wednesday = Self.date(2026, 7, 15) // Wednesday
        let perProvider: [UsageProvider: [CostUsageDailyReport.Entry]] = [
            .claude: [Self.entry("2026-07-14", tokens: 100, cost: 1.0)],
            .codex: [Self.entry("2026-07-14", tokens: 40), Self.entry("2026-07-15", tokens: 25)],
        ]
        let slots = CostUsageStackedBuckets.naturalWeekSlots(
            perProvider: perProvider, providers: [.claude, .codex],
            containing: wednesday, calendar: Self.calendar)

        #expect(slots.count == 7)
        #expect(slots.map(\.dayKey) == [
            "2026-07-13", "2026-07-14", "2026-07-15", "2026-07-16",
            "2026-07-17", "2026-07-18", "2026-07-19",
        ])

        // Tuesday 07-14: both providers contributed.
        let tuesday = slots[1]
        #expect(tuesday.segments.count == 2)
        #expect(tuesday.segments[0].provider == .claude && tuesday.segments[0].totalTokens == 100)
        #expect(tuesday.segments[1].provider == .codex && tuesday.segments[1].totalTokens == 40)
        #expect(tuesday.grandTotal == 140)

        // Wednesday 07-15: only codex, today.
        let wed = slots[2]
        #expect(wed.isToday)
        #expect(wed.segments[0].totalTokens == nil) // claude has nothing
        #expect(wed.segments[1].totalTokens == 25)
        #expect(wed.grandTotal == 25)

        // Future days carry nil segments.
        #expect(slots[3].isFuture)
        #expect(slots[3].grandTotal == 0)
    }

    @Test
    func `trailing slots end today and count back inclusively`() {
        let today = Self.date(2026, 7, 15)
        let perProvider: [UsageProvider: [CostUsageDailyReport.Entry]] = [
            .codex: [Self.entry("2026-06-16", tokens: 42)],
        ]
        let slots = CostUsageStackedBuckets.trailingDaySlots(
            perProvider: perProvider, providers: [.codex],
            days: 30, endingAt: today, calendar: Self.calendar)

        #expect(slots.count == 30)
        #expect(slots.first?.dayKey == "2026-06-16")
        #expect(slots.last?.dayKey == "2026-07-15")
        #expect(slots.first?.segments.first?.totalTokens == 42)
        #expect(slots.last?.isToday == true)
    }

    @Test
    func `grand total falls back to component sum when totalTokens is nil`() {
        let slot = CostUsageStackedDaySlot(
            dayKey: "2026-07-13", date: Date(timeIntervalSince1970: 0),
            segments: [
                .init(provider: .claude, totalTokens: nil,
                      inputTokens: 100, outputTokens: 50, cacheReadTokens: 20, cacheCreationTokens: 5,
                      costUSD: nil),
            ], isToday: false, isFuture: false)
        #expect(slot.grandTotal == 175) // 100 + 50 + 20 + 5
    }

    @Test
    func `as day slot collapses segments into one flat slot`() {
        let slot = CostUsageStackedDaySlot(
            dayKey: "2026-07-13", date: Date(timeIntervalSince1970: 0),
            segments: [
                .init(provider: .claude, totalTokens: 100, inputTokens: 40, outputTokens: 20,
                      cacheReadTokens: 30, cacheCreationTokens: 10, costUSD: 1.0),
                .init(provider: .codex, totalTokens: 50, inputTokens: 20, outputTokens: 10,
                      cacheReadTokens: 15, cacheCreationTokens: 5, costUSD: 0.5),
            ], isToday: true, isFuture: false)
        let flat = slot.asDaySlot
        #expect(flat.totalTokens == 150)
        #expect(flat.inputTokens == 60)
        #expect(flat.outputTokens == 30)
        #expect(flat.cacheReadTokens == 45)
        #expect(flat.cacheCreationTokens == 15)
        #expect(flat.costUSD == 1.5)
        #expect(flat.isToday)
    }

    // MARK: - Provider/model aggregation

    @Test
    func `provider totals sum daily fields and break down per model`() {
        let entries = [
            Self.entry("2026-07-13", tokens: 300, input: 100, output: 50, cacheRead: 150,
                       cost: 3.0, models: [("claude-sonnet", 300, 3.0)]),
            Self.entry("2026-07-14", tokens: 200, input: 80, output: 40, cacheRead: 80,
                       cost: 2.0, models: [("claude-sonnet", 150, 1.5), ("claude-haiku", 50, 0.5)]),
        ]
        let totals = CostUsageStackedAggregator.providerTotals(provider: .claude, entries: entries)

        #expect(totals.provider == .claude)
        #expect(totals.totalTokens == 500)
        #expect(totals.inputTokens == 180)
        #expect(totals.outputTokens == 90)
        #expect(totals.cacheReadTokens == 230)
        #expect(totals.costUSD == 5.0)
        // Same model across days accumulates.
        let sonnet = totals.models.first { $0.modelName == "claude-sonnet" }
        #expect(sonnet?.totalTokens == 450)
        #expect(sonnet?.costUSD == 4.5)
        let haiku = totals.models.first { $0.modelName == "claude-haiku" }
        #expect(haiku?.totalTokens == 50)
    }

    @Test
    func `models are sorted by total tokens descending`() {
        let entries = [
            Self.entry("2026-07-13", tokens: 100, models: [("small", 10, 0.1), ("big", 90, 0.9)]),
        ]
        let totals = CostUsageStackedAggregator.providerTotals(provider: .codex, entries: entries)
        #expect(totals.models.map(\.modelName) == ["big", "small"])
    }

    @Test
    func `all provider totals drops providers with no entries`() {
        let perProvider: [UsageProvider: [CostUsageDailyReport.Entry]] = [
            .claude: [Self.entry("2026-07-13", tokens: 100)],
            .codex: [],
        ]
        let totals = CostUsageStackedAggregator.allProviderTotals(
            perProvider: perProvider, providers: [.claude, .codex])
        #expect(totals.map(\.provider) == [.claude])
    }

    @Test
    func `all provider totals drops providers whose entries are all zero`() {
        let perProvider: [UsageProvider: [CostUsageDailyReport.Entry]] = [
            .claude: [Self.entry("2026-07-13", tokens: 0, cost: 0)],
            .codex: [Self.entry("2026-07-14", tokens: 5, cost: 0.1)],
        ]
        let totals = CostUsageStackedAggregator.allProviderTotals(
            perProvider: perProvider, providers: [.claude, .codex])
        #expect(totals.map(\.provider) == [.codex])
    }

    // MARK: - Helpers

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
#endif
