import Foundation
import Kiwi

/// All native handles are owned by the serial worker; model loading never blocks AppKit.
final class KiwiProofreadingEngine: @unchecked Sendable {
    static let shared = KiwiProofreadingEngine()
    private let worker = DispatchQueue(label: "com.jenalab.jenanote.proofreading", qos: .userInitiated)
    private let modelURL: @Sendable () -> URL?
    private var handle: OpaquePointer?
    private var typos: OpaquePointer?
    private var blocklist: OpaquePointer?

    init(modelURL: @escaping @Sendable () -> URL? = { KiwiProofreadingEngine.bundledModelURL() }) {
        self.modelURL = modelURL
    }

    deinit {
        if let typos { kiwi_prepared_typo_close(typos) }
        if let blocklist { kiwi_morphset_close(blocklist) }
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
        guard let prepared = Self.prepareTypos(), let blocked = Self.blocklist(for: loaded) else {
            kiwi_close(loaded)
            throw AIError(message: L10n.tr("proof.engineFailed"))
        }
        handle = loaded
        typos = prepared
        blocklist = blocked
        return loaded
    }

    /// 한글 맞춤법 제53항: `-ㄹ지·-ㄹ수록·-ㄹ게` are written with plain consonants. The model's
    /// dictionary lacks these misspellings, so a typo rule maps them back (`올찌` → `올지`).
    private static let endingTypos = [("지", "찌"), ("수", "쑤"), ("게", "께")]
    /// Misspellings the model dictionary lists as ordinary morphemes. Blocking them lets the
    /// typo rules or the adverb rule (제51항) find the standard form.
    private static let blockedMorphemes = [("ᆯ께", "EF"), ("ᆯ께", "EC"), ("을께", "EF"), ("ᆯ께요", "EF"), ("을께요", "EF"), ("께", "EF"),
                                           ("깨끗히", "MAG"), ("일일히", "MAG"),
                                           ("번번히", "MAG"), ("틈틈히", "MAG"), ("곰곰히", "MAG"), ("솔직이", "MAG")]

    private static func prepareTypos() -> OpaquePointer? {
        guard let typos = kiwi_typo_copy(kiwi_typo_get_default(Int32(KIWI_TYPO_BASIC_TYPO_SET))) else { return nil }
        defer { kiwi_typo_close(typos) }
        for (standard, misspelled) in endingTypos {
            let added = standard.withCString { orig in
                misspelled.withCString { error in
                    var origs: UnsafePointer<CChar>? = orig, errors: UnsafePointer<CChar>? = error
                    return kiwi_typo_add(typos, &origs, 1, &errors, 1, 1.5, 0)
                }
            }
            guard added == 0 else { return nil }
        }
        return kiwi_typo_prepare(typos)
    }

    private static func blocklist(for handle: OpaquePointer) -> OpaquePointer? {
        guard let set = kiwi_new_morphset(handle) else { return nil }
        for (form, tag) in blockedMorphemes where kiwi_morphset_add(set, form, tag) < 0 {
            kiwi_morphset_close(set)
            return nil
        }
        return set
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
        options.blocklist = blocklist
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
        let separators = try NSRegularExpression(pattern: "[^\\S ]+")
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
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let leading = String(text.prefix(while: { $0 == " " }))
        let trailing = String(text.reversed().prefix(while: { $0 == " " }).reversed())
        let tokens = try tokens(core, handle: handle)
        let protected = tokens.filter { $0.tag == "SL" || $0.tag == "SN" || $0.tag.hasPrefix("W_") }.map(\.range)
        let corrected = KoreanOrthographyRules.correct(core, excluding: protected)
        return leading + (try correctBody(corrected, handle: handle)) + trailing
    }

    /// Protect a name and its attached particles, not the rest of a space-less sentence.
    private func spacingProtection(_ tokens: [Token]) -> [NSRange] {
        var ranges: [NSRange] = []
        for (index, token) in tokens.enumerated() where token.isProtected {
            var end = NSMaxRange(token.range)
            if token.tag == "NNP" {
                var hasParticle = false
                for next in tokens.dropFirst(index + 1) {
                    guard next.range.location == end else { break }
                    if next.tag.hasPrefix("J") { hasParticle = true }
                    else if hasParticle || !(next.tag == "NNP" || next.tag == "NNG") { break }
                    end = NSMaxRange(next.range)
                }
            }
            ranges.append(NSRange(location: token.range.location, length: end - token.range.location))
        }
        return ranges
    }

    private func correctBody(_ text: String, handle: OpaquePointer) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let words = try NSRegularExpression(pattern: "[^ ]+")
        let source = text as NSString
        let analyzed = try tokens(text, handle: handle)
        let corrected = NSMutableString(string: text)
        // Computed on all tokens: a fully dropped `하` is a zero-length token outside any word.
        func has(_ form: String, _ tag: String) -> Bool {
            var ids = [UInt32](repeating: 0, count: 1)
            return kiwi_find_morphemes(handle, form, tag, -1, &ids, 1) > 0
        }
        let morphemes = analyzed.map { ($0.form, $0.tag, $0.range) }
        let haEdits = Self.contractedHaEdits(morphemes, in: text)
            + Self.adverbSuffixEdits(morphemes, in: text, isAdverb: { has($0, "MAG") }, takesHada: { has($0, "XR") })
        for word in words.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let parts = analyzed.filter { NSIntersectionRange($0.range, word.range).length > 0 }
            guard !parts.isEmpty, !parts.contains(where: \.isProtected),
                  parts.allSatisfy({ $0.range.location >= word.range.location && NSMaxRange($0.range) <= NSMaxRange(word.range) }) else { continue }
            guard parts.contains(where: { $0.typoCost > 0 || ($0.tag == "EP" && ["앗", "엇"].contains($0.form)) }) else {
                for edit in haEdits.reversed() where NSIntersectionRange(edit.range, word.range) == edit.range {
                    corrected.replaceCharacters(in: edit.range, with: edit.text)
                }
                continue
            }
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
        let spacingTokens = try tokens(input, handle: handle)
        let protectedRanges = spacingProtection(spacingTokens)
        let rules = Self.orthographySpacing(spacingTokens.map { ($0.form, $0.tag, $0.range) }, in: input)
        // A spacing model can concatenate unfamiliar names with neighboring words.
        // Remove existing boundaries only within a token or before a grammatical suffix.
        var retainedSpaces = Set<Int>()
        var utf16Offset = 0, letterOffset = 0
        for character in input {
            if character == " " {
                let withinToken = spacingTokens.contains {
                    $0.range.location < utf16Offset && NSMaxRange($0.range) > utf16Offset
                }
                let next = spacingTokens.first { $0.range.location > utf16Offset }
                let suffix = next.map { $0.tag.hasPrefix("J") || $0.tag.hasPrefix("E") || $0.tag.hasPrefix("X") } ?? false
                if !withinToken && !suffix { retainedSpaces.insert(letterOffset) }
            } else { letterOffset += 1 }
            utf16Offset += String(character).utf16.count
        }
        guard let spaced = kiwi_space(handle, input, 1) else { throw AIError(message: L10n.tr("proof.engineFailed")) }
        defer { kiwi_free_string(spaced) }
        retainedSpaces.subtract(rules.joins)
        return Self.preserveProtectedSpacing(source: input, candidate: String(cString: spaced), protected: protectedRanges,
                                             preservingSpacesAt: retainedSpaces, keepingJoinedAt: rules.joins, splittingAt: rules.splits)
    }

    /// 한글 맞춤법 제51항: an adverb ending is `-이` after a ㅅ final, a repeated noun, an adverb or a
    /// non-`-하다` stem (`깨끗이`, `곳곳이`, `일찍이`, `많이`) and `-히` after a `-하다` root (`꼼꼼히`).
    /// Kiwi splits misspelled adverbs into root + 이/히. A `-하다` root (XR) not ending in ㄱ follows the
    /// rule alone (`간편히` is not a listed adverb); every other swap also needs the result to be a listed
    /// adverb, since ㄱ finals go both ways (`깊숙이`, `넉넉히`).
    static func adverbSuffixEdits(_ tokens: [(form: String, tag: String, range: NSRange)], in text: String,
                                  isAdverb: (String) -> Bool, takesHada: (String) -> Bool) -> [(range: NSRange, text: String)] {
        let ns = text as NSString
        var edits: [(range: NSRange, text: String)] = []
        for index in tokens.indices.dropFirst() {
            let (root, suffix) = (tokens[index - 1], tokens[index])
            guard ["이", "히"].contains(suffix.form), suffix.tag == "XSM" || (suffix.tag == "EC" && root.tag.hasPrefix("VA")),
                  suffix.range.location == NSMaxRange(root.range), suffix.range.length == 1,
                  ns.substring(with: suffix.range) == suffix.form,
                  let last = root.form.unicodeScalars.last?.value, (0xAC00...0xD7A3).contains(last) else { continue }
            // Kiwi may split a repeated noun into two tokens (`틈/NNG 틈/NNG 히`).
            let doubled = index >= 2 && tokens[index - 2].form == root.form && tokens[index - 2].tag == "NNG"
                && NSMaxRange(tokens[index - 2].range) == root.range.location
            let start = doubled ? tokens[index - 2].range.location : root.range.location
            let rootText = ns.substring(with: NSRange(location: start, length: NSMaxRange(root.range) - start))
            let half = rootText.count / 2
            let repeated = root.tag == "NNG" && rootText.count >= 2 && rootText.count % 2 == 0 && rootText.prefix(half) == rootText.suffix(half)
            let final = Int(last - 0xAC00) % 28
            let expected: String, ruleOnly: Bool
            if final == 19 || repeated || root.tag.hasPrefix("VA") { (expected, ruleOnly) = ("이", false) }
            else if takesHada(root.form) { (expected, ruleOnly) = ("히", root.tag == "XR" && ![1, 2, 24].contains(final)) }
            else if root.tag == "MAG" { (expected, ruleOnly) = ("이", false) }
            else { continue }
            if expected != suffix.form, ruleOnly || isAdverb(rootText + expected) { edits.append((suffix.range, expected)) }
        }
        return edits
    }

    /// 한글 맞춤법 제40항: when `하` of `-하다` contracts, it drops entirely after a [ㄱ·ㄷ·ㅂ] final
    /// (`넉넉지`, `생각건대`, `깨끗지`) and otherwise merges as an aspirate (`흔치`, `간편케`, `회상컨대`).
    /// Kiwi already analyzes both spellings as stem + `하` + ending, so only the surface ending is fixed.
    /// Fully spelled `하지` and lexicalized adverbs (`요컨대`, `결코`) are untouched.
    private static let contractedEndings: [String: String] = ["지": "치", "건대": "컨대", "게": "케", "도록": "토록", "다": "타"]
    /// Finals pronounced [ㄱ·ㄷ·ㅂ]: ㄱ ㄲ ㄳ ㄷ ㄺ ㄼ ㄿ ㅂ ㅄ ㅅ ㅆ ㅈ ㅊ ㅋ ㅌ ㅍ.
    private static let obstruentFinals: Set<Int> = [1, 2, 3, 7, 9, 11, 14, 17, 18, 19, 20, 22, 23, 24, 25, 26]

    static func contractedHaEdits(_ tokens: [(form: String, tag: String, range: NSRange)], in text: String) -> [(range: NSRange, text: String)] {
        let ns = text as NSString
        var edits: [(range: NSRange, text: String)] = []
        for index in tokens.indices.dropFirst(2) {
            let (stem, ha, ending) = (tokens[index - 2], tokens[index - 1], tokens[index])
            guard ["XR", "NNG"].contains(stem.tag), ha.form == "하", ["XSA", "XSV"].contains(ha.tag),
                  let aspirated = contractedEndings[ending.form], ending.tag.hasPrefix("E"),
                  ha.range.location == NSMaxRange(stem.range), ending.range.location == ha.range.location,
                  ha.range.length <= 1, ending.range.length == (ending.form as NSString).length,
                  let last = ns.substring(with: stem.range).unicodeScalars.last?.value, (0xAC00...0xD7A3).contains(last) else { continue }
            let surface = ns.substring(with: ending.range)
            guard surface == ending.form || surface == aspirated else { continue }
            let expected = obstruentFinals.contains(Int(last - 0xAC00) % 28) ? ending.form : aspirated
            if surface != expected { edits.append((ending.range, expected)) }
        }
        return edits
    }

    /// Word boundaries decided by the orthography rules rather than by Kiwi's spacing model.
    /// `joins` are letter offsets that must not hold a space: required joins (any input) and
    /// permitted joins (only where the source was already attached). `splits` require a space.
    /// - 제47항: `-어 지다` and adjective + `-어 하다` are written together (`지워진다`, `예뻐한다`);
    ///   a phrase + `-어 하다` is spaced (`먹고 싶어 하다`); other `-아/-어` + auxiliaries may be
    ///   written either way, so an attached source (`꺼져간다`) is kept.
    /// - 제42항: `뿐·대로·만큼` after a nominal are particles (`남자뿐`), after a modifier bound nouns.
    /// - A Sino-Korean noun with a suffix-like syllable (`수출량`, `생산력`) is one word, not `수출 량`.
    ///   Ordinary one-syllable nouns still split (`책상위에` → `책상 위에`); names have separate protection.
    private static let sinoNounSuffixes: Set<String> = ["량", "률", "율", "력"]
    private static let nominalParticles: Set<String> = ["뿐", "대로", "만큼"]

    static func orthographySpacing(_ tokens: [(form: String, tag: String, range: NSRange)], in text: String) -> (joins: Set<Int>, splits: Set<Int>) {
        let ns = text as NSString
        func letters(before location: Int) -> Int { ns.substring(to: location).filter { $0 != " " }.count }
        func attached(_ location: Int) -> Bool { location > 0 && ns.character(at: location - 1) != 0x20 }
        func syllables(_ range: NSRange) -> Int { ns.substring(with: range).count }
        func nominal(_ tag: String) -> Bool { ["NNG", "NNP", "NP", "NR", "SN"].contains(tag) }
        var joins = Set<Int>(), splits = Set<Int>()
        for index in tokens.indices.dropFirst() {
            let (current, previous) = (tokens[index], tokens[index - 1])
            let boundary = current.range.location
            guard boundary > 0, boundary < ns.length, NSMaxRange(previous.range) <= boundary else { continue }
            let offset = letters(before: boundary)
            if current.tag == "VX", previous.tag == "EC", ["아", "어", "여"].contains(previous.form) {
                let stem = index >= 2 ? tokens[index - 2].tag : ""
                let adjective = stem.hasPrefix("VA") || stem == "XSA"
                if current.form == "지" || (current.form == "하" && adjective) { joins.insert(offset) }
                else if current.form == "하", stem.hasPrefix("VV") || stem.hasPrefix("VX") { splits.insert(offset) }
                else if current.form != "하", attached(boundary) { joins.insert(offset) }
            } else if current.tag == "NNB", nominalParticles.contains(current.form), nominal(previous.tag) {
                joins.insert(offset)
            } else if attached(boundary), current.tag == "NNB", current.form == "거", previous.tag == "ETM",
                      tokens.indices.contains(index + 1), tokens[index + 1].tag == "JKO", tokens[index + 1].range.location == boundary {
                // `그럴걸` (ending -ㄹ걸, 제53항) and `먹을 걸` (것을) differ only in meaning; keep the writer's choice.
                joins.insert(offset)
            } else if attached(boundary), current.tag == "NNG", previous.tag.hasPrefix("NN"), previous.tag != "NNB",
                      Self.sinoNounSuffixes.contains(current.form), syllables(previous.range) >= 2 {
                joins.insert(offset)
            }
        }
        return (joins, splits)
    }

    /// Kiwi's spacing API must not change characters, names, numbers, URLs or edge whitespace.
    static func preserveProtectedSpacing(source: String, candidate: String, protected: [NSRange], preservingSpacesAt retainedSpaces: Set<Int> = [],
                                         keepingJoinedAt joins: Set<Int> = [], splittingAt splits: Set<Int> = []) -> String {
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
        // Only internal boundaries are locked. Spaces before/after the protected span may change.
        for range in protected where range.location >= 0 && NSMaxRange(range) <= ns.length {
            let start = ns.substring(to: range.location).filter { $0 != " " }.count
            let length = ns.substring(with: range).filter { $0 != " " }.count
            if length > 1 { locked.formUnion((start + 1)..<(start + length)) }
        }
        proposed.subtract(locked)
        proposed.formUnion(original.intersection(locked))
        proposed.formUnion(original.intersection(retainedSpaces))
        proposed.subtract(joins.subtracting(locked))
        proposed.formUnion(splits.subtracting(locked))
        var output = ""
        for index in 0...letters.count {
            if proposed.contains(index) { output += " " }
            if index < letters.count { output.append(letters[index]) }
        }
        return output
    }
}
