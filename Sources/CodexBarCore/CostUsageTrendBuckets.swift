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

    private struct DayAccumulator {
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
