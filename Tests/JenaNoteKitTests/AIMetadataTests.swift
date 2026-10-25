import AppKit
import XCTest
@testable import JenaNoteKit

final class AIMetadataTests: XCTestCase {
    func testClaudeUsesActualPeriodsAndDoesNotInventDisabledMonthlyUsage() {
        let value = AIMetadata.claude(models: ["models": [["value": "opus", "displayName": "Opus"]]], usage: [
            "rate_limits": ["five_hour": ["utilization": 0, "resets_at": "2026-10-25T12:00:00Z"],
                            "seven_day": ["utilization": 28],
                            "extra_usage": ["is_enabled": false, "utilization": NSNull()]]
        ])
        XCTAssertEqual(value.models.map(\.id), ["opus"])
        XCTAssertEqual(value.quotas.map(\.usedPercent), [0, 28], "An actual zero is valid, but missing monthly data isn't zero")
        XCTAssertNotNil(value.quotas[0].resetsAt)
        XCTAssertTrue(value.usageAvailable)
        XCTAssertFalse(AIMetadata.claude(models: [:], usage: [:]).usageAvailable)
        let scoped = AIMetadata.claude(models: [:], usage: ["rate_limits": ["limits": [
            ["group": "weekly", "percent": 51, "scope": ["model": ["display_name": "Fable"]]]
        ]]])
        XCTAssertTrue(scoped.quotas[0].title.contains("Fable"))
    }

    func testCodexPrimaryCanBeWeeklyAndMultipleBucketsAreNotLost() {
        let value = AIMetadata.codex(models: ["data": [["model": "available-model", "hidden": false],
                                                       ["model": "hidden-model", "hidden": true]]], usage: [
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 16, "windowDurationMins": 10080, "resetsAt": 1793515577]],
                "other": ["limitName": "Other", "primary": ["usedPercent": 30, "windowDurationMins": 300]]
            ]
        ])
        XCTAssertEqual(value.models.map(\.id), ["available-model"])
        XCTAssertEqual(value.quotas.count, 2)
        XCTAssertEqual(value.quotas[0].title, L10n.tr("ai.quotaWeekly"), "Primary doesn't always mean five hours")
        XCTAssertTrue(value.quotas[1].title.contains("Other"))
    }

    func testTokenAccountingDoesNotDoubleCountCachedOrReasoningTokens() {
        XCTAssertEqual(AIClient.tokens(from: """
        {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20}}
        """, provider: .codex), 120)
        XCTAssertEqual(AIClient.tokens(from: """
        {"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":20,"cache_creation_input_tokens":7}}
        """, provider: .claude), 42)
        XCTAssertEqual(AIClient.tokens(from: """
        {"stats":{"models":{"main":{"tokens":{"total":120,"thoughts":20}},"fallback":{"tokens":{"total":10}}}}}
        """, provider: .gemini), 130)
        XCTAssertEqual(AIClient.tokens(from: """
        {"usage":{"total_tokens":150,"reasoning_tokens":20}}
        """, provider: .grok), 150)
        XCTAssertNil(AIClient.tokens(from: "{}", provider: .claude))
    }

    func testModelIsPassedAsSingleArgumentAndProviderPreferenceIsSeparate() {
        let policy = URL(fileURLWithPath: "/tmp/policy")
        let unusualModel = "model;$(echo nope)"
        for provider in AIProvider.allCases {
            let args = AIClient.arguments(for: provider, policy: policy, model: unusualModel)
            let index = args.firstIndex(of: "--model")!
            XCTAssertEqual(args[index + 1], unusualModel)
            XCTAssertFalse(AIClient.arguments(for: provider, policy: policy, model: "").contains("--model"))
            if provider == .codex { XCTAssertEqual(args.last, "-") }
        }
        let oldClaude = AISettings.model(for: .claude), oldCodex = AISettings.model(for: .codex)
        defer { AISettings.setModel(oldClaude, for: .claude); AISettings.setModel(oldCodex, for: .codex) }
        AISettings.setModel("opus", for: .claude)
        AISettings.setModel("account-model", for: .codex)
        XCTAssertEqual(AISettings.model(for: .claude), "opus")
        XCTAssertEqual(AISettings.model(for: .codex), "account-model")
    }

    func testInteractiveMetadataHandshakeWaitsForResponsesWithoutInference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("metadata")
        try """
        #!/bin/sh
        read -r initialize
        echo '{"id":1,"result":{}}'
        read -r initialized
        read -r models
        read -r usage
        echo '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300}}}}'
        echo '{"id":2,"result":{"data":[{"model":"fixture-model"}]}}'
        # Parent must finish once all replies arrive, without waiting for EOF.
        sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let exchange = AIMetadataExchange(provider: .codex)
        let done = expectation(description: "Metadata responds without a chat turn")
        let process = AIProcess()
        process.run(executable: script, arguments: [], input: exchange.initial, timeout: 3, exchange: exchange) { result in
            switch result {
            case .success:
                let metadata = AIMetadata.codex(models: exchange.models, usage: exchange.usage)
                XCTAssertEqual(metadata.models.first?.id, "fixture-model")
                XCTAssertEqual(metadata.quotas.first?.usedPercent, 12)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testClaudeControlExchangeKeepsModelListWhenUsageIsUnsupported() {
        let exchange = AIMetadataExchange(provider: .claude)
        let reply = exchange.receive("""
        {"type":"control_response","response":{"subtype":"success","request_id":"init","response":{"models":[{"value":"sonnet"}]}}}
        """)
        XCTAssertTrue(reply?.contains("get_usage") == true)
        XCTAssertFalse(exchange.isComplete)
        _ = exchange.receive("""
        {"type":"control_response","response":{"subtype":"error","request_id":"usage","error":"unsupported"}}
        """)
        XCTAssertTrue(exchange.isComplete)
        let metadata = AIMetadata.claude(models: exchange.models, usage: exchange.usage)
        XCTAssertEqual(metadata.models.first?.id, "sonnet")
        XCTAssertFalse(metadata.usageAvailable)
    }

    func testClientSendsSelectedModelAndReportsTokens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = AISettings.customPath(for: .claude)
        defer { AISettings.setPath(previous, for: .claude); try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        let argumentsFile = directory.appendingPathComponent("arguments")
        let script = "#!/bin/sh\nif [ \"$2\" != \"--output-format\" ]; then exit 0; fi\nprintf '%s\\n' \"$@\" > " + AITerminal.quote(argumentsFile.path)
            + "\ncat >/dev/null\necho '{\"result\":\"answer\",\"usage\":{\"input_tokens\":12,\"output_tokens\":3}}'\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        AISettings.setPath(executable.path, for: .claude)
        let client = AIClient()
        let done = expectation(description: "Selected model reaches the CLI")
        client.send(provider: .claude, prompt: "request", model: "sonnet") { result in
            XCTAssertEqual(try? result.get(), "answer")
            XCTAssertEqual(client.tokenUsage, 15)
            XCTAssertTrue((try? String(contentsOf: argumentsFile, encoding: .utf8))?.contains("--model\nsonnet\n") == true)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testLoaderIsInsideScrollableConversationAfterLastMessage() {
        _ = NSApplication.shared
        let transcript = AIChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let loading = NSView()
        transcript.setLoadingView(loading)
        transcript.setMessages([.init(role: "user", text: "request")])
        XCTAssertTrue(loading.superview === transcript.documentView)
        XCTAssertGreaterThan(loading.frame.minY, transcript.messageViews[0].frame.maxY)
        loading.isHidden = true
        transcript.setMessages([.init(role: "user", text: "request"), .init(role: "assistant", text: "reply")])
        XCTAssertTrue(loading.isHidden)
    }
}
