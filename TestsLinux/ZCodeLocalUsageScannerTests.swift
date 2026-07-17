import CodexBarCore
import Foundation
import Testing

#if os(Linux)
struct ZCodeLocalUsageScannerTests {
    /// Writes a transcript.jsonl under a temp agents tree and returns the scanner.
    private static func makeScanner(lines: [String]) throws -> (ZCodeLocalUsageScanner, () -> Void) {
        // Structure: tmp/zcode-test-UUID/  <- agentsRoot (scanner scans this recursively)
        //              sess_test/agent_test/transcript.jsonl
        let agentsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-test-\(UUID().uuidString)", isDirectory: true)
        let transcriptDir = agentsRoot
            .appendingPathComponent("sess_test", isDirectory: true)
            .appendingPathComponent("agent_test", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcript = transcriptDir.appendingPathComponent("transcript.jsonl", isDirectory: false)
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: transcript)
        let scanner = ZCodeLocalUsageScanner(agentsRoot: agentsRoot)
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: agentsRoot) }
        return (scanner, cleanup)
    }

    private static func json(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8)!
    }

    @Test
    func `joins model_request and model_complete by turnId into per-day totals`() throws {
        // Two turns on 2026-07-04, one turn on 2026-07-05; one model_request without a
        // matching model_complete (dropped) and one usage without a model (dropped).
        let lines = [
            Self.json([
                "turnId": "turn_a", "type": "model_request",
                "timestamp": "2026-07-04T09:36:00.000Z",
                "payload": ["model": "builtin:bigmodel-coding-plan/GLM-5.2"],
            ]),
            Self.json([
                "turnId": "turn_a", "type": "model_complete",
                "timestamp": "2026-07-04T09:36:28.604Z",
                "payload": ["usage": [
                    "inputTokens": 4108, "outputTokens": 337,
                    "totalTokens": 4445, "cacheReadTokens": 2688, "cacheWriteTokens": 0,
                ]],
            ]),
            Self.json([
                "turnId": "turn_b", "type": "model_request",
                "timestamp": "2026-07-04T10:00:00.000Z",
                "payload": ["model": "GLM-5.2"],
            ]),
            Self.json([
                "turnId": "turn_b", "type": "model_complete",
                "timestamp": "2026-07-04T10:00:10.000Z",
                "payload": ["usage": [
                    "inputTokens": 1000, "outputTokens": 200,
                    "totalTokens": 1200, "cacheReadTokens": 500, "cacheWriteTokens": 50,
                ]],
            ]),
            Self.json([
                "turnId": "turn_c", "type": "model_request",
                "timestamp": "2026-07-05T11:00:00.000Z",
                "payload": ["model": "GLM-5.2"],
            ]),
            Self.json([
                "turnId": "turn_c", "type": "model_complete",
                "timestamp": "2026-07-05T11:00:30.000Z",
                "payload": ["usage": [
                    "inputTokens": 300, "outputTokens": 100,
                    "totalTokens": 400, "cacheReadTokens": 0, "cacheWriteTokens": 0,
                ]],
            ]),
            // Orphan: usage with no matching model_request → dropped.
            Self.json([
                "turnId": "turn_orphan", "type": "model_complete",
                "timestamp": "2026-07-04T12:00:00.000Z",
                "payload": ["usage": ["inputTokens": 999, "totalTokens": 999]],
            ]),
        ]
        let (scanner, cleanup) = try Self.makeScanner(lines: lines)
        defer { cleanup() }

        let calendar = Self.utcCalendar
        let entries = try scanner.loadDailyEntries(calendar: calendar)

        #expect(entries.count == 2)
        #expect(entries.map(\.date) == ["2026-07-04", "2026-07-05"])

        let day1 = entries[0]
        #expect(day1.inputTokens == 5108) // 4108 + 1000
        #expect(day1.outputTokens == 537) // 337 + 200
        #expect(day1.cacheReadTokens == 3188) // 2688 + 500
        #expect(day1.cacheCreationTokens == 50)
        #expect(day1.totalTokens == 5645) // 4445 + 1200
        #expect(day1.requestCount == 2)

        // Model breakdown: both turns used GLM-5.2 (the builtin: prefix is stripped).
        #expect(day1.modelsUsed == ["GLM-5.2"])
        let model = day1.modelBreakdowns?.first
        #expect(model?.modelName == "GLM-5.2")
        #expect(model?.totalTokens == 5645)
    }

    @Test
    func `since filter bounds the returned days`() throws {
        let lines = [
            Self.json([
                "turnId": "t_old", "type": "model_request",
                "timestamp": "2026-06-01T09:00:00.000Z",
                "payload": ["model": "GLM-5.2"],
            ]),
            Self.json([
                "turnId": "t_old", "type": "model_complete",
                "timestamp": "2026-06-01T09:00:10.000Z",
                "payload": ["usage": ["inputTokens": 100, "totalTokens": 100]],
            ]),
            Self.json([
                "turnId": "t_new", "type": "model_request",
                "timestamp": "2026-07-10T09:00:00.000Z",
                "payload": ["model": "GLM-5.2"],
            ]),
            Self.json([
                "turnId": "t_new", "type": "model_complete",
                "timestamp": "2026-07-10T09:00:10.000Z",
                "payload": ["usage": ["inputTokens": 200, "totalTokens": 200]],
            ]),
        ]
        let (scanner, cleanup) = try Self.makeScanner(lines: lines)
        defer { cleanup() }

        let calendar = Self.utcCalendar
        let since = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let entries = try scanner.loadDailyEntries(since: since, calendar: calendar)

        #expect(entries.count == 1)
        #expect(entries.first?.date == "2026-07-10")
    }

    @Test
    func `normalizeModelName strips builtin prefix`() {
        #expect(ZCodeLocalUsageScanner.normalizeModelName("builtin:bigmodel-coding-plan/GLM-5.2") == "GLM-5.2")
        #expect(ZCodeLocalUsageScanner.normalizeModelName("GLM-5.2") == "GLM-5.2")
        #expect(ZCodeLocalUsageScanner.normalizeModelName("vendor/model-name") == "model-name")
    }

    @Test
    func `missing agents root returns empty`() throws {
        let scanner = ZCodeLocalUsageScanner(
            agentsRoot: URL(fileURLWithPath: "/nonexistent-zcode-test-\(UUID().uuidString)"))
        #expect(try scanner.loadDailyEntries().isEmpty)
    }

    @Test
    func `totalTokens falls back to component sum when absent`() throws {
        let lines = [
            Self.json([
                "turnId": "t", "type": "model_request",
                "timestamp": "2026-07-04T09:00:00.000Z",
                "payload": ["model": "GLM-5.2"],
            ]),
            Self.json([
                "turnId": "t", "type": "model_complete",
                "timestamp": "2026-07-04T09:00:10.000Z",
                // No totalTokens field — scanner must derive it from the components.
                "payload": ["usage": [
                    "inputTokens": 100, "outputTokens": 50,
                    "cacheReadTokens": 20, "cacheWriteTokens": 5,
                ]],
            ]),
        ]
        let (scanner, cleanup) = try Self.makeScanner(lines: lines)
        defer { cleanup() }

        let entries = try scanner.loadDailyEntries(calendar: Self.utcCalendar)
        #expect(entries.first?.totalTokens == 175) // 100 + 50 + 20 + 5
    }

    @Test
    func `defaultAgentsRoot honors ZCODE_HOME`() {
        let tmp = "/tmp/zcode-home-\(UUID().uuidString)"
        let root = ZCodeLocalUsageScanner.defaultAgentsRoot(environment: ["ZCODE_HOME": tmp])
        #expect(root.path == "\(tmp)/cli/agents")
    }

    // MARK: - Helpers

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
#endif
