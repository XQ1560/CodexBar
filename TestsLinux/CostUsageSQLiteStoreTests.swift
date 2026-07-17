import Foundation
import Testing
@testable import CodexBarCore

#if os(Linux)
struct CostUsageSQLiteStoreTests {
    private static func temporaryStore() -> (store: CostUsageSQLiteStore, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-usage-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("token-usage.sqlite3", isDirectory: false)
        let store = CostUsageSQLiteStore(databaseURL: url)
        return (store, {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private static func entry(
        _ date: String,
        tokens: Int,
        cost: Double = 0,
        input: Int = 0,
        output: Int = 0) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: input,
            outputTokens: output,
            totalTokens: tokens,
            requestCount: 1,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    @Test
    func `upsert then load returns stored rows oldest first`() throws {
        let (store, cleanup) = Self.temporaryStore()
        defer { cleanup() }

        try store.upsertDailyEntries([
            Self.entry("2026-07-15", tokens: 300, cost: 3.0),
            Self.entry("2026-07-13", tokens: 100, cost: 1.0),
        ], provider: .claude)

        let rows = try store.loadDailyRows(provider: .claude)
        #expect(rows.map(\.day) == ["2026-07-13", "2026-07-15"])
        #expect(rows[0].totalTokens == 100)
        #expect(rows[1].costUSD == 3.0)
    }

    @Test
    func `upsert is idempotent for repeated snapshots`() throws {
        let (store, cleanup) = Self.temporaryStore()
        defer { cleanup() }

        let snapshot = [Self.entry("2026-07-13", tokens: 100), Self.entry("2026-07-14", tokens: 200)]
        try store.upsertDailyEntries(snapshot, provider: .claude)
        try store.upsertDailyEntries(snapshot, provider: .claude)

        let rows = try store.loadDailyRows(provider: .claude)
        #expect(rows.count == 2)
        #expect(rows.map(\.totalTokens) == [100, 200])
    }

    @Test
    func `upsert updates the value for an existing day`() throws {
        let (store, cleanup) = Self.temporaryStore()
        defer { cleanup() }

        try store.upsertDailyEntries([Self.entry("2026-07-13", tokens: 100)], provider: .claude)
        try store.upsertDailyEntries([Self.entry("2026-07-13", tokens: 175)], provider: .claude)

        let rows = try store.loadDailyRows(provider: .claude)
        #expect(rows.count == 1)
        #expect(rows[0].totalTokens == 175)
    }

    @Test
    func `rows outside the snapshot window are never deleted`() throws {
        let (store, cleanup) = Self.temporaryStore()
        defer { cleanup() }

        // Day recorded a long time ago (outside a later 30-day scan window).
        try store.upsertDailyEntries([Self.entry("2026-01-01", tokens: 500)], provider: .claude)
        // A newer scan that no longer contains the January day.
        try store.upsertDailyEntries([Self.entry("2026-07-13", tokens: 100)], provider: .claude)

        let rows = try store.loadDailyRows(provider: .claude)
        #expect(rows.map(\.day) == ["2026-01-01", "2026-07-13"])
    }

    @Test
    func `providers are isolated from each other`() throws {
        let (store, cleanup) = Self.temporaryStore()
        defer { cleanup() }

        try store.upsertDailyEntries([Self.entry("2026-07-13", tokens: 100)], provider: .claude)
        try store.upsertDailyEntries([Self.entry("2026-07-13", tokens: 900)], provider: .codex)

        #expect(try store.loadDailyRows(provider: .claude).map(\.totalTokens) == [100])
        #expect(try store.loadDailyRows(provider: .codex).map(\.totalTokens) == [900])
    }

    @Test
    func `merged entries prefer the snapshot for overlapping days`() throws {
        let (store, cleanup) = Self.temporaryStore()
        defer { cleanup() }

        // Stored history: two days.
        try store.upsertDailyEntries([
            Self.entry("2026-06-01", tokens: 111),
            Self.entry("2026-07-13", tokens: 100),
        ], provider: .claude)

        // Live snapshot re-reports 07-13 with a corrected value plus a new day.
        let snapshot = [Self.entry("2026-07-13", tokens: 150), Self.entry("2026-07-14", tokens: 200)]
        let merged = store.mergedDailyEntries(provider: .claude, snapshotEntries: snapshot)

        let byDay = Dictionary(uniqueKeysWithValues: merged.map { (String($0.date.prefix(10)), $0.totalTokens) })
        #expect(byDay["2026-06-01"] == 111)   // history-only day survives
        #expect(byDay["2026-07-13"] == 150)   // snapshot wins on overlap
        #expect(byDay["2026-07-14"] == 200)   // snapshot-only day present
    }

    @Test
    func `loading a missing database returns no rows`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-missing-\(UUID().uuidString)/token-usage.sqlite3")
        let store = CostUsageSQLiteStore(databaseURL: url)
        #expect(try store.loadDailyRows(provider: .claude).isEmpty)
    }

    @Test
    func `since filter bounds the returned range`() throws {
        let (store, cleanup) = Self.temporaryStore()
        defer { cleanup() }

        try store.upsertDailyEntries([
            Self.entry("2026-06-01", tokens: 1),
            Self.entry("2026-07-10", tokens: 2),
            Self.entry("2026-07-15", tokens: 3),
        ], provider: .claude)

        let rows = try store.loadDailyRows(provider: .claude, since: "2026-07-01")
        #expect(rows.map(\.day) == ["2026-07-10", "2026-07-15"])
    }
}
#endif
