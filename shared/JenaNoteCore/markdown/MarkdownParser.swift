import Foundation

/// Markdown text to `MarkdownBlock`s.
///
/// Built from `MarkdownSerializer.parse` on macOS, with the save defects in
/// docs/markdown-known-issues.md fixed. `MarkdownCoreParityTests` compares the two on a Mac.
public enum MarkdownParser {

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if let fence = openingFence(line) {
                var codeLines: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if isClosingFence(lines[i], length: fence.length) {
                        closed = true
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                // In a fence left open, the empty piece after the file's last newline is not a line.
                if !closed, codeLines.last == "" { codeLines.removeLast() }
                blocks.append(.codeBlock(lines: codeLines, language: fence.language))
                i += 1
                continue
            }

            if let note = MarkdownNote.parseDefinition(line) {
                blocks.append(.noteDefinition(id: note.id, runs: parseInline(note.text)))
                i += 1
                continue
            }

            if isTableDataLine(line) && i + 1 < lines.count && isTableSeparatorLine(lines[i + 1]) {
                var tableLines: [String] = []
                while i < lines.count && isTableDataLine(lines[i]) {
                    tableLines.append(lines[i])
                    i += 1
                }
                if let table = makeTable(tableLines) { blocks.append(.table(table)) }
                continue
            }

            if isHorizontalRule(line) {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            if line.hasPrefix("### ") {
                blocks.append(.heading(level: 3, runs: parseInline(String(line.dropFirst(4)))))
            } else if line.hasPrefix("## ") {
                blocks.append(.heading(level: 2, runs: parseInline(String(line.dropFirst(3)))))
            } else if line.hasPrefix("# ") {
                blocks.append(.heading(level: 1, runs: parseInline(String(line.dropFirst(2)))))
            } else if line.hasPrefix("> ") {
                blocks.append(.blockquote(parseInline(String(line.dropFirst(2)))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                blocks.append(.listItem(ordered: false, index: 0, runs: parseInline(String(line.dropFirst(2)))))
            } else if let (index, rest) = parseOrderedListPrefix(line) {
                blocks.append(.listItem(ordered: true, index: index, runs: parseInline(rest)))
            } else if line.isEmpty {
                // Blank lines before the first content are dropped.
                if !blocks.isEmpty { blocks.append(.blank) }
            } else {
                blocks.append(.paragraph(parseInline(line)))
            }

            i += 1
        }

        return blocks
    }

    /// Backticks in the rest of the line mean inline code such as ```a```, not a fence.
    private static func openingFence(_ line: String) -> (length: Int, language: String?)? {
        guard line.hasPrefix("```") else { return nil }
        let length = line.prefix(while: { $0 == "`" }).count
        let language = line.dropFirst(length).trimmingCharacters(in: .whitespaces)
        guard !language.contains("`") else { return nil }
        return (length, language.isEmpty ? nil : language)
    }

    private static func isClosingFence(_ line: String, length: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == "`" }
    }

    // MARK: - Tables

    private static func makeTable(_ lines: [String]) -> MarkdownTable? {
        let dataLines = lines.filter { !isTableSeparatorLine($0) }
        guard !dataLines.isEmpty else { return nil }

        let cells = dataLines.map { parseTableCells($0) }
        let columnCount = cells.map(\.count).max() ?? 1

        var rows: [[[MarkdownRun]]] = []
        for row in cells {
            var cellRuns: [[MarkdownRun]] = []
            for column in 0..<columnCount {
                cellRuns.append(parseInline(column < row.count ? row[column] : ""))
            }
            rows.append(cellRuns)
        }
        // The caller found a separator as the second line.
        let separators = lines.count > 1 ? parseTableCells(lines[1]) : nil
        return MarkdownTable(rows: rows, separators: separators)
    }

    private static func isTableDataLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty
    }

    private static func isTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let inner = trimmed.hasPrefix("|") ? String(trimmed.dropFirst()) : trimmed
        let parts = inner.components(separatedBy: "|")
        let cells = parts.filter { !$0.isEmpty }
        return !cells.isEmpty && cells.allSatisfy { cell in
            let s = cell.trimmingCharacters(in: .whitespaces)
            return !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// `\|` is a pipe inside a cell, not a cell boundary.
    private static func parseTableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|"), !s.hasSuffix("\\|") { s = String(s.dropLast()) }
        var cells: [String] = []
        var cell = ""
        var previous: Character?
        for character in s {
            if character == "|" {
                if previous == "\\" {
                    cell.removeLast()
                    cell.append(character)
                } else {
                    cells.append(cell)
                    cell = ""
                }
            } else {
                cell.append(character)
            }
            previous = character
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Line kinds

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let ch = trimmed.first!
        return (ch == "-" || ch == "*" || ch == "_") && trimmed.allSatisfy { $0 == ch }
    }

    private static func parseOrderedListPrefix(_ line: String) -> (Int, String)? {
        var i = line.startIndex
        var numStr = ""
        while i < line.endIndex && line[i].isNumber { numStr.append(line[i]); i = line.index(after: i) }
        guard !numStr.isEmpty, i < line.endIndex, line[i] == ".", let num = Int(numStr) else { return nil }
        let afterDot = line.index(after: i)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (num, String(line[line.index(after: afterDot)...]))
    }

    // MARK: - Inline

    public static func parseInline(_ text: String) -> [MarkdownRun] {
        var result: [MarkdownRun] = []
        var remaining = text[...]

        while !remaining.isEmpty {
            if remaining.hasPrefix("[^"), let end = remaining.firstIndex(of: "]") {
                let id = String(remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<end])
                if MarkdownNote.validID(id) {
                    append(MarkdownRun(.noteReference(id)), to: &result)
                    remaining = remaining[remaining.index(after: end)...]
                    continue
                }
            }
            if remaining.hasPrefix("<span "), let parsed = parseColorSpan(in: remaining) {
                for run in parsed.runs { append(run, to: &result) }
                remaining = parsed.remaining
                continue
            }
            if remaining.hasPrefix("<img "), let parsed = parseImageTag(in: remaining) {
                append(parsed.run, to: &result)
                remaining = parsed.remaining
                continue
            }
            // Must come before the link check, which would otherwise take the `[`.
            if remaining.hasPrefix("!["),
               let textEnd = remaining.range(of: "]("),
               let urlEnd = remaining[textEnd.upperBound...].range(of: ")") {
                let altStart = remaining.index(remaining.startIndex, offsetBy: 2)
                let alt = String(remaining[altStart..<textEnd.lowerBound])
                let path = String(remaining[textEnd.upperBound..<urlEnd.lowerBound])
                append(MarkdownRun(.image(path: path, alt: alt, width: nil)), to: &result)
                remaining = remaining[urlEnd.upperBound...]
                continue
            }
            if remaining.hasPrefix("***"), let end = remaining.dropFirst(3).range(of: "***"),
               end.lowerBound > remaining.index(remaining.startIndex, offsetBy: 3) {
                let content = String(remaining[remaining.index(remaining.startIndex, offsetBy: 3)..<end.lowerBound])
                append(MarkdownRun(text: content, bold: true, italic: true), to: &result)
                remaining = remaining[end.upperBound...]
            } else if remaining.hasPrefix("**"), let end = remaining.dropFirst(2).range(of: "**"),
                      end.lowerBound > remaining.index(remaining.startIndex, offsetBy: 2) {
                let content = String(remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<end.lowerBound])
                append(MarkdownRun(text: content, bold: true), to: &result)
                remaining = remaining[end.upperBound...]
            } else if remaining.hasPrefix("__"), !followsWord(remaining, in: text),
                      let end = underscoreEnd(in: remaining.dropFirst(2), marker: "__"),
                      end.lowerBound > remaining.index(remaining.startIndex, offsetBy: 2) {
                let content = String(remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<end.lowerBound])
                append(MarkdownRun(text: content, bold: true), to: &result)
                remaining = remaining[end.upperBound...]
            } else if remaining.hasPrefix("*"), !remaining.hasPrefix("**"), let end = findItalicEnd(in: remaining.dropFirst(1), marker: "*"),
                      end.lowerBound > remaining.index(after: remaining.startIndex) {
                let content = String(remaining[remaining.index(after: remaining.startIndex)..<end.lowerBound])
                append(MarkdownRun(text: content, italic: true), to: &result)
                remaining = remaining[end.upperBound...]
            } else if remaining.hasPrefix("_"), !remaining.hasPrefix("__"), !followsWord(remaining, in: text),
                      let end = underscoreEnd(in: remaining.dropFirst(1), marker: "_"),
                      end.lowerBound > remaining.index(after: remaining.startIndex) {
                let content = String(remaining[remaining.index(after: remaining.startIndex)..<end.lowerBound])
                append(MarkdownRun(text: content, italic: true), to: &result)
                remaining = remaining[end.upperBound...]
            } else if remaining.hasPrefix("`"), let span = inlineCode(in: remaining) {
                append(MarkdownRun(text: span.content, code: true), to: &result)
                remaining = span.remaining
            } else if remaining.hasPrefix("["),
                      let textEnd = remaining.range(of: "]("),
                      let urlEnd = remaining[textEnd.upperBound...].range(of: ")") {
                let linkText = String(remaining[remaining.index(after: remaining.startIndex)..<textEnd.lowerBound])
                let url = String(remaining[textEnd.upperBound..<urlEnd.lowerBound])
                append(MarkdownRun(text: linkText, link: url), to: &result)
                remaining = remaining[urlEnd.upperBound...]
            } else {
                append(MarkdownRun(text: String(remaining.removeFirst())), to: &result)
            }
        }

        return result
    }

    /// Code between runs of the same number of backticks, so code can hold shorter runs.
    private static func inlineCode(in text: Substring) -> (content: String, remaining: Substring)? {
        let length = text.prefix(while: { $0 == "`" }).count
        var index = text.index(text.startIndex, offsetBy: length)
        let start = index
        while index < text.endIndex {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }
            let run = text[index...].prefix(while: { $0 == "`" })
            if run.count == length, index > start { return (String(text[start..<index]), text[run.endIndex...]) }
            index = run.endIndex
        }
        return nil
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Underscores inside a word, as in snake_case, are ordinary characters.
    private static func followsWord(_ remaining: Substring, in text: String) -> Bool {
        guard remaining.startIndex > text.startIndex else { return false }
        return isWord(text[text.index(before: remaining.startIndex)])
    }

    private static func underscoreEnd(in text: Substring, marker: String) -> Range<Substring.Index>? {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix(marker) {
                let end = text.index(index, offsetBy: marker.count)
                let doubled = marker == "_" && end < text.endIndex && text[end] == "_"
                if !doubled, end == text.endIndex || !isWord(text[end]) { return index..<end }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Neighbors with identical formatting are one run, as in an attributed string.
    private static func append(_ run: MarkdownRun, to runs: inout [MarkdownRun]) {
        guard case .text(let text) = run.content else {
            runs.append(run)
            return
        }
        guard !text.isEmpty else { return }
        if let last = runs.last, case .text(let previous) = last.content,
           last.bold == run.bold, last.italic == run.italic, last.code == run.code,
           last.link == run.link, last.color == run.color {
            runs[runs.count - 1].content = .text(previous + text)
        } else {
            runs.append(run)
        }
    }

    private static func parseColorSpan(in text: Substring) -> (runs: [MarkdownRun], remaining: Substring)? {
        guard text.hasPrefix("<span "), let openEnd = text.range(of: ">") else { return nil }
        let openTag = String(text[text.startIndex..<openEnd.upperBound])
        let normalized = openTag.replacingOccurrences(of: "'", with: "\"")
        guard let colorRange = normalized.range(of: "color:") else { return nil }

        let afterColor = normalized[colorRange.upperBound...]
        // Only `#` values count. Named colors are not supported.
        guard let hashIndex = afterColor.firstIndex(of: "#") else { return nil }
        var hexEnd = afterColor.index(after: hashIndex)
        while hexEnd < afterColor.endIndex,
              let scalar = afterColor[hexEnd].unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) {
            hexEnd = afterColor.index(after: hexEnd)
        }
        guard let color = normalizedColor(String(afterColor[hashIndex..<hexEnd])) else { return nil }

        let afterOpen = text[openEnd.upperBound...]
        guard let closeRange = afterOpen.range(of: "</span>") else { return nil }
        let inner = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])

        var runs: [MarkdownRun] = []
        for var run in parseInline(inner) {
            run.color = color
            append(run, to: &runs)
        }
        return (runs, afterOpen[closeRange.upperBound...])
    }

    /// "#RGB" or "#RRGGBB" in any case becomes uppercase "#RRGGBB". Invalid values give nil.
    public static func normalizedColor(_ hex: String) -> String? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return String(format: "#%06X", value)
    }

    private static func parseImageTag(in text: Substring) -> (run: MarkdownRun, remaining: Substring)? {
        guard text.hasPrefix("<img "), let closeRange = text.range(of: ">") else { return nil }
        let tag = String(text[text.startIndex..<closeRange.upperBound])
        guard let src = htmlAttribute("src", in: tag) else { return nil }
        let alt = htmlAttribute("alt", in: tag) ?? ""
        let width = htmlAttribute("width", in: tag).flatMap { Int($0) }
        return (MarkdownRun(.image(path: src, alt: alt, width: width), rawTag: tag), text[closeRange.upperBound...])
    }

    private static func htmlAttribute(_ name: String, in tag: String) -> String? {
        guard let nameRange = tag.range(of: "\(name)=") else { return nil }
        var rest = tag[nameRange.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    private static func findItalicEnd(in text: Substring, marker: String) -> Range<Substring.Index>? {
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx...].hasPrefix(marker) {
                let next = text.index(after: idx)
                if next >= text.endIndex || String(text[next]) != marker {
                    return idx..<text.index(after: idx)
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}
