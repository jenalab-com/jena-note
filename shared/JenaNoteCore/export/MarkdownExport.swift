import Foundation

/// Markdown model to the export model, following `DocumentModelBuilder` on macOS.
/// `MarkdownCoreParityTests` compares the two on a Mac.
public enum MarkdownExport {
    public struct Result {
        public var blocks: [Block]
        /// Images whose file could not be read, or any image when there is no base folder.
        public var imageLoadFailures: Int
    }

    public static func blocks(from markdown: [MarkdownBlock], baseFolder: URL?) -> Result {
        var builder = Builder(baseFolder: baseFolder)
        for block in markdown { builder.add(block) }
        // A blank line at the end would only leave an empty space in the exported file.
        while case .paragraph(let inlines)? = builder.blocks.last, inlines.isEmpty { builder.blocks.removeLast() }
        return Result(blocks: builder.blocks, imageLoadFailures: builder.imageLoadFailures)
    }

    private struct Builder {
        let baseFolder: URL?
        var blocks: [Block] = []
        var imageLoadFailures = 0
        var imageCount = 0

        init(baseFolder: URL?) {
            self.baseFolder = baseFolder
        }

        mutating func add(_ block: MarkdownBlock) {
            switch block {
            case .blank:
                blocks.append(.paragraph([]))
            case .horizontalRule:
                blocks.append(.horizontalRule)
            case .heading(let level, let runs):
                if runs.isEmpty {
                    blocks.append(.paragraph([]))
                } else if case .image = runs[0].content {
                    // A leading image makes the line read as body text, as when saving.
                    emit(runs) { .paragraph($0) }
                } else {
                    let suppressBold = MarkdownWriter.headingBaseIsBold(level)
                    emit(runs, suppressBold: suppressBold) { .heading(level: level, inlines: $0) }
                }
            case .paragraph(let runs):
                if runs.isEmpty { blocks.append(.paragraph([])) } else { emit(runs) { .paragraph($0) } }
            case .blockquote(let runs):
                if runs.isEmpty { blocks.append(.paragraph([])) } else { emit(runs) { .blockquote($0) } }
            case .listItem(let ordered, let index, let runs):
                emit(runs) { .listItem(ordered: ordered, index: index, inlines: $0) }
            case .noteDefinition(let id, let runs):
                emit([MarkdownRun(text: "[\(id)] ")] + runs) { .paragraph($0) }
            case .codeBlock(let lines):
                addCode(lines)
            case .table(let table):
                addTable(table)
            }
        }

        /// Text before and after an image becomes separate blocks around it.
        private mutating func emit(_ runs: [MarkdownRun], suppressBold: Bool = false, make: ([Inline]) -> Block) {
            var inlines: [Inline] = []
            for run in runs {
                if case .image(let path, _, let width) = run.content {
                    if !inlines.isEmpty {
                        blocks.append(make(inlines))
                        inlines = []
                    }
                    addImage(path: path, width: width)
                } else if let inline = Self.inline(run, suppressBold: suppressBold) {
                    inlines.append(inline)
                }
            }
            if !inlines.isEmpty { blocks.append(make(inlines)) }
        }

        private static func inline(_ run: MarkdownRun, suppressBold: Bool) -> Inline? {
            switch run.content {
            case .image:
                return nil
            case .noteReference(let id):
                return Inline(text: "[\(id)]", color: run.color)
            case .text(let text):
                return Inline(text: text, bold: run.bold && !suppressBold, italic: run.italic, code: run.code,
                              color: run.color, link: run.link)
            }
        }

        private mutating func addImage(path: String, width: Int?) {
            guard let baseFolder,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path, relativeTo: baseFolder).standardizedFileURL) else {
                imageLoadFailures += 1
                return
            }
            imageCount += 1
            let fileExtension = (path as NSString).pathExtension.lowercased()
            let fileName = "image\(imageCount)." + (fileExtension.isEmpty ? "png" : fileExtension)
            blocks.append(.image(ImageRef(data: data, fileName: fileName, width: width.flatMap { $0 > 0 ? $0 : nil })))
        }

        /// Empty lines before the first code line read as blank paragraphs, as when saving.
        private mutating func addCode(_ lines: [String]) {
            let leadingEmpty = lines.prefix(while: { $0.isEmpty }).count
            for _ in 0..<leadingEmpty { blocks.append(.paragraph([])) }
            if leadingEmpty < lines.count {
                blocks.append(.codeBlock(lines.dropFirst(leadingEmpty).joined(separator: "\n")))
            }
        }

        /// Empty cells before the first filled one read as blank paragraphs, as when saving.
        private mutating func addTable(_ table: MarkdownTable) {
            let cells = table.rows.flatMap { $0 }
            let leadingEmpty = cells.prefix(while: { $0.isEmpty }).count
            for _ in 0..<leadingEmpty { blocks.append(.paragraph([])) }
            guard leadingEmpty < cells.count else { return }
            let rows = table.rows.map { row in row.map { cell in cell.compactMap { Self.inline($0, suppressBold: false) } } }
            blocks.append(.table(rows: rows, headerRow: table.headerRow))
        }
    }
}
