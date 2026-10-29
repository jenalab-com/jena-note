import AppKit

extension NSAttributedString.Key {
    static let mdNoteReference = NSAttributedString.Key("MDNoteReference")
    static let mdNoteDefinition = NSAttributedString.Key("MDNoteDefinition")
}

enum DocumentEndnotes {
    struct Note {
        let id: String
        let text: String
        let range: NSRange
    }
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }
    }
    static func reference(_ id: String, font: NSFont = MemoFont.body) -> NSAttributedString {
        NSAttributedString(string: "[\(id)]", attributes: [.font: font, .foregroundColor: NSColor.labelColor, .mdNoteReference: id])
    }
    static func definition(_ id: String, text: String, baseURL: URL? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "[\(id)] ", attributes: MarkdownSerializer.bodyAttributes())
        result.addAttribute(.mdNoteDefinition, value: id, range: NSRange(location: 0, length: result.length))
        result.append(MarkdownSerializer.parseInline(text, baseFont: MemoFont.body, baseURL: baseURL))
        result.append(NSAttributedString(string: "\n", attributes: MarkdownSerializer.bodyAttributes()))
        return result
    }
    static func parseDefinition(_ line: String) -> (id: String, text: String)? {
        guard line.hasPrefix("[^"), let end = line.range(of: "]:"),
              validID(String(line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound])) else { return nil }
        return (String(line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound]), String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
    static func notes(in content: NSAttributedString) -> [Note] {
        var notes: [Note] = []
        let full = content.string as NSString
        content.enumerateAttribute(.mdNoteDefinition, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard let id = value as? String else { return }
            let paragraph = full.paragraphRange(for: NSRange(location: range.location, length: 0))
            let text = full.substring(with: paragraph)
            let prefix = "[\(id)] "
            guard range.location == paragraph.location, text.hasPrefix(prefix) else { return }
            notes.append(Note(id: id, text: String(text.dropFirst(prefix.count)).trimmingCharacters(in: .newlines), range: paragraph))
        }
        return notes
    }
    static func referenceRanges(_ id: String, in content: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        let full = content.string as NSString, marker = "[\(id)]" as NSString
        content.enumerateAttribute(.mdNoteReference, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard value as? String == id else { return }
            var search = range
            while search.length >= marker.length {
                let found = full.range(of: marker as String, range: search)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                search = NSRange(location: NSMaxRange(found), length: NSMaxRange(range) - NSMaxRange(found))
            }
        }
        return ranges
    }
    static func insert(into content: NSAttributedString, at position: Int, text: String) -> (content: NSAttributedString, id: String) {
        let updated = NSMutableAttributedString(attributedString: content)
        var used = Set(notes(in: content).map(\.id))
        content.enumerateAttribute(.mdNoteReference, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            if let id = value as? String { used.insert(id) }
        }
        var number = 1
        while used.contains(String(number)) { number += 1 }
        let id = String(number)
        updated.insert(reference(id), at: max(0, min(position, updated.length)))
        if !updated.string.hasSuffix("\n") { updated.append(NSAttributedString(string: "\n", attributes: MarkdownSerializer.bodyAttributes())) }
        updated.append(definition(id, text: normalized(text)))
        return (updated, id)
    }
    static func update(_ id: String, text: String?, in content: NSAttributedString) -> NSAttributedString {
        let updated = NSMutableAttributedString(attributedString: content)
        var edits = notes(in: content).filter { $0.id == id }.map { ($0.range, text.map { definition(id, text: normalized($0)) } ?? NSAttributedString(string: "")) }
        if text == nil {
            let definitions = edits.map { $0.0 }
            edits += referenceRanges(id, in: content).filter { reference in
                !definitions.contains { NSIntersectionRange($0, reference).length > 0 }
            }.map { ($0, NSAttributedString(string: "")) }
        }
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            updated.replaceCharacters(in: range, with: replacement)
        }
        return updated
    }
    static func normalized(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
