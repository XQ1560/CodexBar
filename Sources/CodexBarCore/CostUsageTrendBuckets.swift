// Fork: calendar-aware bucketing (natural week, trailing days, heatmap week grid)
// for the CLI watch trend views. Kept in a separate file so upstream merges stay clean.

import Foundation

/// One day cell used by the CLI trend views. Token fields are nil when the day has no
/// recorded usage (or lies in the future). `totalTokens` falls back to the sum of the
/// input/output/cache components when the source didn't report an explicit total.
public struct CostUsageDaySlot: Sendable, Equatable {
    public let dayKey: String
    public let date: Date
    public let totalTokens: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
    public let costUSD: Double?
    public let isToday: Bool
    public let isFuture: Bool

    public init(
        dayKey: String,
        date: Date,
        totalTokens: Int?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        costUSD: Double?,
        isToday: Bool,
        isFuture: Bool)
    {
        self.dayKey = dayKey
        self.date = date
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
        self.isToday = isToday
        self.isFuture = isFuture
    }
}

/// Aggregated token totals over a set of day slots, with the input/output/cache breakdown.
public struct CostUsageTokenTotals: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    public var activeDays: Int = 0

    public init() {}

    public static func from(slots: [CostUsageDaySlot]) -> CostUsageTokenTotals {
        var totals = CostUsageTokenTotals()
        for slot in slots {
            let dayTotal = slot.totalTokens ?? 0
            if dayTotal > 0 { totals.activeDays += 1 }
            totals.inputTokens += slot.inputTokens ?? 0
            totals.outputTokens += slot.outputTokens ?? 0
            totals.cacheReadTokens += slot.cacheReadTokens ?? 0
            totals.cacheCreationTokens += slot.cacheCreationTokens ?? 0
            totals.totalTokens += dayTotal
            totals.costUSD += slot.costUSD ?? 0
        }
        return totals
    }
}

/// Static bucketing helpers. They accept plain daily entries so callers can merge
/// multiple sources (live scanner snapshot + SQLite history) before bucketing.
public enum CostUsageTrendBuckets {
    /// Start of the Monday-first natural week containing `reference`.
    /// Uses a fixed Monday anchor regardless of the calendar's locale firstWeekday.
    public static func mondayStart(containing reference: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: reference)
        let weekday = calendar.dateComponents([.weekday], from: day).weekday ?? 1
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: day) ?? day
    }

    /// Monday-first natural week containing `reference`. Always 7 slots (Mon..Sun);
    /// days without data or in the future carry nil tokens.
    public static func naturalWeekSlots(
        entries: [CostUsageDailyReport.Entry],
        containing reference: Date,
        calendar: Calendar = .current) -> [CostUsageDaySlot]
    {
        let monday = self.mondayStart(containing: reference, calendar: calendar)
        return self.slots(entries: entries, from: monday, count: 7, reference: reference, calendar: calendar)
    }

    /// Trailing `days` slots ending at `reference`'s day (oldest first), one per day.
    public static func trailingDaySlots(
        entries: [CostUsageDailyReport.Entry],
        days: Int,
        endingAt reference: Date,
        calendar: Calendar = .current) -> [CostUsageDaySlot]
    {
        let count = max(1, days)
        let today = calendar.startOfDay(for: reference)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        return self.slots(entries: entries, from: start, count: count, reference: reference, calendar: calendar)
    }

    /// GitHub-style heatmap grid: `weeks` columns of Monday-first natural weeks,
    /// oldest column first; the last column is the week containing `reference`.
    /// Every column has exactly 7 slots (Mon..Sun).
    public static func weekGridSlots(
        entries: [CostUsageDailyReport.Entry],
        weeks: Int,
        endingAt reference: Date,
        calendar: Calendar = .current) -> [[CostUsageDaySlot]]
    {
        let columns = max(1, weeks)
        let currentMonday = self.mondayStart(containing: reference, calendar: calendar)
        let index = self.dayIndex(entries: entries, calendar: calendar)
        return (0..<columns).map { column in
            let offsetWeeks = -(columns - 1 - column)
            let monday = calendar.date(byAdding: .day, value: offsetWeeks * 7, to: currentMonday) ?? currentMonday
            return self.slots(
                entries: entries, from: monday, count: 7, reference: reference,
                calendar: calendar, index: index)
        }
    }

    // MARK: - Internals

    // Fork: internal (not private) so the stacked buckets in the same file can reuse the
    // day-index build without re-implementing the date-key normalization.
    struct DayAccumulator {
        var totalTokens: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var costUSD: Double?

        /// Explicit total when reported, otherwise the sum of the components. Some sources
        /// only populate the breakdown and leave `totalTokens` nil, so trends must fall back.
        var resolvedTotal: Int? {
            if let totalTokens { return totalTokens }
            let sum = (self.inputTokens ?? 0) + (self.outputTokens ?? 0)
                + (self.cacheReadTokens ?? 0) + (self.cacheCreationTokens ?? 0)
            return sum > 0 ? sum : nil
        }
    }

    private static func slots(
        entries: [CostUsageDailyReport.Entry],
        from start: Date,
        count: Int,
        reference: Date,
        calendar: Calendar,
        index: [String: DayAccumulator]? = nil) -> [CostUsageDaySlot]
    {
        let todayKey = CostUsageLocalDay.key(from: reference, calendar: calendar)
        let dayIndex = index ?? self.dayIndex(entries: entries, calendar: calendar)
        return (0..<count).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let key = CostUsageLocalDay.key(from: date, calendar: calendar)
            let isFuture = key > todayKey
            let values = isFuture ? nil : dayIndex[key]
            return CostUsageDaySlot(
                dayKey: key,
                date: date,
                totalTokens: values?.resolvedTotal,
                inputTokens: values?.inputTokens,
                outputTokens: values?.outputTokens,
                cacheReadTokens: values?.cacheReadTokens,
                cacheCreationTokens: values?.cacheCreationTokens,
                costUSD: values?.costUSD,
                isToday: key == todayKey,
                isFuture: isFuture)
        }
    }

    private static func dayIndex(
        entries: [CostUsageDailyReport.Entry],
        calendar: Calendar) -> [String: DayAccumulator]
    {
        Self.sharedDayIndex(entries: entries, calendar: calendar)
    }

    // Fork: shared day-index build, reused by CostUsageStackedBuckets.
    static func sharedDayIndex(
        entries: [CostUsageDailyReport.Entry],
        calendar: Calendar) -> [String: DayAccumulator]
    {
        var index: [String: DayAccumulator] = [:]
        for entry in entries {
            guard let key = self.normalizedDayKey(entry.date, calendar: calendar) else { continue }
            var accumulator = index[key] ?? DayAccumulator()
            accumulator.totalTokens = self.addOptional(accumulator.totalTokens, entry.totalTokens)
            accumulator.inputTokens = self.addOptional(accumulator.inputTokens, entry.inputTokens)
            accumulator.outputTokens = self.addOptional(accumulator.outputTokens, entry.outputTokens)
            accumulator.cacheReadTokens = self.addOptional(accumulator.cacheReadTokens, entry.cacheReadTokens)
            accumulator.cacheCreationTokens = self.addOptional(
                accumulator.cacheCreationTokens, entry.cacheCreationTokens)
            accumulator.costUSD = self.addOptional(accumulator.costUSD, entry.costUSD)
            index[key] = accumulator
        }
        return index
    }

    private static func normalizedDayKey(_ rawDate: String, calendar: Calendar) -> String? {
        let trimmed = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 10 {
            let prefix = String(trimmed.prefix(10))
            if prefix.count == 10,
               prefix[prefix.index(prefix.startIndex, offsetBy: 4)] == "-",
               prefix[prefix.index(prefix.startIndex, offsetBy: 7)] == "-"
            {
                return prefix
            }
        }
        guard let parsed = CostUsageDateParser.parse(trimmed) else { return nil }
        return CostUsageLocalDay.key(from: parsed, calendar: calendar)
    }

    private static func addOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case let (value?, nil), let (nil, value?): value
        case let (l?, r?): l + r
        }
    }

    private static func addOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case let (value?, nil), let (nil, value?): value
        case let (l?, r?): l + r
        }
    }
}

extension CostUsageTokenSnapshot {
    public func naturalWeekSlots(
        containing reference: Date = Date(),
        calendar: Calendar = .current) -> [CostUsageDaySlot]
    {
        CostUsageTrendBuckets.naturalWeekSlots(entries: self.daily, containing: reference, calendar: calendar)
    }

    public func trailingDaySlots(
        _ days: Int,
        endingAt reference: Date = Date(),
        calendar: Calendar = .current) -> [CostUsageDaySlot]
    {
        CostUsageTrendBuckets.trailingDaySlots(
            entries: self.daily, days: days, endingAt: reference, calendar: calendar)
    }

    public func weekGridSlots(
        weeks: Int,
        endingAt reference: Date = Date(),
        calendar: Calendar = .current) -> [[CostUsageDaySlot]]
    {
        CostUsageTrendBuckets.weekGridSlots(
            entries: self.daily, weeks: weeks, endingAt: reference, calendar: calendar)
    }
}

// MARK: - Fork: per-provider stacked buckets

/// One provider's contribution for a single day, used by the stacked trend views.
/// `totalTokens` is nil when the provider has no recorded usage for that day.
public struct CostUsageStackedSegment: Sendable, Equatable {
    public let provider: UsageProvider
    public let totalTokens: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
    public let costUSD: Double?

    public init(
        provider: UsageProvider,
        totalTokens: Int?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        costUSD: Double?)
    {
        self.provider = provider
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
    }
}

/// A day cell split per provider for the stacked bar chart. `segments` is ordered by the
/// caller-supplied provider list (skipping providers with no data for this day is the
/// renderer's job). `grandTotal` sums all segments so the bar height can be scaled.
public struct CostUsageStackedDaySlot: Sendable, Equatable {
    public let dayKey: String
    public let date: Date
    public let segments: [CostUsageStackedSegment]
    public let isToday: Bool
    public let isFuture: Bool

    public init(
        dayKey: String,
        date: Date,
        segments: [CostUsageStackedSegment],
        isToday: Bool,
        isFuture: Bool)
    {
        self.dayKey = dayKey
        self.date = date
        self.segments = segments
        self.isToday = isToday
        self.isFuture = isFuture
    }

    /// Sum of every segment's resolved total (explicit totalTokens, else the component sum).
    public var grandTotal: Int {
        self.segments.reduce(0) { partial, segment in
            if let total = segment.totalTokens { return partial + total }
            let components = (segment.inputTokens ?? 0) + (segment.outputTokens ?? 0)
                + (segment.cacheReadTokens ?? 0) + (segment.cacheCreationTokens ?? 0)
            return partial + components
        }
    }

    /// Flat day-slot view (segments collapsed into one) for legend/totals reuse.
    public var asDaySlot: CostUsageDaySlot {
        let totals = CostUsageTokenTotals.from(slots: [
            CostUsageDaySlot(
                dayKey: self.dayKey, date: self.date,
                totalTokens: self.grandTotal,
                inputTokens: self.segments.compactMap(\.inputTokens).reduce(0, +),
                outputTokens: self.segments.compactMap(\.outputTokens).reduce(0, +),
                cacheReadTokens: self.segments.compactMap(\.cacheReadTokens).reduce(0, +),
                cacheCreationTokens: self.segments.compactMap(\.cacheCreationTokens).reduce(0, +),
                costUSD: self.segments.compactMap(\.costUSD).reduce(0, +),
                isToday: self.isToday, isFuture: self.isFuture),
        ])
        return CostUsageDaySlot(
            dayKey: self.dayKey, date: self.date,
            totalTokens: totals.totalTokens,
            inputTokens: totals.inputTokens,
            outputTokens: totals.outputTokens,
            cacheReadTokens: totals.cacheReadTokens,
            cacheCreationTokens: totals.cacheCreationTokens,
            costUSD: totals.costUSD,
            isToday: self.isToday, isFuture: self.isFuture)
    }
}

/// Fork: stacked bucketing helpers. Each provider's daily entries are bucketed
/// independently and zipped into a single day cell that carries per-provider segments.
public enum CostUsageStackedBuckets {
    /// Monday-first natural week containing `reference`, one stacked slot per weekday.
    public static func naturalWeekSlots(
        perProvider: [UsageProvider: [CostUsageDailyReport.Entry]],
        providers: [UsageProvider],
        containing reference: Date,
        calendar: Calendar = .current) -> [CostUsageStackedDaySlot]
    {
        let monday = CostUsageTrendBuckets.mondayStart(containing: reference, calendar: calendar)
        return Self.slots(perProvider: perProvider, providers: providers, from: monday, count: 7,
                          reference: reference, calendar: calendar)
    }

    /// Trailing `days` stacked slots ending at `reference`'s day (oldest first).
    public static func trailingDaySlots(
        perProvider: [UsageProvider: [CostUsageDailyReport.Entry]],
        providers: [UsageProvider],
        days: Int,
        endingAt reference: Date,
        calendar: Calendar = .current) -> [CostUsageStackedDaySlot]
    {
        let count = max(1, days)
        let today = calendar.startOfDay(for: reference)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        return Self.slots(perProvider: perProvider, providers: providers, from: start, count: count,
                          reference: reference, calendar: calendar)
    }

    // MARK: - Internals

    private static func slots(
        perProvider: [UsageProvider: [CostUsageDailyReport.Entry]],
        providers: [UsageProvider],
        from start: Date,
        count: Int,
        reference: Date,
        calendar: Calendar) -> [CostUsageStackedDaySlot]
    {
        let todayKey = CostUsageLocalDay.key(from: reference, calendar: calendar)
        let indexByProvider: [UsageProvider: [String: CostUsageTrendBuckets.DayAccumulator]] =
            Dictionary(uniqueKeysWithValues: providers.map { provider in
                let entries = perProvider[provider] ?? []
                return (provider, CostUsageTrendBuckets.sharedDayIndex(entries: entries, calendar: calendar))
            })

        return (0..<count).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let key = CostUsageLocalDay.key(from: date, calendar: calendar)
            let isFuture = key > todayKey
            let segments: [CostUsageStackedSegment] = providers.map { provider in
                let accumulator = isFuture ? nil : indexByProvider[provider]?[key]
                return CostUsageStackedSegment(
                    provider: provider,
                    totalTokens: accumulator?.resolvedTotal,
                    inputTokens: accumulator?.inputTokens,
                    outputTokens: accumulator?.outputTokens,
                    cacheReadTokens: accumulator?.cacheReadTokens,
                    cacheCreationTokens: accumulator?.cacheCreationTokens,
                    costUSD: accumulator?.costUSD)
            }
            return CostUsageStackedDaySlot(
                dayKey: key, date: date, segments: segments,
                isToday: key == todayKey, isFuture: isFuture)
        }
    }
}

// MARK: - Fork: per-provider × per-model aggregation

/// Aggregated usage of one model under one provider over the trend window. Only fields the
/// `ModelBreakdown` type actually exposes are populated; per-day in/out/cache splits exist
/// only at the Entry level so they live on `CostUsageStackedModelTotals` instead.
public struct CostUsageModelBreakdownTotals: Sendable, Equatable {
    public let provider: UsageProvider
    public let modelName: String
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    public var requestCount: Int = 0

    public init(provider: UsageProvider, modelName: String) {
        self.provider = provider
        self.modelName = modelName
    }
}

/// Per-provider totals across the whole trend window: full in/out/cache breakdown (from the
/// Entry level) plus the model-level breakdown list. Used by the watch trend detail table.
public struct CostUsageStackedProviderTotals: Sendable, Equatable {
    public let provider: UsageProvider
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    public var requestCount: Int = 0
    public var models: [CostUsageModelBreakdownTotals] = []

    public init(provider: UsageProvider) {
        self.provider = provider
    }
}

/// Fork: aggregates a provider's daily entries into window-wide provider + model totals.
public enum CostUsageStackedAggregator {
    /// Sums entries into provider-level totals (in/out/cache/total/cost) plus the model list.
    public static func providerTotals(
        provider: UsageProvider,
        entries: [CostUsageDailyReport.Entry]) -> CostUsageStackedProviderTotals
    {
        var totals = CostUsageStackedProviderTotals(provider: provider)
        var modelIndex: [String: CostUsageModelBreakdownTotals] = [:]
        for entry in entries {
            totals.inputTokens += entry.inputTokens ?? 0
            totals.outputTokens += entry.outputTokens ?? 0
            totals.cacheReadTokens += entry.cacheReadTokens ?? 0
            totals.cacheCreationTokens += entry.cacheCreationTokens ?? 0
            totals.totalTokens += entry.totalTokens ?? 0
            totals.costUSD += entry.costUSD ?? 0
            totals.requestCount += entry.requestCount ?? 0
            for breakdown in entry.modelBreakdowns ?? [] {
                var model = modelIndex[breakdown.modelName]
                    ?? CostUsageModelBreakdownTotals(provider: provider, modelName: breakdown.modelName)
                model.totalTokens += breakdown.totalTokens ?? 0
                model.costUSD += breakdown.costUSD ?? 0
                model.requestCount += breakdown.requestCount ?? 0
                modelIndex[breakdown.modelName] = model
            }
        }
        // Models sorted by total tokens descending (most-used first), ties by name for stability.
        totals.models = modelIndex.values.sorted { lhs, rhs in
            lhs.totalTokens == rhs.totalTokens
                ? lhs.modelName < rhs.modelName
                : lhs.totalTokens > rhs.totalTokens
        }
        return totals
    }

    /// Aggregates a full per-provider map into totals, preserving the caller's provider order
    /// and dropping providers that have no entries at all.
    public static func allProviderTotals(
        perProvider: [UsageProvider: [CostUsageDailyReport.Entry]],
        providers: [UsageProvider]) -> [CostUsageStackedProviderTotals]
    {
        providers.compactMap { provider in
            let entries = perProvider[provider] ?? []
            guard !entries.isEmpty else { return nil }
            let totals = Self.providerTotals(provider: provider, entries: entries)
            // Skip providers whose entries are all zero (no real activity in the window).
            guard totals.totalTokens > 0
                || totals.costUSD > 0
                || totals.requestCount > 0
                || !totals.models.isEmpty
            else { return nil }
            return totals
        }
    }
}
