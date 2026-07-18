// Fork: local SQLite persistence for daily token usage. The jsonl session logs the
// scanner reads only cover ~30 days; this store accumulates per-day rows forever so
// future statistics (long-range heatmaps, weekly reports) can outlive the log window.

import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)

public enum CostUsageSQLiteStoreError: LocalizedError, Sendable, Equatable {
    case openFailed(String)
    case sqlFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            "Failed to open token usage database: \(message)"
        case let .sqlFailed(message):
            "Token usage database error: \(message)"
        }
    }
}

/// A stored per-day usage row (mirrors the `daily_usage` table).
public struct CostUsageStoredDay: Sendable, Equatable {
    public let provider: String
    public let day: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let totalTokens: Int
    public let requestCount: Int
    public let costUSD: Double
    public let updatedAt: String

    public init(
        provider: String, day: String,
        inputTokens: Int, outputTokens: Int,
        cacheReadTokens: Int, cacheCreationTokens: Int,
        totalTokens: Int, requestCount: Int,
        costUSD: Double, updatedAt: String)
    {
        self.provider = provider
        self.day = day
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.costUSD = costUSD
        self.updatedAt = updatedAt
    }

    /// Bridge back to the daily-entry shape so trend bucketing can merge stored
    /// history with a live scanner snapshot.
    public var asDailyEntry: CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: self.day,
            inputTokens: self.inputTokens,
            outputTokens: self.outputTokens,
            cacheReadTokens: self.cacheReadTokens,
            cacheCreationTokens: self.cacheCreationTokens,
            totalTokens: self.totalTokens,
            requestCount: self.requestCount,
            costUSD: self.costUSD,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }
}

/// Upserts daily usage into `~/.config/codexbar/token-usage.sqlite3`. Rows outside the
/// scanner's history window are never deleted, so the database accumulates history.
public struct CostUsageSQLiteStore: Sendable {
    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    /// Default location next to config.json: `~/.config/codexbar/token-usage.sqlite3`
    /// (honors `XDG_CONFIG_HOME` via the config store's directory resolution).
    public static func defaultStore(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> CostUsageSQLiteStore
    {
        let configURL = CodexBarConfigStore.defaultURL(environment: environment)
        let directory = configURL.deletingLastPathComponent()
        return CostUsageSQLiteStore(
            databaseURL: directory.appendingPathComponent("token-usage.sqlite3", isDirectory: false))
    }

    // MARK: - Writing

    /// Upserts one row per (provider, day). Idempotent: re-writing the same snapshot
    /// leaves the table unchanged. Runs in a single transaction.
    public func upsertDailyEntries(
        _ entries: [CostUsageDailyReport.Entry],
        provider: UsageProvider,
        now: Date = Date()) throws
    {
        guard !entries.isEmpty else { return }
        let db = try self.openReadWrite()
        defer { sqlite3_close(db) }
        try self.migrate(db)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let updatedAt = isoFormatter.string(from: now)
        try self.exec(db, "BEGIN IMMEDIATE")
        do {
            try self.upsertDailyRows(db, entries: entries, provider: provider.rawValue, updatedAt: updatedAt)
            try self.upsertModelRows(db, entries: entries, provider: provider.rawValue)
            try self.exec(db, "COMMIT")
        } catch {
            try? self.exec(db, "ROLLBACK")
            throw error
        }
    }

    // MARK: - Reading

    /// Loads stored rows for `provider`, oldest first. Pass `since` (a "yyyy-MM-dd"
    /// key) to bound the range; nil returns everything.
    public func loadDailyRows(provider: UsageProvider, since dayKey: String? = nil) throws -> [CostUsageStoredDay] {
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw CostUsageSQLiteStoreError.openFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        var sql = """
            SELECT provider, day, input_tokens, output_tokens, cache_read_tokens,
                   cache_creation_tokens, total_tokens, request_count, cost_usd, updated_at
            FROM daily_usage WHERE provider = ?
            """
        if dayKey != nil {
            sql += " AND day >= ?"
        }
        sql += " ORDER BY day ASC"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, Self.transient)
        if let dayKey {
            sqlite3_bind_text(stmt, 2, dayKey, -1, Self.transient)
        }

        var rows: [CostUsageStoredDay] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
            }
            rows.append(CostUsageStoredDay(
                provider: Self.columnText(stmt, 0),
                day: Self.columnText(stmt, 1),
                inputTokens: Int(sqlite3_column_int64(stmt, 2)),
                outputTokens: Int(sqlite3_column_int64(stmt, 3)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 4)),
                cacheCreationTokens: Int(sqlite3_column_int64(stmt, 5)),
                totalTokens: Int(sqlite3_column_int64(stmt, 6)),
                requestCount: Int(sqlite3_column_int64(stmt, 7)),
                costUSD: sqlite3_column_double(stmt, 8),
                updatedAt: Self.columnText(stmt, 9)))
        }
        return rows
    }

    /// Fork: distinct provider keys that have at least one stored row. Used by the watch
    /// loop so the heatmap/trend views cover every provider that ever wrote history, not
    /// just the currently-enabled set.
    public func allStoredProviders() throws -> [UsageProvider] {
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw CostUsageSQLiteStoreError.openFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = "SELECT DISTINCT provider FROM daily_usage ORDER BY provider ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var providers: [UsageProvider] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
            }
            let raw = Self.columnText(stmt, 0)
            if let provider = UsageProvider(rawValue: raw) {
                providers.append(provider)
            }
        }
        return providers
    }

    /// Stored history merged with a live snapshot's daily entries; snapshot wins on
    /// overlapping days. Result is plain entries ready for trend bucketing.
    public func mergedDailyEntries(
        provider: UsageProvider,
        snapshotEntries: [CostUsageDailyReport.Entry],
        since dayKey: String? = nil) -> [CostUsageDailyReport.Entry]
    {
        let stored = (try? self.loadDailyRows(provider: provider, since: dayKey)) ?? []
        guard !stored.isEmpty else { return snapshotEntries }
        let snapshotDays = Set(snapshotEntries.map { String($0.date.prefix(10)) })
        let historical = stored
            .filter { !snapshotDays.contains($0.day) }
            .map(\.asDailyEntry)
        return historical + snapshotEntries
    }

    // MARK: - Internals

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func openReadWrite() throws -> OpaquePointer? {
        let directory = self.databaseURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            self.databaseURL.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw CostUsageSQLiteStoreError.openFailed(message)
        }
        sqlite3_busy_timeout(db, 1000)
        try? self.exec(db, "PRAGMA journal_mode=WAL")
        return db
    }

    private func migrate(_ db: OpaquePointer?) throws {
        try self.exec(db, """
            CREATE TABLE IF NOT EXISTS daily_usage (
              provider TEXT NOT NULL,
              day TEXT NOT NULL,
              input_tokens INTEGER NOT NULL DEFAULT 0,
              output_tokens INTEGER NOT NULL DEFAULT 0,
              cache_read_tokens INTEGER NOT NULL DEFAULT 0,
              cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
              total_tokens INTEGER NOT NULL DEFAULT 0,
              request_count INTEGER NOT NULL DEFAULT 0,
              cost_usd REAL NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (provider, day))
            """)
        try self.exec(db, """
            CREATE TABLE IF NOT EXISTS daily_model_usage (
              provider TEXT NOT NULL,
              day TEXT NOT NULL,
              model TEXT NOT NULL,
              input_tokens INTEGER NOT NULL DEFAULT 0,
              output_tokens INTEGER NOT NULL DEFAULT 0,
              cache_read_tokens INTEGER NOT NULL DEFAULT 0,
              cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
              total_tokens INTEGER NOT NULL DEFAULT 0,
              cost_usd REAL NOT NULL DEFAULT 0,
              PRIMARY KEY (provider, day, model))
            """)
        try self.exec(db, "PRAGMA user_version = 1")
        // Fork: re-normalize legacy Claude model names so the version separator reads as a
        // dot (claude-opus-4-8 → claude-opus-4.8). The normalization rule changed after
        // some rows were already written; this migration merges the legacy rows into the
        // canonical names so the breakdown table doesn't show duplicates.
        try self.migrateLegacyClaudeModelNames(db: db)
    }

    /// Updates legacy `claude-{family}-{major}-{minor}` model rows to the dotted form
    /// (`claude-{family}-{major}.{minor}`), merging them into any existing canonical rows.
    private func migrateLegacyClaudeModelNames(db: OpaquePointer?) throws {
        // Pull the legacy model rows so we can re-key them (sqlite UPDATE can't change the
        // primary key in place when the target row already exists, so we sum-then-delete).
        let sql = """
            SELECT provider, day, model, input_tokens, output_tokens,
                   cache_read_tokens, cache_creation_tokens, total_tokens, cost_usd
            FROM daily_model_usage
            WHERE provider = 'claude' AND model LIKE 'claude-%' AND model GLOB '*-[0-9]-[0-9]'
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var legacy: [(provider: String, day: String, model: String,
            input: Int, output: Int, cacheRead: Int, cacheWrite: Int, total: Int, cost: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            legacy.append((
                provider: Self.columnText(stmt, 0),
                day: Self.columnText(stmt, 1),
                model: Self.columnText(stmt, 2),
                input: Int(sqlite3_column_int64(stmt, 3)),
                output: Int(sqlite3_column_int64(stmt, 4)),
                cacheRead: Int(sqlite3_column_int64(stmt, 5)),
                cacheWrite: Int(sqlite3_column_int64(stmt, 6)),
                total: Int(sqlite3_column_int64(stmt, 7)),
                cost: sqlite3_column_double(stmt, 8)))
        }
        guard !legacy.isEmpty else { return }

        try self.exec(db, "BEGIN IMMEDIATE")
        do {
            for row in legacy {
                let normalized = CostUsagePricing.normalizeClaudeModel(row.model)
                guard normalized != row.model else { continue }
                // Sum into the canonical row (INSERT ... ON CONFLICT adds to the existing one).
                let mergeSQL = """
                    INSERT INTO daily_model_usage
                      (provider, day, model, input_tokens, output_tokens,
                       cache_read_tokens, cache_creation_tokens, total_tokens, cost_usd)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, day, model) DO UPDATE SET
                      input_tokens = daily_model_usage.input_tokens + excluded.input_tokens,
                      output_tokens = daily_model_usage.output_tokens + excluded.output_tokens,
                      cache_read_tokens = daily_model_usage.cache_read_tokens + excluded.cache_read_tokens,
                      cache_creation_tokens = daily_model_usage.cache_creation_tokens + excluded.cache_creation_tokens,
                      total_tokens = daily_model_usage.total_tokens + excluded.total_tokens,
                      cost_usd = daily_model_usage.cost_usd + excluded.cost_usd
                    """
                var merge: OpaquePointer?
                guard sqlite3_prepare_v2(db, mergeSQL, -1, &merge, nil) == SQLITE_OK else {
                    throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(merge) }
                sqlite3_bind_text(merge, 1, row.provider, -1, Self.transient)
                sqlite3_bind_text(merge, 2, row.day, -1, Self.transient)
                sqlite3_bind_text(merge, 3, normalized, -1, Self.transient)
                sqlite3_bind_int64(merge, 4, Int64(row.input))
                sqlite3_bind_int64(merge, 5, Int64(row.output))
                sqlite3_bind_int64(merge, 6, Int64(row.cacheRead))
                sqlite3_bind_int64(merge, 7, Int64(row.cacheWrite))
                sqlite3_bind_int64(merge, 8, Int64(row.total))
                sqlite3_bind_double(merge, 9, row.cost)
                guard sqlite3_step(merge) == SQLITE_DONE else {
                    throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            // Drop the legacy rows now that they've been merged into the canonical names.
            try self.exec(db, """
                DELETE FROM daily_model_usage
                WHERE provider = 'claude' AND model LIKE 'claude-%' AND model GLOB '*-[0-9]-[0-9]'
                """)
            try self.exec(db, "COMMIT")
        } catch {
            try? self.exec(db, "ROLLBACK")
            throw error
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw CostUsageSQLiteStoreError.sqlFailed(message)
        }
    }

    private func upsertDailyRows(
        _ db: OpaquePointer?,
        entries: [CostUsageDailyReport.Entry],
        provider: String,
        updatedAt: String) throws
    {
        let sql = """
            INSERT INTO daily_usage (provider, day, input_tokens, output_tokens, cache_read_tokens,
              cache_creation_tokens, total_tokens, request_count, cost_usd, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, day) DO UPDATE SET
              input_tokens = excluded.input_tokens,
              output_tokens = excluded.output_tokens,
              cache_read_tokens = excluded.cache_read_tokens,
              cache_creation_tokens = excluded.cache_creation_tokens,
              total_tokens = excluded.total_tokens,
              request_count = excluded.request_count,
              cost_usd = excluded.cost_usd,
              updated_at = excluded.updated_at
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for entry in entries {
            guard let day = Self.normalizedDayKey(entry.date) else { continue }
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, provider, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, day, -1, Self.transient)
            sqlite3_bind_int64(stmt, 3, Int64(entry.inputTokens ?? 0))
            sqlite3_bind_int64(stmt, 4, Int64(entry.outputTokens ?? 0))
            sqlite3_bind_int64(stmt, 5, Int64(entry.cacheReadTokens ?? 0))
            sqlite3_bind_int64(stmt, 6, Int64(entry.cacheCreationTokens ?? 0))
            sqlite3_bind_int64(stmt, 7, Int64(entry.totalTokens ?? 0))
            sqlite3_bind_int64(stmt, 8, Int64(entry.requestCount ?? 0))
            sqlite3_bind_double(stmt, 9, entry.costUSD ?? 0)
            sqlite3_bind_text(stmt, 10, updatedAt, -1, Self.transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func upsertModelRows(
        _ db: OpaquePointer?,
        entries: [CostUsageDailyReport.Entry],
        provider: String) throws
    {
        let sql = """
            INSERT INTO daily_model_usage (provider, day, model, input_tokens, output_tokens,
              cache_read_tokens, cache_creation_tokens, total_tokens, cost_usd)
            VALUES (?, ?, ?, 0, 0, 0, 0, ?, ?)
            ON CONFLICT(provider, day, model) DO UPDATE SET
              total_tokens = excluded.total_tokens,
              cost_usd = excluded.cost_usd
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for entry in entries {
            guard let day = Self.normalizedDayKey(entry.date),
                  let breakdowns = entry.modelBreakdowns else { continue }
            for breakdown in breakdowns {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, provider, -1, Self.transient)
                sqlite3_bind_text(stmt, 2, day, -1, Self.transient)
                sqlite3_bind_text(stmt, 3, breakdown.modelName, -1, Self.transient)
                sqlite3_bind_int64(stmt, 4, Int64(breakdown.totalTokens ?? 0))
                sqlite3_bind_double(stmt, 5, breakdown.costUSD ?? 0)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw CostUsageSQLiteStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }

    private static func normalizedDayKey(_ rawDate: String) -> String? {
        let trimmed = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let prefix = String(trimmed.prefix(10))
        guard prefix[prefix.index(prefix.startIndex, offsetBy: 4)] == "-",
              prefix[prefix.index(prefix.startIndex, offsetBy: 7)] == "-"
        else { return nil }
        return prefix
    }
}

#endif
