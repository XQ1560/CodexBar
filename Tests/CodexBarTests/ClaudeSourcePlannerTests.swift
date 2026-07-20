import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSourcePlannerTests {
    @Test
    func `app auto plan preserves ordered steps and reasons`() {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: true))

        #expect(plan.orderedSteps.map(\.dataSource) == [.oauth, .cli, .web])
        #expect(plan.orderedSteps.map(\.inclusionReason) == [
            .appAutoPreferredOAuth,
            .appAutoFallbackCLI,
            .appAutoFallbackWeb,
        ])
        #expect(plan.availableSteps.map(\.dataSource) == [.oauth, .cli, .web])
        #expect(plan.preferredStep?.dataSource == .oauth)
    }

    @Test
    func `CLI auto plan preserves ordered steps and reasons`() {
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

    @Test
    func `explicit mode plan is single step`() {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: .cli,
            webExtrasEnabled: true,
            hasWebSession: false,
            hasCLI: true,
            hasOAuthCredentials: false))

        #expect(plan.orderedSteps.count == 1)
        #expect(plan.orderedSteps.first?.dataSource == .cli)
        #expect(plan.orderedSteps.first?.inclusionReason == .explicitSourceSelection)
        #expect(plan.compatibilityStrategy == ClaudeUsageStrategy(dataSource: .cli, useWebExtras: true))
    }

    @Test
    func `app auto CLI fallback reports web extras like runtime`() {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: .auto,
            webExtrasEnabled: true,
            hasWebSession: false,
            hasCLI: true,
            hasOAuthCredentials: false))

        #expect(plan.preferredStep?.dataSource == .cli)
        #expect(plan.compatibilityStrategy == ClaudeUsageStrategy(dataSource: .cli, useWebExtras: true))
    }

    @Test
    func `no source planner output is deterministic`() {
        let input = ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: false,
            hasCLI: false,
            hasOAuthCredentials: false)
        let plan = ClaudeSourcePlanner.resolve(input: input)

        #expect(plan.orderedSteps.map(\.dataSource) == [.oauth, .cli, .web])
        #expect(plan.availableSteps.isEmpty)
        #expect(plan.isNoSourceAvailable)
        #expect(plan.preferredStep == nil)
        #expect(plan.executionSteps.isEmpty)
        #expect(plan.debugLines() == [
            "planner_order=oauth→cli→web",
            "planner_selected=none",
            "planner_no_source=true",
            "planner_step.oauth=unavailable reason=app-auto-preferred-oauth",
            "planner_step.cli=unavailable reason=app-auto-fallback-cli",
            "planner_step.web=unavailable reason=app-auto-fallback-web",
        ])
    }

    @Test
    func `CLI resolver falls back to PATH when Claude CLI path override is invalid`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let binaryURL = tempDir.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let resolved = ClaudeCLIResolver.resolvedBinaryPath(
            environment: [
                "CLAUDE_CLI_PATH": "/definitely/missing/claude",
                "PATH": tempDir.path,
            ],
            loginPATH: nil)

        #expect(resolved == binaryURL.path)
    }
}
