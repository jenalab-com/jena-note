import Foundation

/// Source UTF-16 ranges only. Inserted spaces are indicated on the adjacent source letters.
enum ProofreadingAnnotations {
    static func ranges(source: String, corrected: String) -> [NSRange] {
        let old = Array(source), new = Array(corrected)
        guard old.count <= 500, new.count <= 1000, !old.isEmpty else { return [] }
        let difference = new.difference(from: old)
        let removed = Set(difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }; return nil
        })
        let inserted = Set(difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }; return nil
        })
        var selected = removed, i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { i += 1 }
            else if j < new.count, inserted.contains(j) {
                if i == 0 || !removed.contains(i - 1) {
                    if i > 0 { selected.insert(i - 1) }
                    if i < old.count { selected.insert(i) }
                }
                j += 1
            } else { i += 1; j += 1 }
        }
        var offset = 0, result: [NSRange] = []
        for (index, character) in old.enumerated() {
            let length = String(character).utf16.count
            if selected.contains(index) {
                if let last = result.last, NSMaxRange(last) == offset {
                    result[result.count - 1].length += length
                } else { result.append(NSRange(location: offset, length: length)) }
            }
            offset += length
        }
        return result
    }

    static func chunks(_ text: String, in range: NSRange) -> [(NSRange, String)] {
        guard let indices = Range(range, in: text) else { return [] }
        var result: [(NSRange, String)] = [], chunk = "", start = range.location, offset = start
        func flush() {
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !chunk.contains("\u{fffc}"), !chunk.contains("\0") {
                result.append((NSRange(location: start, length: chunk.utf16.count), chunk))
            }
            chunk = ""; start = offset
        }
        for character in text[indices] {
            let value = String(character)
            if chunk.count >= 500 || chunk.utf8.count + value.utf8.count > 1500 { flush() }
            if value.utf8.count > 1500 { offset += value.utf16.count; start = offset; continue }
            chunk += value; offset += value.utf16.count
            if character.isNewline || ".!?。！？".contains(character) { flush() }
        }
        flush()
        return result
    }
}
