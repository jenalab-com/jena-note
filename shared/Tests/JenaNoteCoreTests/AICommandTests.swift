import XCTest
@testable import JenaNoteCore

final class AICommandTests: XCTestCase {
    func testModelIsOneArgumentBeforeCodexStdinMarker() {
        let model = "gpt; rm -rf /"
        for provider in AIProvider.allCases {
            let arguments = AICommand.arguments(for: provider, policyPath: "/p", model: model)
            XCTAssertEqual(arguments[arguments.firstIndex(of: "--model")! + 1], model)
            XCTAssertFalse(AICommand.arguments(for: provider, policyPath: "/p", model: "").contains("--model"))
        }
        XCTAssertEqual(AICommand.arguments(for: .codex, policyPath: "/p", model: "m").last, "-")
    }

    func testGrokPromptFileAndGeminiPolicyAreSubstituted() {
        let grok = AICommand.arguments(for: .grok, policyPath: "/p", promptFile: "C:\\t\\prompt.txt")
        XCTAssertEqual(grok[grok.firstIndex(of: "--prompt-file")! + 1], "C:\\t\\prompt.txt")
        XCTAssertEqual(AICommand.arguments(for: .grok, policyPath: "/p")[1], "/dev/stdin")
        let gemini = AICommand.arguments(for: .gemini, policyPath: "C:\\t\\deny.toml")
        XCTAssertEqual(gemini[gemini.firstIndex(of: "--policy")! + 1], "C:\\t\\deny.toml")
    }

    func testEveryProviderForbidsToolsAndAutomation() {
        XCTAssertTrue(AICommand.arguments(for: .claude, policyPath: "").contains("--safe-mode"))
        XCTAssertTrue(AICommand.arguments(for: .codex, policyPath: "").contains("read-only"))
        XCTAssertTrue(AICommand.arguments(for: .gemini, policyPath: "").contains("plan"))
        XCTAssertTrue(AICommand.arguments(for: .grok, policyPath: "").contains("dontAsk"))
        XCTAssertEqual(AICommand.environment["GROK_CODEX_HOOKS_ENABLED"], "0")
        XCTAssertEqual(AICommand.removedEnvironment, ["CLAUDECODE"])
    }

    func testAnswersFromEachProvider() throws {
        func output(_ text: String, status: Int32 = 0) -> AIProcessOutput { AIProcessOutput(status: status, stdout: text, stderr: "") }
        XCTAssertEqual(try AICommand.answer(from: output("{\"result\":\"a\"}"), provider: .claude), "a")
        XCTAssertEqual(try AICommand.answer(from: output("{\"response\":\"b\"}"), provider: .gemini), "b")
        XCTAssertEqual(try AICommand.answer(from: output("{\"stopReason\":\"end_turn\",\"text\":\"c\"}"), provider: .grok), "c")
        let codex = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"d\"}}\n{\"type\":\"turn.completed\"}"
        XCTAssertEqual(try AICommand.answer(from: output(codex), provider: .codex), "d")
        XCTAssertThrowsError(try AICommand.answer(from: output("{\"is_error\":true,\"result\":\"x\"}"), provider: .claude))
        XCTAssertThrowsError(try AICommand.answer(from: output("{\"result\":\"  \"}"), provider: .claude))
        XCTAssertThrowsError(try AICommand.answer(from: output("{\"type\":\"item.completed\"}"), provider: .codex))
        XCTAssertThrowsError(try AICommand.answer(from: output("no", status: 1), provider: .claude))
    }

    func testTokenCounts() {
        XCTAssertEqual(AICommand.tokens(from: "{\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}", provider: .claude), 7)
        XCTAssertEqual(AICommand.tokens(from: "{\"usage\":{\"total_tokens\":9}}", provider: .grok), 9)
        XCTAssertEqual(AICommand.tokens(from: "{\"stats\":{\"models\":{\"m\":{\"tokens\":{\"total\":5}}}}}", provider: .gemini), 5)
        XCTAssertEqual(AICommand.tokens(from: "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}", provider: .codex), 3)
        XCTAssertNil(AICommand.tokens(from: "{}", provider: .claude))
    }

    func testPromptSizeAndModes() throws {
        let guide = try AIChatPrompt.make(document: "본문", selectedText: "", messages: [AIChatMessage(role: "user", text: "앞")], request: "질문", mode: .guide)
        XCTAssertTrue(guide.hasPrefix("You are JenaNote's writing assistant."))
        XCTAssertTrue(guide.contains("Give writing advice"))
        XCTAssertTrue(guide.contains("질문"))
        let edit = try AIChatPrompt.make(document: "본문", selectedText: "본", messages: [], request: "고쳐", mode: .edit)
        XCTAssertTrue(edit.contains("Return ONLY a JSON object"))
        XCTAssertThrowsError(try AIChatPrompt.make(document: String(repeating: "x", count: 500_001), selectedText: "", messages: [], request: "", mode: .guide))
    }

    func testEditAnswers() throws {
        XCTAssertThrowsError(try AIChatPrompt.parseEdit("Here is the answer"))
        XCTAssertThrowsError(try AIChatPrompt.parseEdit("{\"explanation\":\"x\"}"))
        XCTAssertNil(try AIChatPrompt.parseEdit("{\"explanation\":\"x\",\"replacement\":null}").replacement)
        XCTAssertEqual(try AIChatPrompt.parseEdit("```json\n{\"explanation\":\"x\",\"replacement\":\"y\"}\n```").replacement, "y")
    }

    func testMetadataFromClaudeAndCodex() {
        let claude = AIMetadata.claude(models: ["models": [["value": "opus", "displayName": "Opus"], ["value": "default"]]],
                                       usage: ["rate_limits": ["limits": [["group": "session", "percent": 12.5, "resets_at": 1_000]]]])
        XCTAssertEqual(claude.models.map(\.id), ["opus"])
        XCTAssertTrue(claude.usageAvailable)
        XCTAssertEqual(claude.quotas.first?.usedPercent, 12.5)
        XCTAssertFalse(AIMetadata.claude(models: [:], usage: [:]).usageAvailable)
        let codex = AIMetadata.codex(models: ["data": [["model": "m", "hidden": false], ["model": "h", "hidden": true]]],
                                     usage: ["rateLimits": ["primary": ["usedPercent": 30, "windowDurationMins": 300]]])
        XCTAssertEqual(codex.models.map(\.id), ["m"])
        XCTAssertEqual(codex.quotas.first?.usedPercent, 30)
        XCTAssertEqual(AIMetadata.grokModels(from: "  * grok-4  x\n  - grok-3 y\nheader line\n").map(\.id), ["grok-4", "grok-3"])
    }

    func testMetadataExchangeWithClaude() {
        let exchange = AIMetadataExchange(provider: .claude)
        XCTAssertTrue(exchange.initial.contains("initialize"))
        let reply = exchange.receive("{\"type\":\"control_response\",\"response\":{\"request_id\":\"init\",\"response\":{\"models\":[]}}}")
        XCTAssertTrue(reply?.contains("get_usage") == true)
        XCTAssertFalse(exchange.isComplete)
        XCTAssertNil(exchange.receive("{\"type\":\"control_response\",\"response\":{\"request_id\":\"usage\",\"response\":{}}}"))
        XCTAssertTrue(exchange.isComplete)
        XCTAssertNil(exchange.receive("not json"))
    }

    func testQuotaText() {
        let now = Date(timeIntervalSince1970: 0)
        let quota = AIQuota(title: "t", usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 3_660))
        XCTAssertEqual(quota.resetCountdown(now: now), "1h 1m")
        XCTAssertEqual(quota.compactSummary(now: now), "40% 1h 1m")
        XCTAssertEqual(quota.summary, "t 40%")
    }
}
