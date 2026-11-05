import Foundation

/// `MarkdownBlock`s to Markdown text.
///
/// Produces what `MarkdownSerializer.serialize` writes on macOS, byte for byte. Known defects
/// are kept on purpose so the move changes no saved file; see docs/markdown-known-issues.md.
public enum MarkdownWriter {

    /// Levels whose base font already carries the bold trait on macOS. Marks would add nothing
    /// visible there, so `**` is not written.
    private static func headingBaseIsBold(_ level: Int) -> Bool { level <= 2 }

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
                } else if case .image = runs[0].content {
                    // A leading image makes the line read as body text.
                    output += inline(runs) + "\n"
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
            case .codeBlock(let lines):
                output += code(lines)
            case .table(let table):
                output += self.table(table)
            }
        }

        return output.trimmingCharacters(in: .newlines) + "\n"
    }

    /// Fences attach to non-empty lines only, so an empty first or last line loses its fence.
    private static func code(_ lines: [String]) -> String {
        var output = ""
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                output += "\n"
                continue
            }
            if index == 0 { output += "```\n" }
            output += line + "\n"
            if index == lines.count - 1 { output += "```\n" }
        }
        return output
    }

    private static func table(_ table: MarkdownTable) -> String {
        // Empty cells before the first filled one are written as blank lines above the table.
        let cells = table.rows.flatMap { $0 }
        let leadingEmpty = cells.prefix(while: { $0.isEmpty }).count
        var output = String(repeating: "\n", count: leadingEmpty)
        guard leadingEmpty < cells.count else { return output }

        for (rowIndex, row) in table.rows.enumerated() {
            output += "| " + row.map { inline($0) }.joined(separator: " | ") + " |\n"
            if rowIndex == table.headerRow {
                output += "| " + row.map { _ in "---" }.joined(separator: " | ") + " |\n"
            }
        }
        return output + "\n"
    }

    public static func inline(_ runs: [MarkdownRun], suppressBold: Bool = false) -> String {
        var result = ""
        for run in runs {
            switch run.content {
            case .noteReference(let id):
                result += "[^\(id)]"
            case .image(let path, let alt, let width):
                if let width, width > 0 {
                    let altAttribute = alt.isEmpty ? "" : " alt=\"\(alt)\""
                    result += "<img src=\"\(path)\"\(altAttribute) width=\"\(width)\">"
                } else {
                    result += "![\(alt)](\(path))"
                }
            case .text(let text):
                var output: String
                if run.code {
                    output = "`\(text)`"
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
