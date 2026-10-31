import Foundation
import Kiwi

/// All native handles are owned by the serial worker; model loading never blocks AppKit.
final class KiwiProofreadingEngine: @unchecked Sendable {
    static let shared = KiwiProofreadingEngine()
    private let worker = DispatchQueue(label: "com.jenalab.jenanote.proofreading", qos: .userInitiated)
    private let modelURL: @Sendable () -> URL?
    private var handle: OpaquePointer?
    private var typos: OpaquePointer?

    init(modelURL: @escaping @Sendable () -> URL? = { KiwiProofreadingEngine.bundledModelURL() }) {
        self.modelURL = modelURL
    }

    deinit {
        if let typos { kiwi_prepared_typo_close(typos) }
        if let handle { kiwi_close(handle) }
    }

    static func bundledModelURL() -> URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("KiwiModel"),
           FileManager.default.fileExists(atPath: url.appendingPathComponent("cong.mdl").path) {
            return url
        }
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        return Bundle.module.url(forResource: "KiwiModel", withExtension: nil)
    }

    func prewarm() {
        worker.async { [self] in _ = try? load() }
    }

    func check(_ text: String) async throws -> String {
        try Task.checkCancellation()
        let corrected: String = try await withCheckedThrowingContinuation { continuation in
            worker.async { [self] in
                do {
                    let handle = try load()
                    continuation.resume(returning: try correct(text, handle: handle))
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return corrected
    }

    private func load() throws -> OpaquePointer {
        if let handle { return handle }
        guard let url = modelURL() else { throw AIError(message: L10n.tr("proof.modelMissing")) }
        // Keep original allomorphs and exclude typo.dict: that dictionary accepts misspellings
        // as ordinary forms, preventing correction candidates from being identified.
        let options = Int32(KIWI_BUILD_LOAD_DEFAULT_DICT | KIWI_BUILD_LOAD_MULTI_DICT)
        guard let loaded = kiwi_init(url.path, 1, options, 0) else {
            throw AIError(message: L10n.tr("proof.engineFailed"))
        }
        guard let prepared = kiwi_typo_prepare(kiwi_typo_get_default(Int32(KIWI_TYPO_BASIC_TYPO_SET))) else {
            kiwi_close(loaded)
            throw AIError(message: L10n.tr("proof.engineFailed"))
        }
        handle = loaded
        typos = prepared
        return loaded
    }

    private struct Token {
        let form: String
        let tag: String
        let range: NSRange
        let typoCost: Float
        var isProtected: Bool { tag == "NNP" || tag == "SL" || tag == "SN" || tag.hasPrefix("W_") }
    }

    private func tokens(_ text: String, handle: OpaquePointer) throws -> [Token] {
        var options = kiwi_analyze_option_t()
        options.match_options = Int32(KIWI_MATCH_ALL | KIWI_MATCH_OOV_CHR_MODEL)
        options.typo_transformer = typos
        options.typo_threshold = 2.5
        options.dialect_cost = 3
        guard let result = kiwi_analyze(handle, text, 1, options, nil) else {
            throw AIError(message: L10n.tr("proof.engineFailed"))
        }
        defer { kiwi_res_close(result) }
        let count = kiwi_res_word_num(result, 0)
        guard count >= 0 else { throw AIError(message: L10n.tr("proof.engineFailed")) }
        return try (0..<count).map { index in
            guard let form = kiwi_res_form(result, 0, index), let tag = kiwi_res_tag(result, 0, index) else {
                throw AIError(message: L10n.tr("proof.engineFailed"))
            }
            let range = NSRange(location: Int(kiwi_res_position(result, 0, index)),
                                length: Int(kiwi_res_length(result, 0, index)))
            guard range.location >= 0, NSMaxRange(range) <= (text as NSString).length else {
                throw AIError(message: L10n.tr("proof.invalid"))
            }
            return Token(form: String(cString: form), tag: String(cString: tag), range: range,
                         typoCost: kiwi_res_typo_cost(result, 0, index))
        }
    }

    private func correct(_ text: String, handle: OpaquePointer) throws -> String {
        // Preserve layout whitespace verbatim. Analyze ordinary spaces in their sentence context.
        let separators = try NSRegularExpression(pattern: "[^\\S ]+| {2,}")
        let source = text as NSString
        var output = "", cursor = 0
        for match in separators.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += try correctSegment(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), handle: handle)
            output += source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        output += try correctSegment(source.substring(from: cursor), handle: handle)
        return output
    }

    private func correctSegment(_ text: String, handle: OpaquePointer) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let words = try NSRegularExpression(pattern: "[^ ]+")
        let source = text as NSString
        let analyzed = try tokens(text, handle: handle)
        let corrected = NSMutableString(string: text)
        for word in words.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let parts = analyzed.filter { NSIntersectionRange($0.range, word.range).length > 0 }
            guard !parts.isEmpty, !parts.contains(where: \.isProtected),
                  parts.allSatisfy({ $0.range.location >= word.range.location && NSMaxRange($0.range) <= NSMaxRange(word.range) }),
                  parts.contains(where: { $0.typoCost > 0 || ($0.tag == "EP" && ["앗", "엇"].contains($0.form)) }) else { continue }
            guard let joiner = kiwi_new_joiner(handle, 0) else { throw AIError(message: L10n.tr("proof.engineFailed")) }
            defer { kiwi_joiner_close(joiner) }
            for part in parts {
                let form = part.tag == "EP" ? ["앗": "았", "엇": "었"][part.form] ?? part.form : part.form
                guard kiwi_joiner_add(joiner, form, part.tag, 0) == 0 else { throw AIError(message: L10n.tr("proof.engineFailed")) }
            }
            guard let joined = kiwi_joiner_get(joiner) else { throw AIError(message: L10n.tr("proof.engineFailed")) }
            let replacement = String(cString: joined)
            guard !replacement.isEmpty else { throw AIError(message: L10n.tr("proof.invalid")) }
            corrected.replaceCharacters(in: word.range, with: replacement)
        }
        let input = corrected as String
        let protectedTokens = try tokens(input, handle: handle).filter(\.isProtected)
        guard let spaced = kiwi_space(handle, input, 1) else { throw AIError(message: L10n.tr("proof.engineFailed")) }
        defer { kiwi_free_string(spaced) }
        return Self.preserveProtectedSpacing(source: input, candidate: String(cString: spaced), protected: protectedTokens.map(\.range))
    }

    /// Kiwi's spacing API must not change characters, names, numbers, URLs or edge whitespace.
    static func preserveProtectedSpacing(source: String, candidate: String, protected: [NSRange]) -> String {
        let letters = Array(source.filter { $0 != " " })
        guard letters == Array(candidate.filter { $0 != " " }) else { return source }
        func spaces(_ value: String) -> Set<Int> {
            var positions = Set<Int>(), index = 0
            for character in value {
                if character == " " { positions.insert(index) } else { index += 1 }
            }
            return positions
        }
        let original = spaces(source)
        var proposed = spaces(candidate)
        var locked: Set<Int> = [0, letters.count]
        let ns = source as NSString
        // Protect the full original word containing a proper noun (including its particle).
        var offset = 0
        for word in source.components(separatedBy: " ") {
            let range = NSRange(location: offset, length: (word as NSString).length)
            if protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                let start = ns.substring(to: offset).filter { $0 != " " }.count
                locked.formUnion(start...(start + word.count))
            }
            offset += range.length + 1
        }
        proposed.subtract(locked)
        proposed.formUnion(original.intersection(locked))
        var output = ""
        for index in 0...letters.count {
            if proposed.contains(index) { output += " " }
            if index < letters.count { output.append(letters[index]) }
        }
        return output
    }
}
