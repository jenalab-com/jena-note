import Foundation

/// The JSON form of the Markdown model, for editors outside Swift.
///
/// Block: `{"type": ..., ...}` with type `blank`, `heading` (level, runs), `paragraph` (runs),
/// `blockquote` (runs), `listItem` (ordered, index, runs), `codeBlock` (lines, language),
/// `table` (rows, headerRow, separators), `horizontalRule`, or `noteDefinition` (id, runs).
///
/// Run: `{"text": ...}` with optional bold, italic, code, link and color,
/// or `{"image": {"path", "alt", "width"}, "raw": tag}`, or `{"note": id}`. Images and notes may carry color.
public enum MarkdownJSON {
    public static func encode(_ blocks: [MarkdownBlock]) throws -> String {
        let data = try JSONEncoder().encode(blocks.map(BlockDTO.init))
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String) throws -> [MarkdownBlock] {
        try JSONDecoder().decode([BlockDTO].self, from: Data(json.utf8)).map { try $0.model() }
    }
}

private struct RunDTO: Codable {
    struct Image: Codable {
        var path: String
        var alt: String
        var width: Int?
    }

    var text: String?
    var image: Image?
    var note: String?
    var bold: Bool?
    var italic: Bool?
    var code: Bool?
    var link: String?
    var color: String?
    var raw: String?

    init(_ run: MarkdownRun) {
        switch run.content {
        case .text(let value): text = value
        case .image(let path, let alt, let width): image = Image(path: path, alt: alt, width: width)
        case .noteReference(let id): note = id
        }
        bold = run.bold ? true : nil
        italic = run.italic ? true : nil
        code = run.code ? true : nil
        link = run.link
        color = run.color
        raw = run.rawTag
    }

    func model() throws -> MarkdownRun {
        let content: MarkdownRun.Content
        if let text {
            content = .text(text)
        } else if let image {
            content = .image(path: image.path, alt: image.alt, width: image.width)
        } else if let note {
            content = .noteReference(note)
        } else {
            throw AIError(message: "run has no content")
        }
        return MarkdownRun(content, bold: bold ?? false, italic: italic ?? false, code: code ?? false,
                           link: link, color: color, rawTag: raw)
    }
}

private struct BlockDTO: Codable {
    var type: String
    var level: Int?
    var ordered: Bool?
    var index: Int?
    var runs: [RunDTO]?
    var lines: [String]?
    var language: String?
    var separators: [String]?
    var rows: [[[RunDTO]]]?
    var headerRow: Int?
    var id: String?

    init(_ block: MarkdownBlock) {
        switch block {
        case .blank:
            type = "blank"
        case .horizontalRule:
            type = "horizontalRule"
        case .heading(let level, let runs):
            type = "heading"
            self.level = level
            self.runs = runs.map(RunDTO.init)
        case .paragraph(let runs):
            type = "paragraph"
            self.runs = runs.map(RunDTO.init)
        case .blockquote(let runs):
            type = "blockquote"
            self.runs = runs.map(RunDTO.init)
        case .listItem(let ordered, let index, let runs):
            type = "listItem"
            self.ordered = ordered
            self.index = index
            self.runs = runs.map(RunDTO.init)
        case .codeBlock(let lines, let language):
            type = "codeBlock"
            self.lines = lines
            self.language = language
        case .table(let table):
            type = "table"
            rows = table.rows.map { row in row.map { cell in cell.map(RunDTO.init) } }
            headerRow = table.headerRow
            separators = table.separators
        case .noteDefinition(let id, let runs):
            type = "noteDefinition"
            self.id = id
            self.runs = runs.map(RunDTO.init)
        }
    }

    func model() throws -> MarkdownBlock {
        let content = try (runs ?? []).map { try $0.model() }
        switch type {
        case "blank": return .blank
        case "horizontalRule": return .horizontalRule
        case "heading": return .heading(level: level ?? 1, runs: content)
        case "paragraph": return .paragraph(content)
        case "blockquote": return .blockquote(content)
        case "listItem": return .listItem(ordered: ordered ?? false, index: index ?? 0, runs: content)
        case "codeBlock": return .codeBlock(lines: lines ?? [], language: language)
        case "noteDefinition": return .noteDefinition(id: id ?? "", runs: content)
        case "table":
            let cells = try (rows ?? []).map { row in try row.map { cell in try cell.map { try $0.model() } } }
            return .table(MarkdownTable(rows: cells, headerRow: headerRow ?? 0, separators: separators))
        default:
            throw AIError(message: "unknown block type: \(type)")
        }
    }
}
