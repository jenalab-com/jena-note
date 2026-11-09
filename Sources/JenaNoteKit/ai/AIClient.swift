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
            try AICommand.denyAllToolsPolicy.write(to: policy, atomically: true, encoding: .utf8)
            let geminiDirectory = directory.appendingPathComponent(".gemini", isDirectory: true)
            try FileManager.default.createDirectory(at: geminiDirectory, withIntermediateDirectories: true)
            try AICommand.geminiSettings.write(
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
        AICommand.arguments(for: provider, policyPath: policy.path, model: model)
    }

    static func tokens(from text: String, provider: AIProvider) -> Int? {
        AICommand.tokens(from: text, provider: provider)
    }

    static func answer(from output: AIProcessOutput, provider: AIProvider) throws -> String {
        try AICommand.answer(from: output, provider: provider)
    }
}
