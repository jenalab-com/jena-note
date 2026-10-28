import Foundation
import CryptoKit

struct AIIndexedPassage: Codable, Equatable {
    let id: String
    let path: String
    let isSetting: Bool
    let firstLine: Int
    let lastLine: Int
    let text: String
    let contentHash: String
    var summary: String
    var summaryOrigin: AIIndexSummary.Origin? = nil
    var summaryIssue: String? = nil

    var cacheKey: String { (isSetting ? "setting:" : "episode:") + contentHash }
    var citation: String { "\(path):\(firstLine)-\(lastLine)" }
    var catalogEntry: [String: Any] {
        ["id": id, "source": citation, "kind": isSetting ? "setting" : "episode",
         "summary": summary.isEmpty ? String(text.prefix(700)) : summary,
         "summaryKind": summary.isEmpty ? "excerpt" : (summaryOrigin?.rawValue ?? "unknown")]
    }
}

struct AIWorkIndex: Codable {
    static let version = 2
    static let chunkBytes = 2_400
    var version = Self.version
    var passages: [AIIndexedPassage] = []
    var updatedAt = Date()
    var summaryAvailability: String? = nil

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func split(text: String, path: String, isSetting: Bool) -> [AIIndexedPassage] {
        var result: [AIIndexedPassage] = []
        var buffer = "", first = 1, line = 1
        func flush() {
            guard !buffer.isEmpty else { return }
            let id = String(digest("\(path):\(result.count):\(buffer)").prefix(24))
            result.append(AIIndexedPassage(id: id, path: path, isSetting: isSetting,
                                           firstLine: first, lastLine: line, text: buffer, contentHash: digest(buffer), summary: ""))
            buffer = ""
            first = line
        }
        // Unicode scalars keep even a single enormous line bounded without splitting UTF-8.
        var bytes = 0
        for scalar in AIWorkContextResolver.normalize(text).unicodeScalars {
            let part = String(scalar)
            if bytes + part.utf8.count > chunkBytes { flush(); bytes = 0 }
            buffer += part
            bytes += part.utf8.count
            if scalar == "\n" {
                if bytes >= chunkBytes / 2 { flush(); bytes = 0; first = line + 1 }
                line += 1
            }
        }
        flush()
        return result
    }

    static func scan(context: AIWorkContext) throws -> AIWorkIndex {
        guard context.invalidPaths.isEmpty,
              context.settingsSourceURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw AIError(message: L10n.tr("ai.work.unreadable"))
        }
        let resolved = AIWorkContextResolver.resolve(context, currentFile: context.rootURL)
        if !resolved.unreadable.isEmpty { throw AIError(message: L10n.tr("ai.work.unreadable")) }
        var index = AIWorkIndex()
        for (file, setting) in resolved.settings.map({ ($0, true) }) + resolved.episodes.map({ ($0, false) }) {
            guard AIWorkContext.isSafeInsideRoot(file.url, root: context.rootURL),
                  let path = AIWorkContext.relativePath(of: file.url, to: context.rootURL) else {
                throw AIError(message: L10n.tr("ai.work.unreadable"))
            }
            index.passages += split(text: try AIWorkContextResolver.readText(file), path: path, isSetting: setting)
        }
        return index
    }

    /// Rebuild eligibility from this request, never from a previous document or cache entry.
    func eligible(for resolved: AIResolvedWorkContext, includeOpenSettings: Bool = true) throws -> [AIIndexedPassage] {
        let root = resolved.context.rootURL
        let settings = Set(resolved.settings.compactMap { AIWorkContext.relativePath(of: $0.url, to: root) })
        let episodes = Set(resolved.previousEpisodes.compactMap { AIWorkContext.relativePath(of: $0.url, to: root) })
        var result = passages.filter { $0.isSetting ? settings.contains($0.path) : episodes.contains($0.path) }
        if includeOpenSettings {
            for file in resolved.settings {
                guard AIWorkContext.isSafeInsideRoot(file.url, root: root) else { continue }
                let text = try AIWorkContextResolver.readSettingText(file)
                let existing = result.filter { $0.isSetting && $0.path == file.relativePath }
                if existing.map(\.text).joined() != AIWorkContextResolver.normalize(text) {
                    result.removeAll { $0.isSetting && $0.path == file.relativePath }
                    result += Self.split(text: text, path: file.relativePath, isSetting: true)
                }
            }
        }
        return result
    }

    static func search(_ queries: [String], in passages: [AIIndexedPassage], limit: Int = 24) -> [AIIndexedPassage] {
        let terms = queries.prefix(8).map { String($0.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var scored: [(passage: AIIndexedPassage, score: Int)] = []
        for passage in passages {
            var score = 0
            for term in terms {
                if passage.path.localizedCaseInsensitiveContains(term) { score += 4 }
                if passage.summary.localizedCaseInsensitiveContains(term) { score += 2 }
                if passage.text.localizedCaseInsensitiveContains(term) { score += 1 }
            }
            if score > 0 { scored.append((passage, score)) }
        }
        scored.sort { $0.score == $1.score ? $0.passage.id < $1.passage.id : $0.score > $1.score }
        return scored.prefix(limit).map(\.passage)
    }
}
