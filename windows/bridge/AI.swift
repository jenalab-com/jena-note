import Foundation
import JenaNoteCore

// CLI requests for the Windows app. The app starts the processes. What to pass them and how to read
// their answers stays here, shared with macOS. See Bridge.swift for the conventions.

private func encode(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func report(_ failure: Error, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    error.pointee = duplicate((failure as? AIError)?.message ?? String(describing: failure))
    return -1
}

private func provider(_ name: UnsafePointer<CChar>) throws -> AIProvider {
    guard let value = AIProvider(rawValue: String(cString: name)) else { throw AIError(message: "unknown provider") }
    return value
}

@_cdecl("jena_ai_providers")
public func jena_ai_providers() -> UnsafeMutablePointer<CChar>? {
    // Local (llama.cpp) runs a server only the macOS app manages yet.
    let list: [[String: Any]] = AIProvider.allCases.filter { $0 != .local }.map {
        ["id": $0.rawValue, "title": $0.title, "documentation": $0.documentation.absoluteString, "loginArguments": $0.loginArguments]
    }
    return duplicate((try? encode(list)) ?? "[]")
}

/// The result is `{"arguments", "environment", "removedEnvironment", "denyPolicy", "geminiSettings"}`.
@_cdecl("jena_ai_command")
public func jena_ai_command(_ name: UnsafePointer<CChar>, _ policyPath: UnsafePointer<CChar>, _ promptFile: UnsafePointer<CChar>,
                            _ model: UnsafePointer<CChar>?, _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                            _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let arguments = AICommand.arguments(for: try provider(name), policyPath: String(cString: policyPath),
                                            model: model.map { String(cString: $0) }, promptFile: String(cString: promptFile))
        result.pointee = duplicate(try encode([
            "arguments": arguments, "environment": AICommand.environment, "removedEnvironment": AICommand.removedEnvironment,
            "denyPolicy": AICommand.denyAllToolsPolicy, "geminiSettings": AICommand.geminiSettings,
        ] as [String: Any]))
        return 0
    } catch let failure { return report(failure, error) }
}

/// The result is `{"text", "tokens"}`, where tokens may be missing.
@_cdecl("jena_ai_answer")
public func jena_ai_answer(_ name: UnsafePointer<CChar>, _ status: Int32, _ stdout: UnsafePointer<CChar>, _ stderr: UnsafePointer<CChar>,
                           _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                           _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let which = try provider(name)
        let out = String(cString: stdout)
        var answer: [String: Any] = [:]
        if let tokens = AICommand.tokens(from: out, provider: which) { answer["tokens"] = tokens }
        do {
            answer["text"] = try AICommand.answer(from: AIProcessOutput(status: status, stdout: out, stderr: String(cString: stderr)), provider: which)
        } catch let failure {
            // Tokens were spent even when the answer cannot be used.
            answer["error"] = (failure as? AIError)?.message ?? String(describing: failure)
        }
        result.pointee = duplicate(try encode(answer))
        return 0
    } catch let failure { return report(failure, error) }
}

/// `request` is `{"document", "selectedText", "history": [{"role", "text"}], "request", "mode": "guide"|"edit"}`.
@_cdecl("jena_ai_prompt")
public func jena_ai_prompt(_ request: UnsafePointer<CChar>, _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                           _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let object = try JSONSerialization.jsonObject(with: Data(String(cString: request).utf8)) as? [String: Any] ?? [:]
        let history = (object["history"] as? [[String: Any]] ?? []).map {
            AIChatMessage(role: $0["role"] as? String ?? "", text: $0["text"] as? String ?? "")
        }
        result.pointee = duplicate(try AIChatPrompt.make(
            document: object["document"] as? String ?? "", selectedText: object["selectedText"] as? String ?? "",
            messages: history, request: object["request"] as? String ?? "",
            mode: object["mode"] as? String == "edit" ? .edit : .guide))
        return 0
    } catch let failure { return report(failure, error) }
}

/// The result is `{"explanation", "replacement"}`, where replacement may be null.
@_cdecl("jena_ai_parse_edit")
public func jena_ai_parse_edit(_ answer: UnsafePointer<CChar>, _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                               _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let edit = try AIChatPrompt.parseEdit(String(cString: answer))
        result.pointee = duplicate(try encode(["explanation": edit.explanation, "replacement": edit.replacement ?? NSNull()] as [String: Any]))
        return 0
    } catch let failure { return report(failure, error) }
}

// MARK: - Models and account usage

private func metadataJSON(_ metadata: AIMetadata, provider: AIProvider) -> String {
    let models = metadata.models.isEmpty
        ? AIMetadata.fallbackModels(for: provider).map { ["id": $0, "title": $0] }
        : metadata.models.map { ["id": $0.id, "title": $0.title] }
    let quotas: [[String: Any]] = metadata.quotas.map {
        ["title": $0.title, "summary": $0.summary, "percent": $0.usedPercent, "modelName": $0.modelName ?? NSNull(),
         "resetsAt": $0.resetsAt?.timeIntervalSince1970 ?? NSNull()]
    }
    return (try? encode(["models": models, "quotas": quotas, "usageAvailable": metadata.usageAvailable] as [String: Any])) ?? "{}"
}

@_cdecl("jena_ai_metadata_arguments")
public func jena_ai_metadata_arguments(_ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    guard let which = AIProvider(rawValue: String(cString: name)) else { return duplicate("[]") }
    return duplicate((try? encode(AICommand.metadataArguments(for: which))) ?? "[]")
}

@_cdecl("jena_ai_metadata_open")
public func jena_ai_metadata_open(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    guard let which = AIProvider(rawValue: String(cString: name)) else { return nil }
    return Unmanaged.passRetained(AIMetadataExchange(provider: which)).toOpaque()
}

private func exchange(_ handle: UnsafeMutableRawPointer) -> AIMetadataExchange {
    Unmanaged<AIMetadataExchange>.fromOpaque(handle).takeUnretainedValue()
}

@_cdecl("jena_ai_metadata_initial")
public func jena_ai_metadata_initial(_ handle: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>? {
    duplicate(exchange(handle).initial)
}

/// The reply to send, or null. `complete` becomes 1 when every answer has arrived.
@_cdecl("jena_ai_metadata_receive")
public func jena_ai_metadata_receive(_ handle: UnsafeMutableRawPointer, _ line: UnsafePointer<CChar>,
                                     _ complete: UnsafeMutablePointer<Int32>) -> UnsafeMutablePointer<CChar>? {
    let current = exchange(handle)
    let reply = current.receive(String(cString: line))
    complete.pointee = current.isComplete ? 1 : 0
    return reply.flatMap { duplicate($0) }
}

@_cdecl("jena_ai_metadata_result")
public func jena_ai_metadata_result(_ handle: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>? {
    let current = exchange(handle)
    let metadata = current.provider == .claude
        ? AIMetadata.claude(models: current.models, usage: current.usage)
        : AIMetadata.codex(models: current.models, usage: current.usage)
    return duplicate(metadataJSON(metadata, provider: current.provider))
}

@_cdecl("jena_ai_metadata_close")
public func jena_ai_metadata_close(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<AIMetadataExchange>.fromOpaque(handle).release()
}

/// A CLI without a metadata exchange. `output` is what `grok models` printed, or empty.
@_cdecl("jena_ai_metadata_plain")
public func jena_ai_metadata_plain(_ name: UnsafePointer<CChar>, _ output: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    guard let which = AIProvider(rawValue: String(cString: name)) else { return duplicate("{}") }
    var metadata = AIMetadata()
    if which == .grok { metadata.models = AIMetadata.grokModels(from: String(cString: output)) }
    return duplicate(metadataJSON(metadata, provider: which))
}
