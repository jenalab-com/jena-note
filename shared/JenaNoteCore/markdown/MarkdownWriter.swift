import Foundation

/// `MarkdownBlock`s to Markdown text.
///
/// Saving what was read must keep what the author wrote and stay the same on every later save.
/// The macOS serializer does not yet; see docs/markdown-known-issues.md.
public enum MarkdownWriter {

    /// Levels whose base font already carries the bold trait on macOS. Marks would add nothing
    /// visible there, so `**` is not written.
    static func headingBaseIsBold(_ level: Int) -> Bool { level <= 2 }

    public static func write(_ blocks: [MarkdownBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        var output = ""

        for block in blocks {
            switch block {
            case .blank:
                output += "\n"
            case .horizontalRule:
                output += "---\n"
            case .heading(let level, let runs):
                if runs.isEmpty {
                    output += "\n"
                } else {
                    output += String(repeating: "#", count: level) + " "
                        + inline(runs, suppressBold: headingBaseIsBold(level)) + "\n"
                }
            case .paragraph(let runs):
                output += inline(runs) + "\n"
            case .blockquote(let runs):
                output += runs.isEmpty ? "\n" : "> " + inline(runs) + "\n"
            case .listItem(let ordered, let index, let runs):
                output += (ordered ? "\(index). " : "- ") + inline(runs) + "\n"
            case .noteDefinition(let id, let runs):
                output += "[^\(id)]: " + inline(runs) + "\n"
            case .codeBlock(let lines, let language):
                output += code(lines, language: language)
            case .table(let table):
                output += self.table(table)
            }
        }

        return output.trimmingCharacters(in: .newlines) + "\n"
    }

    /// The fence grows past any line inside that would otherwise end the block.
    private static func code(_ lines: [String], language: String?) -> String {
        let longest = lines.map { line -> Int in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.allSatisfy { $0 == "`" } ? trimmed.count : 0
        }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + (language ?? "") + "\n" + lines.map { $0 + "\n" }.joined() + fence + "\n"
    }

    private static func table(_ table: MarkdownTable) -> String {
        var output = ""
        for (rowIndex, row) in table.rows.enumerated() {
            // A header row is bold already, so marks in it add nothing, as in a large heading.
            let cells = row.map { inline($0, suppressBold: rowIndex == table.headerRow).replacingOccurrences(of: "|", with: "\\|") }
            output += "| " + cells.joined(separator: " | ") + " |\n"
            if rowIndex == table.headerRow {
                let separators = table.separators?.count == row.count ? table.separators! : row.map { _ in "---" }
                output += "| " + separators.joined(separator: " | ") + " |\n"
            }
        }
        return output
    }

    /// The fence is one backtick longer than any run inside, so the code cannot end early.
    private static func inlineCode(_ text: String) -> String {
        var longest = 0, current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: longest + 1)
        return fence + text + fence
    }

    public static func inline(_ runs: [MarkdownRun], suppressBold: Bool = false) -> String {
        var result = ""
        for run in runs {
            switch run.content {
            case .noteReference(let id):
                result += "[^\(id)]"
            case .image(let path, let alt, let width):
                if let tag = run.rawTag {
                    result += tag
                } else if let width, width > 0 {
                    let altAttribute = alt.isEmpty ? "" : " alt=\"\(alt)\""
                    result += "<img src=\"\(path)\"\(altAttribute) width=\"\(width)\">"
                } else {
                    result += "![\(alt)](\(path))"
                }
            case .text(let text):
                var output: String
                if run.code {
                    output = inlineCode(text)
                } else {
                    output = text
                    let bold = run.bold && !suppressBold
                    if bold && run.italic {
                        output = "***\(output)***"
                    } else if bold {
                        output = "**\(output)**"
                    } else if run.italic {
                        output = "*\(output)*"
                    }
                    if let link = run.link { output = "[\(output)](\(link))" }
                }
                // Outermost, because the parser takes the color first and then reads inside it.
                if let color = run.color {
                    output = "<span style=\"color: \(color)\">\(output)</span>"
                }
                result += output
            }
        }
        return result
    }
}
