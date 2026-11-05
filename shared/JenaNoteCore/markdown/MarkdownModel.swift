import Foundation

/// A stretch of inline content with one set of formatting.
public struct MarkdownRun: Equatable {
    public enum Content: Equatable {
        case text(String)
        case image(path: String, alt: String, width: Int?)
        case noteReference(String)
    }

    public var content: Content
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    public var link: String?
    /// "#RRGGBB", set only when the author chose a color.
    public var color: String?

    public init(_ content: Content, bold: Bool = false, italic: Bool = false, code: Bool = false,
                link: String? = nil, color: String? = nil) {
        self.content = content
        self.bold = bold
        self.italic = italic
        self.code = code
        self.link = link
        self.color = color
    }

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false,
                link: String? = nil, color: String? = nil) {
        self.init(.text(text), bold: bold, italic: italic, code: code, link: link, color: color)
    }
}

public struct MarkdownTable: Equatable {
    /// `rows[row][column]` holds the cell's runs.
    public var rows: [[[MarkdownRun]]]
    public var headerRow: Int

    public init(rows: [[[MarkdownRun]]], headerRow: Int = 0) {
        self.rows = rows
        self.headerRow = headerRow
    }
}

/// One line-level element of a document. Platform-neutral form of what the editor shows.
public enum MarkdownBlock: Equatable {
    case blank
    case heading(level: Int, runs: [MarkdownRun])
    case paragraph([MarkdownRun])
    case blockquote([MarkdownRun])
    case listItem(ordered: Bool, index: Int, runs: [MarkdownRun])
    case codeBlock(lines: [String])
    case table(MarkdownTable)
    case horizontalRule
    case noteDefinition(id: String, runs: [MarkdownRun])
}

public enum MarkdownNote {
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }
    }

    public static func parseDefinition(_ line: String) -> (id: String, text: String)? {
        guard line.hasPrefix("[^"), let end = line.range(of: "]:"),
              validID(String(line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound])) else { return nil }
        return (String(line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound]), String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
}
