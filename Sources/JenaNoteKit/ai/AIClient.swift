import Foundation

final class AIClient {
    private let process = AIProcess()
    static let defaultTimeout: TimeInterval = 120
    static let summaryTimeout: TimeInterval = 240
    /// A 12B model on an M1 produces about 10 tokens/s, and it reasons before it answers.
    static let localTimeout: TimeInterval = 600
    private(set) var tokenUsage: Int?
    private var localTask: URLSessionDataTask?
    func cancel() { process.cancel(); localTask?.cancel() }

    func send(provider: AIProvider, prompt: String, model: String? = nil, timeout: TimeInterval = AIClient.defaultTimeout,
              completion: @escaping (Result<String, Error>) -> Void) {
        if provider == .local {
            sendToLocalServer(prompt: prompt, model: model, timeout: max(timeout, Self.localTimeout), completion: completion)
            return
        }
        guard let executable = AISettings.executable(for: provider) else {
            completion(.failure(AIError(message: L10n.tr("ai.notInstalled"))))
            return
        }
        do {
            if provider == .grok {
                try FileManager.default.createDirectory(at: AISettings.grokProfile, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JenaNote-AI-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let policy = directory.appendingPathComponent("deny-tools.toml")
            try "[[rule]]\ntoolName = \"*\"\ndecision = \"deny\"\npriority = 999\n".write(to: policy, atomically: true, encoding: .utf8)
            let geminiDirectory = directory.appendingPathComponent(".gemini", isDirectory: true)
            try FileManager.default.createDirectory(at: geminiDirectory, withIntermediateDirectories: true)
            try "{\"hooksConfig\":{\"enabled\":false},\"mcp\":{\"allowed\":[]},\"tools\":{\"core\":[]}}".write(
                to: geminiDirectory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            process.run(executable: executable, arguments: Self.arguments(for: provider, policy: policy, model: model),
                        input: prompt, directory: directory, timeout: timeout,
                        environmentOverrides: provider.environmentOverrides) { result in
                // This folder is created solely for this request, never the user's note folder.
                try? FileManager.default.removeItem(at: directory)
                completion(result.flatMap { output in
                    Result {
                        self.tokenUsage = Self.tokens(from: output.stdout, provider: provider)
                        return try Self.answer(from: output, provider: provider)
                    }
                })
            }
        } catch { completion(.failure(error)) }
    }

    private func sendToLocalServer(prompt: String, model: String?, timeout: TimeInterval,
                                   completion: @escaping (Result<String, Error>) -> Void) {
        guard let server = AISettings.localServerURL else {
            completion(.failure(AIError(message: L10n.tr("ai.local.invalidAddress")))); return
        }
        do {
            let request = try Self.localRequest(server: server, prompt: prompt, model: model, timeout: timeout)
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    completion(Result {
                        if let error { throw Self.localFailure(error) }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let reply = try Self.localReply(from: data ?? Data(), status: status)
                        self.tokenUsage = reply.tokens
                        return reply.text
                    })
                }
            }
            localTask = task
            task.resume()
        } catch { completion(.failure(error)) }
    }

    static func localRequest(server: URL, prompt: String, model: String?, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent("v1/chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["messages": [["role": "user", "content": prompt]], "stream": false]
        if let model, !model.isEmpty { body["model"] = model }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func localFailure(_ error: Error) -> AIError {
        switch (error as? URLError)?.code {
        case .cancelled: return AIError(message: L10n.tr("ai.cancelled"))
        case .timedOut: return AIError(message: L10n.tr("ai.local.timeout"))
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return AIError(message: L10n.tr("ai.local.notRunning"))
        default: return AIError(message: error.localizedDescription)
        }
    }

    static func localReply(from data: Data, status: Int) throws -> (text: String, tokens: Int?) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let detail = (root?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(1800), as: UTF8.self)
            throw AIError(message: L10n.tr("ai.local.requestFailed") + "\n" + detail)
        }
        let choice = (root?["choices"] as? [[String: Any]])?.first
        // Reasoning arrives in `reasoning_content`; only the final answer belongs in the chat.
        guard let text = (choice?["message"] as? [String: Any])?["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError(message: L10n.tr("ai.invalidResponse"))
        }
        return (text, (root?["usage"] as? [String: Any])?["total_tokens"] as? Int)
    }

    static func arguments(for provider: AIProvider, policy: URL, model: String? = nil) -> [String] {
        let base = baseArguments(for: provider, policy: policy)
        guard let model = model, !model.isEmpty else { return base }
        // Insert before stdin's positional '-' and pass as one argv value, never shell code.
        if provider == .codex { return Array(base.dropLast()) + ["--model", model, "-"] }
        return base + ["--model", model]
    }

    private static func baseArguments(for provider: AIProvider, policy: URL) -> [String] {
        switch provider {
        case .claude:
            return ["-p", "--output-format", "json", "--tools", "", "--strict-mcp-config",
                    "--disable-slash-commands", "--no-session-persistence", "--safe-mode"]
        case .codex:
            return ["-a", "never", "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
                    "--sandbox", "read-only", "--skip-git-repo-check", "--disable", "shell_tool", "--disable", "hooks", "--disable", "multi_agent", "--disable", "apps",
                    "-c", "web_search=\"disabled\"", "--json", "-"]
        case .gemini:
            return ["--prompt", "Follow the request on stdin.", "--output-format", "json",
                    "--approval-mode", "plan", "--policy", policy.path, "--extensions", "none", "--skip-trust"]
        case .grok:
            return ["--prompt-file", "/dev/stdin", "--output-format", "json", "--max-turns", "1", "--tools", "",
                    "--disable-web-search", "--no-subagents", "--permission-mode", "dontAsk",
                    "--deny", "MCPTool", "--sandbox", "read-only"]
        case .local:
            return []
        }
    }

    static func tokens(from text: String, provider: AIProvider) -> Int? {
        func object(_ text: String) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        if provider == .codex {
            let event = text.split(separator: "\n").compactMap { object(String($0)) }.last { $0["type"] as? String == "turn.completed" }
            guard let usage = event?["usage"] as? [String: Any], let input = usage["input_tokens"] as? Int,
                  let output = usage["output_tokens"] as? Int else { return nil }
            return max(0, input) + max(0, output) // cached_input_tokens is already part of input_tokens.
        }
        guard let root = object(text) else { return nil }
        if provider == .gemini {
            guard let stats = root["stats"] as? [String: Any], let models = stats["models"] as? [String: [String: Any]] else { return nil }
            let totals = models.values.compactMap { ($0["tokens"] as? [String: Any])?["total"] as? Int }
            return totals.isEmpty ? nil : totals.reduce(0) { $0 + max(0, $1) }
        }
        guard let usage = root["usage"] as? [String: Any] else { return nil }
        if let total = usage["total_tokens"] as? Int { return max(0, total) }
        let keys = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        let values = keys.compactMap { usage[$0] as? Int }
        return values.isEmpty ? nil : values.reduce(0) { $0 + max(0, $1) }
    }

    static func answer(from output: AIProcessOutput, provider: AIProvider) throws -> String {
        guard output.status == 0 else {
            // Keep diagnostic output bounded; never display environment or authentication files.
            let diagnostic = output.stderr.isEmpty ? output.stdout : output.stderr
            throw AIError(message: L10n.tr("ai.cliFailed") + "\n" + String(diagnostic.suffix(1800)))
        }
        let text: String
        if provider == .grok {
            guard let object = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any],
                  object["stopReason"] as? String == "end_turn", (object["num_turns"] as? Int ?? 1) <= 1, let message = object["text"] as? String else {
                throw AIError(message: L10n.tr("ai.grokIncomplete"))
            }
            text = message
        } else if provider == .codex {
            var messages: [String] = []
            var complete = false
            for line in output.stdout.split(separator: "\n") {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let type = event["type"] as? String
                if type == "turn.failed" || type == "error" { throw AIError(message: L10n.tr("ai.cliFailed")) }
                if type == "turn.completed" { complete = true }
                if type == "item.completed", let item = event["item"] as? [String: Any],
                   item["type"] as? String == "agent_message", let message = item["text"] as? String {
                    messages.append(message)
                }
            }
            guard complete else { throw AIError(message: L10n.tr("ai.incomplete")) }
            text = messages.joined(separator: "\n")
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any],
                  object["is_error"] as? Bool != true, object["error"] == nil,
                  let message = object[provider == .claude ? "result" : "response"] as? String else {
                throw AIError(message: L10n.tr("ai.invalidResponse"))
            }
            text = message
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError(message: L10n.tr("ai.invalidResponse"))
        }
        return text
    }
}
