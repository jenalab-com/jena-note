import Foundation

/// No prompts or inference: only CLI metadata control messages. Credentials remain in the CLI.
final class AIMetadataClient {
    private let process = AIProcess()
    func cancel() { process.cancel() }

    func load(provider: AIProvider, completion: @escaping (Result<AIMetadata, Error>) -> Void) {
        if provider == .local { completion(.success(AIMetadata())); return }
        guard let executable = AISettings.executable(for: provider) else {
            completion(.failure(AIError(message: L10n.tr("ai.notInstalled")))); return
        }
        if provider == .grok {
            process.run(executable: executable, arguments: ["models"], directory: FileManager.default.temporaryDirectory,
                        timeout: 15, environmentOverrides: provider.environmentOverrides) { result in
                completion(result.map { output in
                    var metadata = AIMetadata()
                    if output.status == 0 { metadata.models = AIMetadata.grokModels(from: output.stdout) }
                    return metadata
                })
            }
            return
        }
        guard provider == .claude || provider == .codex else {
            completion(.success(AIMetadata())); return
        }
        let exchange = AIMetadataExchange(provider: provider)
        let arguments = AICommand.metadataArguments(for: provider)
        process.run(executable: executable, arguments: arguments, input: exchange.initial,
                    directory: FileManager.default.temporaryDirectory, timeout: 25, exchange: exchange) { result in
            completion(result.flatMap { output in
                guard output.status == 0, exchange.isComplete else {
                    return .failure(AIError(message: L10n.tr("ai.metadataUnavailable")))
                }
                return .success(provider == .claude
                    ? AIMetadata.claude(models: exchange.models, usage: exchange.usage)
                    : AIMetadata.codex(models: exchange.models, usage: exchange.usage))
            })
        }
    }
}
