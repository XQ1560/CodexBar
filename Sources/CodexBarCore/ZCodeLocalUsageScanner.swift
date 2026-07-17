// Fork: local token-usage scanner for ZCode (z.ai's CLI / desktop). ZCode persists every
// agent turn as a JSONL transcript under ~/.zcode/cli/agents/<session>/<agent>/transcript.jsonl.
// Each turn is split across two event rows keyed by `turnId`:
//   - `model_request` carries `payload.model` (the model id)
//   - `model_complete` carries `payload.usage` (camelCase token counters)
// Joining them yields per-turn (date, model, tokens) tuples, which this scanner aggregates
// into the same `CostUsageDailyReport.Entry` shape the rest of the cost pipeline uses — so
// ZCode feeds the watch trend/heatmap views without touching the upstream codex/claude path.

import Foundation

public enum ZCodeLocalUsageScannerError: LocalizedError, Sendable, Equatable {
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .readFailed(message):
            "Failed to read ZCode transcript: \(message)"
        }
    }
}

/// Fork: scans ZCode agent transcripts and aggregates token usage into daily entries.
public struct ZCodeLocalUsageScanner: Sendable {
    public let agentsRoot: URL

    public init(agentsRoot: URL) {
        self.agentsRoot = agentsRoot
    }

    /// Resolves the ZCode agents root from the environment.
    /// `ZCODE_HOME` (default `~/.zcode`) → `$ZCODE_HOME/cli/agents`.
    public static func defaultAgentsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        if let raw = environment["ZCODE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: raw).appendingPathComponent("cli", isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".zcode", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
    }

    /// Convenience default scanner.
    public static func defaultScanner(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ZCodeLocalUsageScanner
    {
        ZCodeLocalUsageScanner(agentsRoot: Self.defaultAgentsRoot(environment: environment))
    }

    /// Loads per-day token usage for all transcripts under the agents root.
    /// - Parameters:
    ///   - since: inclusive lower bound (start of the day). nil = no bound.
    ///   - calendar: calendar used to derive the per-day key.
    /// - Returns: daily entries (oldest first), each aggregating every turn that day.
    public func loadDailyEntries(
        since: Date? = nil,
        calendar: Calendar = .current) throws -> [CostUsageDailyReport.Entry]
    {
        guard FileManager.default.fileExists(atPath: self.agentsRoot.path) else { return [] }
        let transcripts = try Self.listTranscripts(root: self.agentsRoot)
        guard !transcripts.isEmpty else { return [] }

        var byDay: [String: DayAccumulator] = [:]
        for transcript in transcripts {
            let turns = Self.scanTranscript(url: transcript)
            for turn in turns {
                if let since, turn.timestamp < calendar.startOfDay(for: since) { continue }
                let dayKey = Self.dayKey(from: turn.timestamp, calendar: calendar)
                var accumulator = byDay[dayKey] ?? DayAccumulator(dayKey: dayKey)
                accumulator.add(turn: turn)
                byDay[dayKey] = accumulator
            }
        }

        return byDay.values.sorted { $0.dayKey < $1.dayKey }.map(\.asEntry)
    }

    // MARK: - Internals

    /// One resolved turn: timestamp + model + token counters.
    struct TurnUsage: Sendable, Equatable {
        let timestamp: Date
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
    }

    /// Per-day aggregator producing a `CostUsageDailyReport.Entry`.
    struct DayAccumulator {
        let dayKey: String
        var inputTokens = 0
        var outputTokens = 0
        var totalTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var requestCount = 0
        var models: [String: ModelAccumulator] = [:]

        init(dayKey: String) {
            self.dayKey = dayKey
        }

        mutating func add(turn: TurnUsage) {
            self.inputTokens += turn.inputTokens
            self.outputTokens += turn.outputTokens
            self.totalTokens += turn.totalTokens
            self.cacheReadTokens += turn.cacheReadTokens
            self.cacheWriteTokens += turn.cacheWriteTokens
            self.requestCount += 1
            var model = self.models[turn.model] ?? ModelAccumulator(model: turn.model)
            model.add(turn: turn)
            self.models[turn.model] = model
        }

        var asEntry: CostUsageDailyReport.Entry {
            let modelBreakdowns = self.models.values.sorted { lhs, rhs in
                lhs.totalTokens == rhs.totalTokens ? lhs.model < rhs.model : lhs.totalTokens > rhs.totalTokens
            }.map(\.asBreakdown)
            return CostUsageDailyReport.Entry(
                date: self.dayKey,
                inputTokens: self.inputTokens,
                outputTokens: self.outputTokens,
                cacheReadTokens: self.cacheReadTokens,
                cacheCreationTokens: self.cacheWriteTokens,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                costUSD: nil,
                modelsUsed: self.models.keys.sorted(),
                modelBreakdowns: modelBreakdowns)
        }
    }

    /// Per-model aggregator (mirrors the day totals for one model).
    struct ModelAccumulator {
        let model: String
        var inputTokens = 0
        var outputTokens = 0
        var totalTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var requestCount = 0

        mutating func add(turn: TurnUsage) {
            self.inputTokens += turn.inputTokens
            self.outputTokens += turn.outputTokens
            self.totalTokens += turn.totalTokens
            self.cacheReadTokens += turn.cacheReadTokens
            self.cacheWriteTokens += turn.cacheWriteTokens
            self.requestCount += 1
        }

        var asBreakdown: CostUsageDailyReport.ModelBreakdown {
            CostUsageDailyReport.ModelBreakdown(
                modelName: self.model,
                costUSD: nil,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount)
        }
    }

    /// Enumerates every `transcript.jsonl` under `root`, sorted for stable output.
    static func listTranscripts(root: URL) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles])
        else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "transcript.jsonl" {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// Scans one transcript file, joining `model_request` and `model_complete` rows by
    /// `turnId` into resolved `TurnUsage` records.
    static func scanTranscript(url: URL) -> [TurnUsage] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var modelByTurn: [String: String] = [:]
        var usageByTurn: [(turn: String, timestamp: Date, usage: TokenUsage)] = []
        // Pre-resolve model on the first pass; usage rows carry the timestamp we key on.
        Self.forEachJSONLine(data: data) { object in
            guard let turn = object["turnId"] as? String else { return }
            let type = (object["type"] as? String) ?? ""
            if type == "model_request", let payload = object["payload"] as? [String: Any] {
                if let model = payload["model"] as? String, !model.isEmpty {
                    modelByTurn[turn] = Self.normalizeModelName(model)
                } else if let modelRef = payload["modelRef"] as? [String: Any],
                          let modelId = modelRef["modelId"] as? String, !modelId.isEmpty
                {
                    modelByTurn[turn] = modelId
                }
            }
            if type == "model_complete", let payload = object["payload"] as? [String: Any],
               let usage = payload["usage"] as? [String: Any],
               let timestamp = Self.timestamp(from: object)
            {
                let tokens = TokenUsage(usage: usage)
                if tokens.hasAny {
                    usageByTurn.append((turn, timestamp, tokens))
                }
            }
        }
        return usageByTurn.compactMap { record in
            guard let model = modelByTurn[record.turn] else { return nil }
            return TurnUsage(
                timestamp: record.timestamp,
                model: model,
                inputTokens: record.usage.inputTokens,
                outputTokens: record.usage.outputTokens,
                totalTokens: record.usage.totalTokens,
                cacheReadTokens: record.usage.cacheReadTokens,
                cacheWriteTokens: record.usage.cacheWriteTokens)
        }
    }

    /// Strips the `builtin:` provider prefix ZCode prepends (e.g.
    /// `builtin:bigmodel-coding-plan/GLM-5.2` → `GLM-5.2`) so model rows group cleanly.
    public static func normalizeModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return trimmed
    }

    static func dayKey(from date: Date, calendar: Calendar) -> String {
        CostUsageLocalDay.key(from: date, calendar: calendar)
    }

    private static func timestamp(from object: [String: Any]) -> Date? {
        guard let raw = object["timestamp"] as? String else { return nil }
        // ZCode emits ISO8601 with milliseconds + "Z" (e.g. 2026-07-04T09:36:28.604Z).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Streams a JSONL buffer line by line, decoding each line as a JSON object.
    private static func forEachJSONLine(data: Data, _ block: ([String: Any]) -> Void) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            block(object)
        }
    }
}

/// Token counters extracted from a ZCode `usage` object.
private struct TokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int

    init(usage: [String: Any]) {
        self.inputTokens = Self.int(usage, "inputTokens")
        self.outputTokens = Self.int(usage, "outputTokens")
        self.cacheReadTokens = Self.int(usage, "cacheReadTokens")
        self.cacheWriteTokens = Self.int(usage, "cacheWriteTokens")
        let explicitTotal = Self.int(usage, "totalTokens")
        self.totalTokens = explicitTotal > 0
            ? explicitTotal
            : self.inputTokens + self.outputTokens + self.cacheReadTokens + self.cacheWriteTokens
    }

    var hasAny: Bool {
        self.inputTokens > 0 || self.outputTokens > 0 || self.totalTokens > 0
            || self.cacheReadTokens > 0 || self.cacheWriteTokens > 0
    }

    private static func int(_ object: [String: Any], _ key: String) -> Int {
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? NSNumber { return value.intValue }
        if let value = object[key] as? Double { return Int(value) }
        if let value = object[key] as? String, let parsed = Int(value) { return parsed }
        return 0
    }
}
