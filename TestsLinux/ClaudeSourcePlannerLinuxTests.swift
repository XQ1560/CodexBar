import Foundation
import Testing
@testable import CodexBarCore

#if os(Linux)
// Linux mirror of Tests/CodexBarTests/ClaudeSourcePlannerTests.swift — CodexBarTests is
// macOS-only (depends on the CodexBar app target), so the fork-specific CLI auto OAuth
// preference is asserted here too. The planner itself lives in CodexBarCore (cross-platform).
struct ClaudeSourcePlannerLinuxTests {
    @Test
    func `CLI auto plan keeps web cli order without OAuth credentials`() {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .cli,
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: false))

        #expect(plan.orderedSteps.map(\.dataSource) == [.web, .cli])
        #expect(plan.orderedSteps.map(\.inclusionReason) == [
            .cliAutoPreferredWeb,
            .cliAutoFallbackCLI,
        ])
        #expect(plan.preferredStep?.dataSource == .web)
    }

    @Test
    func `CLI auto plan prefers OAuth when credentials are available`() {
        // Fork: when OAuth credentials are available, CLI auto prefers OAuth over the
        // brittle CLI PTY fallback (some Claude Code 2.1.x output shapes fail to parse).
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .cli,
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: true))

        #expect(plan.orderedSteps.map(\.dataSource) == [.oauth, .web, .cli])
        #expect(plan.orderedSteps.map(\.inclusionReason) == [
            .cliAutoPreferredOAuth,
            .cliAutoPreferredWeb,
            .cliAutoFallbackCLI,
        ])
        #expect(plan.availableSteps.map(\.dataSource) == [.oauth, .web, .cli])
        #expect(plan.preferredStep?.dataSource == .oauth)
    }
}
#endif
