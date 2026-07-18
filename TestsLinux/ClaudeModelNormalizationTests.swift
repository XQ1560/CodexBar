import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

#if os(Linux)
struct ClaudeModelNormalizationTests {
    @Test
    func `claude version hyphen becomes dot`() {
        // Fork: Anthropic ids like claude-opus-4-8 display as claude-opus-4.8.
        #expect(CostUsagePricing.normalizeClaudeModel("claude-opus-4-8") == "claude-opus-4.8")
        #expect(CostUsagePricing.normalizeClaudeModel("claude-haiku-4-5") == "claude-haiku-4.5")
        #expect(CostUsagePricing.normalizeClaudeModel("claude-sonnet-4-6") == "claude-sonnet-4.6")
    }

    @Test
    func `claude dated suffix is stripped after version dot rewrite`() {
        // Real jsonl carries a date suffix: claude-haiku-4-5-20251001. The version rewrite
        // must run before the dated-suffix short-circuit, otherwise the pricing-table hit
        // returns the hyphen form and the dot rewrite never fires.
        #expect(CostUsagePricing.normalizeClaudeModel("claude-haiku-4-5-20251001") == "claude-haiku-4.5")
        #expect(CostUsagePricing.normalizeClaudeModel("claude-opus-4-8-20251001") == "claude-opus-4.8")
    }

    @Test
    func `claude family hyphen is preserved`() {
        // The family separator (claude-opus) must stay a hyphen; only the version
        // major/minor separator turns into a dot.
        let result = CostUsagePricing.normalizeClaudeModel("claude-opus-4-8")
        #expect(result.hasPrefix("claude-opus-"))
        #expect(result == "claude-opus-4.8")
    }

    @Test
    func `claude ids without version pair are unchanged`() {
        #expect(CostUsagePricing.normalizeClaudeModel("claude-fable-5") == "claude-fable-5")
        #expect(CostUsagePricing.normalizeClaudeModel("gpt-5.5") == "gpt-5.5")
    }

    @Test
    func `claude anthropic prefix is stripped`() {
        // Existing behavior must still work after the fork change.
        #expect(CostUsagePricing.normalizeClaudeModel("anthropic.claude-opus-4-8") == "claude-opus-4.8")
    }

    @Test
    func `unknown model displays as unspecified`() {
        #expect(CLIWatchTrendRenderer.displayName(forModel: "unknown") == "(unspecified)")
        #expect(CLIWatchTrendRenderer.displayName(forModel: "") == "(unspecified)")
        #expect(CLIWatchTrendRenderer.displayName(forModel: "gpt-5.5") == "gpt-5.5")
    }
}
#endif
