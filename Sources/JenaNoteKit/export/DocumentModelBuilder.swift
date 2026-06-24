import AppKit

// MARK: - DocumentModelBuilder
//
// `NSAttributedString`(SSOT) → `[Block]`(IR) 변환.
// `MarkdownSerializer.serialize()`의 순회 구조를 그대로 본뜬다 — 단락 경계(`\n`)
// 단위 순회 + `mdBlockType` 분기 + 테이블 grid 재구성 + 인라인 run 순회.
// 차이는 출력이 Markdown 문자열이 아니라 Block 트리라는 것뿐이다.

enum DocumentModelBuilder {

    /// 변환 결과. 블록 트리와 함께, 로드에 실패한 이미지 수를 함께 돌려준다(에러 알림용).
    struct Result {
        var blocks: [Block]
        /// 경로가 깨졌거나 baseURL이 없어 바이너리를 못 읽은 이미지 수.
        var imageLoadFailures: Int
    }

    /// - Parameters:
    ///   - attributed: 문서 SSOT.
    ///   - baseURL: 이미지 상대경로(`mdImageRelPath`)를 해석할 기준 폴더. 미저장 문서면 nil.
    static func build(_ attributed: NSAttributedString, baseURL: URL?) -> Result {
        var ctx = Context(attributed: attributed, baseURL: baseURL)
        ctx.run()
        return Result(blocks: ctx.blocks, imageLoadFailures: ctx.imageLoadFailures)
    }

    // MARK: - Context (순회 상태)

    private struct Context {
        let attributed: NSAttributedString
        let full: NSString
        let length: Int
        let baseURL: URL?

        var blocks: [Block] = []
        var imageLoadFailures = 0
        var imageCounter = 0

        init(attributed: NSAttributedString, baseURL: URL?) {
            self.attributed = attributed
            self.full = attributed.string as NSString
            self.length = attributed.length
            self.baseURL = baseURL
        }

        mutating func run() {
            guard length > 0 else { return }
            var pos = 0

            while pos < length {
                var paraEnd = pos
                while paraEnd < length && full.character(at: paraEnd) != 10 { paraEnd += 1 }
                let paraRange = NSRange(location: pos, length: paraEnd - pos)

                // 빈 단락: hr이면 구분선, 아니면 무시(문단 간 간격은 Writer가 처리).
                if paraRange.length == 0 {
                    if paraEnd < length {
                        let nlAttrs = attributed.attributes(at: paraEnd, effectiveRange: nil)
                        if (nlAttrs[.mdBlockType] as? String) == "hr" {
                            blocks.append(.horizontalRule)
                        }
                    }
                    pos = paraEnd + 1
                    continue
                }

                let paraAttrs = attributed.attributes(at: pos, effectiveRange: nil)
                let blockType = resolveBlockType(paraAttrs: paraAttrs, paraEnd: paraEnd)
                let paraText = full.substring(with: paraRange)

                // 헤딩은 기준 폰트가 이미 bold — 인라인 추출 시 기준 폰트를 넘겨 사용자 서식만 잡는다.
                let baseFont: NSFont
                switch blockType {
                case "h1": baseFont = MemoFont.h1
                case "h2": baseFont = MemoFont.h2
                case "h3": baseFont = MemoFont.h3
                default:   baseFont = MemoFont.body
                }

                // 테이블: 셀 묶음을 grid로 재구성하고 한 번에 소비.
                if blockType == "table-cell" {
                    if let paraStyle = paraAttrs[.paragraphStyle] as? NSParagraphStyle,
                       let block = paraStyle.textBlocks.first as? NSTextTableBlock {
                        let (table, newPos) = buildTable(startPos: pos, table: block.table)
                        if let table = table { blocks.append(table) }
                        pos = newPos
                        continue
                    }
                }

                // ul/ol 접두사("•\t" / "N.\t") 범위만큼 잘라낸다.
                let inlineRange = inlineRangeStrippingListPrefix(blockType: blockType,
                                                                paraRange: paraRange,
                                                                paraText: paraText)

                switch blockType {
                case "codeblock":
                    // 연속 codeblock 단락을 하나로 묶는다.
                    pos = appendCodeBlock(startPos: pos)
                    continue
                case "hr":
                    blocks.append(.horizontalRule)
                case "h1", "h2", "h3":
                    let level = Int(String(blockType.dropFirst())) ?? 1
                    emit(range: inlineRange, baseFont: baseFont) { .heading(level: level, inlines: $0) }
                case "blockquote":
                    emit(range: inlineRange, baseFont: baseFont) { .blockquote($0) }
                case "ul":
                    emit(range: inlineRange, baseFont: baseFont) { .listItem(ordered: false, index: 0, inlines: $0) }
                case "ol":
                    let idx = paraAttrs[.mdListIndex] as? Int ?? 1
                    emit(range: inlineRange, baseFont: baseFont) { .listItem(ordered: true, index: idx, inlines: $0) }
                default:
                    emit(range: inlineRange, baseFont: baseFont) { .paragraph($0) }
                }

                pos = paraEnd + 1
            }
        }

        // MARK: 블록 타입 / 접두사

        private func resolveBlockType(paraAttrs: [NSAttributedString.Key: Any], paraEnd: Int) -> String {
            if let bt = paraAttrs[.mdBlockType] as? String { return bt }
            if paraEnd < length {
                return (attributed.attributes(at: paraEnd, effectiveRange: nil)[.mdBlockType] as? String) ?? "body"
            }
            return "body"
        }

        private func inlineRangeStrippingListPrefix(blockType: String, paraRange: NSRange, paraText: String) -> NSRange {
            if blockType == "ul" {
                let skip = (paraRange.length >= 2 &&
                            full.character(at: paraRange.location) == 0x2022 &&   // •
                            full.character(at: paraRange.location + 1) == 9) ? 2 : 0
                return NSRange(location: paraRange.location + skip, length: paraRange.length - skip)
            } else if blockType == "ol" {
                var skip = 0
                for ch in paraText {
                    skip += 1
                    if ch == "\t" { break }
                }
                return NSRange(location: paraRange.location + skip, length: max(0, paraRange.length - skip))
            }
            return paraRange
        }

        // MARK: 인라인 추출 + 이미지 분리

        /// `range`에서 텍스트 인라인과 이미지를 순서대로 추출한다.
        /// 텍스트 인라인이 모이면 `makeBlock`으로 블록을 만들고, 이미지는 즉시 `Block.image`로 떨군다.
        /// (대부분의 이미지는 자기 단락에 단독으로 있다.)
        private mutating func emit(range: NSRange, baseFont: NSFont, makeBlock: ([Inline]) -> Block) {
            var inlines: [Inline] = []
            var i = range.location
            let end = range.location + range.length
            let baseTraits = baseFont.fontDescriptor.symbolicTraits

            func flushText() {
                if !inlines.isEmpty {
                    blocks.append(makeBlock(inlines))
                    inlines = []
                }
            }

            while i < end {
                var effectiveRange = NSRange()
                let attrs = attributed.attributes(at: i, effectiveRange: &effectiveRange)
                let clampedStart = max(effectiveRange.location, i)
                let clampedEnd = min(effectiveRange.location + effectiveRange.length, end)
                let clampedRange = NSRange(location: clampedStart, length: max(0, clampedEnd - clampedStart))

                // 이미지 첨부 — 텍스트 흐름을 끊고 별도 image 블록으로.
                if attrs[.attachment] != nil {
                    if let relPath = attrs[.mdImageRelPath] as? String {
                        flushText()
                        let width = attrs[.mdImageWidth] as? Int
                        if let ref = loadImage(relPath: relPath, width: width) {
                            blocks.append(.image(ref))
                        } else {
                            imageLoadFailures += 1
                        }
                    }
                    i = effectiveRange.location + effectiveRange.length
                    continue
                }

                let text = full.substring(with: clampedRange)
                if !text.isEmpty {
                    inlines.append(makeInline(text: text, attrs: attrs, baseTraits: baseTraits))
                }
                i = effectiveRange.location + effectiveRange.length
            }
            flushText()
        }

        private func makeInline(text: String, attrs: [NSAttributedString.Key: Any],
                                baseTraits: NSFontDescriptor.SymbolicTraits) -> Inline {
            let isCode = attrs[.mdInlineCode] as? Bool == true
            let font = attrs[.font] as? NSFont ?? MemoFont.body
            let fontTraits = font.fontDescriptor.symbolicTraits
            // 기준 폰트에 이미 있는 trait은 사용자가 명시 적용한 게 아니다.
            let isBold   = fontTraits.contains(.bold)   && !baseTraits.contains(.bold)
            let isItalic = fontTraits.contains(.italic) && !baseTraits.contains(.italic)

            var color: String? = nil
            if attrs[.mdCustomColor] as? Bool == true, let c = attrs[.foregroundColor] as? NSColor {
                color = MarkdownColor.toHex(c)
            }

            var link: String? = nil
            if let url = attrs[.link] as? URL { link = url.absoluteString }
            else if let s = attrs[.link] as? String { link = s }

            return Inline(text: text, bold: isBold, italic: isItalic, code: isCode, color: color, link: link)
        }

        // MARK: 이미지 로드

        private mutating func loadImage(relPath: String, width: Int?) -> ImageRef? {
            guard let baseURL = baseURL else { return nil }
            let fileURL = URL(fileURLWithPath: relPath, relativeTo: baseURL).standardizedFileURL
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            imageCounter += 1
            let ext = (relPath as NSString).pathExtension.lowercased()
            let fileName = "image\(imageCounter)." + (ext.isEmpty ? "png" : ext)
            return ImageRef(data: data, fileName: fileName, width: width)
        }

        // MARK: 코드블록 (연속 묶기)

        /// `startPos`부터 연속된 codeblock 단락을 모아 하나의 `Block.codeBlock`으로 만들고,
        /// 다음 처리 위치를 돌려준다. (`serialize()`의 prevIsCB 묶음 로직과 같은 경계.)
        private mutating func appendCodeBlock(startPos: Int) -> Int {
            var pos = startPos
            var lines: [String] = []
            while pos < length {
                let bt = (attributed.attributes(at: pos, effectiveRange: nil)[.mdBlockType] as? String) ?? "body"
                guard bt == "codeblock" else { break }
                var paraEnd = pos
                while paraEnd < length && full.character(at: paraEnd) != 10 { paraEnd += 1 }
                lines.append(full.substring(with: NSRange(location: pos, length: paraEnd - pos)))
                pos = paraEnd + 1
            }
            blocks.append(.codeBlock(lines.joined(separator: "\n")))
            return pos
        }

        // MARK: 테이블 grid 재구성

        /// `serializeTable()`을 본떠, 같은 `NSTextTable`에 속한 셀 단락들을 grid로 재구성한다.
        private mutating func buildTable(startPos: Int, table: NSTextTable) -> (Block?, Int) {
            var pos = startPos
            struct Cell { let row: Int; let col: Int; let inlines: [Inline]; let isHeader: Bool }
            var cells: [Cell] = []
            let baseTraits = MemoFont.body.fontDescriptor.symbolicTraits

            while pos < length {
                var paraEnd = pos
                while paraEnd < length && full.character(at: paraEnd) != 10 { paraEnd += 1 }
                let paraRange = NSRange(location: pos, length: paraEnd - pos)
                let attrs = attributed.attributes(at: pos, effectiveRange: nil)

                guard let paraStyle = attrs[.paragraphStyle] as? NSParagraphStyle,
                      let block = paraStyle.textBlocks.first as? NSTextTableBlock,
                      block.table === table else { break }

                let inlines = inlinesIn(range: paraRange, baseTraits: baseTraits)
                let isHeader = attrs[.mdTableHeader] as? Bool == true
                cells.append(Cell(row: block.startingRow, col: block.startingColumn,
                                  inlines: inlines, isHeader: isHeader))
                pos = paraEnd + 1
            }

            guard !cells.isEmpty else { return (nil, pos) }

            let maxRow = cells.map(\.row).max() ?? 0
            let maxCol = cells.map(\.col).max() ?? 0
            var grid = Array(repeating: Array(repeating: [Inline](), count: maxCol + 1), count: maxRow + 1)
            var headerRow = 0
            for cell in cells {
                grid[cell.row][cell.col] = cell.inlines
                if cell.isHeader { headerRow = cell.row }
            }
            return (.table(rows: grid, headerRow: headerRow), pos)
        }

        /// 범위 내 텍스트 인라인만 추출(이미지는 표 셀에서 제외). 표 셀 전용 헬퍼.
        private func inlinesIn(range: NSRange, baseTraits: NSFontDescriptor.SymbolicTraits) -> [Inline] {
            var inlines: [Inline] = []
            var i = range.location
            let end = range.location + range.length
            while i < end {
                var effectiveRange = NSRange()
                let attrs = attributed.attributes(at: i, effectiveRange: &effectiveRange)
                let clampedStart = max(effectiveRange.location, i)
                let clampedEnd = min(effectiveRange.location + effectiveRange.length, end)
                let clampedRange = NSRange(location: clampedStart, length: max(0, clampedEnd - clampedStart))
                if attrs[.attachment] == nil {
                    let text = full.substring(with: clampedRange)
                    if !text.isEmpty {
                        inlines.append(makeInline(text: text, attrs: attrs, baseTraits: baseTraits))
                    }
                }
                i = effectiveRange.location + effectiveRange.length
            }
            return inlines
        }
    }
}
