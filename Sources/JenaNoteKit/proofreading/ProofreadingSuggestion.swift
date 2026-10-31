import Foundation

struct ProofreadingSuggestion: Equatable {
    let range: NSRange
    let original: String
    let replacement: String
    let marks: [NSRange]

    struct Edit {
        let range: NSRange
        let replacement: String
    }

    static func edits(source: String, corrected: String) -> [Edit] {
        let old = Array(source), new = Array(corrected)
        guard old.count <= 500, new.count <= 1000, !old.isEmpty, !new.isEmpty else { return [] }
        let diff = new.difference(from: old)
        let removed = Set(diff.removals.compactMap { if case .remove(let n, _, _) = $0 { return n }; return nil })
        let inserted = Set(diff.insertions.compactMap { if case .insert(let n, _, _) = $0 { return n }; return nil })
        var i = 0, j = 0, offset = 0, result: [Edit] = []
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                let start = offset
                var replacement = ""
                while i < old.count, removed.contains(i) { offset += String(old[i]).utf16.count; i += 1 }
                while j < new.count, inserted.contains(j) { replacement.append(new[j]); j += 1 }
                result.append(Edit(range: NSRange(location: start, length: offset - start), replacement: replacement))
            } else {
                if i < old.count { offset += String(old[i]).utf16.count }
                i += 1; j += 1
            }
        }
        return result
    }

    static func suggestions(source: String, corrected: String, terms: [String] = []) -> [Self] {
        let allowed = PersonalDictionaryFilter.ranges(in: source, terms: terms)
        let changes = edits(source: source, corrected: corrected).filter { edit in
            !allowed.contains { span in
                if edit.range.length == 0 { return edit.range.location > span.location && edit.range.location < NSMaxRange(span) }
                return edit.range.location >= span.location && NSMaxRange(edit.range) <= NSMaxRange(span)
            }
        }
        let ns = source as NSString
        var groups: [(NSRange, [Edit])] = []
        for edit in changes {
            let range = wordRange(source: source, edit: edit.range)
            if let last = groups.last, NSIntersectionRange(last.0, range).length > 0 {
                groups[groups.count - 1] = (NSUnionRange(last.0, range), last.1 + [edit])
            } else { groups.append((range, [edit])) }
        }
        return groups.map { range, changes in
            let original = ns.substring(with: range)
            let output = NSMutableString(string: original)
            for edit in changes.reversed() {
                output.replaceCharacters(in: NSRange(location: edit.range.location - range.location, length: edit.range.length), with: edit.replacement)
            }
            let replacement = output as String
            let marks = ProofreadingAnnotations.ranges(source: original, corrected: replacement).map {
                NSRange(location: range.location + $0.location, length: $0.length)
            }
            return Self(range: range, original: original, replacement: replacement, marks: marks)
        }
    }

    static func filteredText(source: String, corrected: String, terms: [String]) -> String {
        let output = NSMutableString(string: source)
        for item in suggestions(source: source, corrected: corrected, terms: terms).reversed() {
            output.replaceCharacters(in: item.range, with: item.replacement)
        }
        return output as String
    }

    private static func wordRange(source: String, edit: NSRange) -> NSRange {
        let chars = Array(source)
        var offsets = [0]
        for c in chars { offsets.append(offsets.last! + String(c).utf16.count) }
        var first = min(offsets.firstIndex(of: edit.location) ?? 0, chars.count - 1)
        var end = min(offsets.firstIndex(of: NSMaxRange(edit)) ?? (first + 1), chars.count)
        if edit.length == 0 { first = max(0, first - 1); end = min(chars.count, end + 1) }
        func word(_ c: Character) -> Bool { !c.isWhitespace && !c.isPunctuation }
        while first > 0, word(chars[first - 1]) { first -= 1 }
        while end < chars.count, word(chars[end]) { end += 1 }
        if end <= first { end = min(chars.count, first + 1) }
        return NSRange(location: offsets[first], length: offsets[end] - offsets[first])
    }
}

enum PersonalDictionaryFilter {
    // Only these complete particle suffixes are accepted; unrelated compound words remain checked.
    private static let particles: Set<String> = ["은", "는", "이", "가", "을", "를", "의", "에", "에서", "에게", "에게는", "에게도", "으로", "로", "와", "과", "도", "만", "부터", "까지", "이라", "라고", "이라는", "란", "처럼", "보다", "한테", "께"]

    static func ranges(in text: String, terms: [String]) -> [NSRange] {
        var result: [NSRange] = []
        func word(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        for term in terms where !term.isEmpty {
            var cursor = text.startIndex
            while cursor < text.endIndex, let match = text.range(of: term, range: cursor..<text.endIndex) {
                let leftOK = match.lowerBound == text.startIndex || !word(text[text.index(before: match.lowerBound)])
                var end = match.upperBound
                while end < text.endIndex, word(text[end]) { end = text.index(after: end) }
                let suffix = String(text[match.upperBound..<end])
                if leftOK && (suffix.isEmpty || particles.contains(suffix)) { result.append(NSRange(match, in: text)) }
                cursor = match.upperBound
            }
        }
        return result
    }
}
