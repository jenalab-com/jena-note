import Foundation

final class AIClient {
    private let process = AIProcess()
    static let defaultTimeout: TimeInterval = 120
    static let summaryTimeout: TimeInterval = 240
    private(set) var tokenUsage: Int?
    func cancel() { process.cancel() }

    func send(provider: AIProvider, prompt: String, model: String? = nil, timeout: TimeInterval = AIClient.defaultTimeout,
              completion: @escaping (Result<String, Error>) -> Void) {
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
