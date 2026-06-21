import AppKit

// MARK: - Custom Attribute Keys

extension NSAttributedString.Key {
    /// 마크다운 블록 타입 (h1, h2, h3, body, ul, ol, blockquote, codeblock, table-cell)
    static let mdBlockType = NSAttributedString.Key("MDBlockType")
    /// 순서 있는 목록의 번호
    static let mdListIndex = NSAttributedString.Key("MDListIndex")
    /// 인라인 코드 여부
    static let mdInlineCode = NSAttributedString.Key("MDInlineCode")
    /// 테이블 헤더 행 여부
    static let mdTableHeader = NSAttributedString.Key("MDTableHeader")
    /// 사용자가 명시적으로 지정한 글자 색 (구조적 기본색과 구분하기 위한 플래그)
    static let mdCustomColor = NSAttributedString.Key("MDCustomColor")
}

// MARK: - Color ↔ Hex Helpers

enum MarkdownColor {
    /// NSColor → "#RRGGBB" — 알파는 무시 (HTML span 호환)
    static func toHex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(max(0, min(1, rgb.redComponent)) * 255))
        let g = Int(round(max(0, min(1, rgb.greenComponent)) * 255))
        let b = Int(round(max(0, min(1, rgb.blueComponent)) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// "#RRGGBB" 또는 "#RGB" → NSColor (실패 시 nil)
    static func fromHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            // 3자리 → 6자리 확장 (e.g., F00 → FF0000)
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Typography

enum MemoFont {
    static let body       = NSFont.systemFont(ofSize: 15)
    static let h1         = NSFont.systemFont(ofSize: 28, weight: .bold)
    static let h2         = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let h3         = NSFont.systemFont(ofSize: 18, weight: .medium)
    static let code       = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let codeBlock  = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static func bold(from base: NSFont) -> NSFont {
        let traits = base.fontDescriptor.symbolicTraits.union(.bold)
        let desc = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }
    static func italic(from base: NSFont) -> NSFont {
        let traits = base.fontDescriptor.symbolicTraits.union(.italic)
        let desc = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }
    static func boldItalic(from base: NSFont) -> NSFont {
        italic(from: bold(from: base))
    }
}

// MARK: - MarkdownSerializer

enum MarkdownSerializer {

    // MARK: Parse: Plain Text → NSAttributedString (마크다운 해석 없이 순수 텍스트)

    static func parsePlainText(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let isLast = i == lines.count - 1
            if isLast && line.isEmpty { break }
            let paraText = line.isEmpty ? "" : line
            result.append(NSAttributedString(string: paraText, attributes: bodyAttributes()))
            result.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
        }
        return result
    }

    // MARK: Parse: Markdown String → NSAttributedString

    static func parse(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Code block (``` fence)
            if line.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                let codeText = codeLines.joined(separator: "\n") + "\n"
                result.append(makeCodeBlock(codeText))
                i += 1
                continue
            }

            // Table: 현재 줄이 | 포함하고 다음 줄이 구분선(|---|---|)인 경우
            if isTableDataLine(line) && i + 1 < lines.count && isTableSeparatorLine(lines[i + 1]) {
                var tableLines: [String] = []
                while i < lines.count && isTableDataLine(lines[i]) {
                    tableLines.append(lines[i])
                    i += 1
                }
                result.append(makeTable(tableLines))
                continue
            }

            // Horizontal rule (---, ***, ___)
            if isHorizontalRule(line) {
                result.append(makeHorizontalRule())
                i += 1
                continue
            }

            // Heading
            if line.hasPrefix("### ") {
                result.append(makeHeading(String(line.dropFirst(4)), level: 3))
            } else if line.hasPrefix("## ") {
                result.append(makeHeading(String(line.dropFirst(3)), level: 2))
            } else if line.hasPrefix("# ") {
                result.append(makeHeading(String(line.dropFirst(2)), level: 1))
            }
            // Blockquote
            else if line.hasPrefix("> ") {
                result.append(makeBlockquote(String(line.dropFirst(2))))
            }
            // Unordered list
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                result.append(makeListItem(String(line.dropFirst(2)), ordered: false, index: 0))
            }
            // Ordered list
            else if let (idx, rest) = parseOrderedListPrefix(line) {
                result.append(makeListItem(rest, ordered: true, index: idx))
            }
            // Empty line → 빈 줄 보존 (textView에서 빈 줄로 표시)
            else if line.isEmpty {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
                }
                i += 1
                continue
            }
            // Body paragraph
            else {
                result.append(makeParagraph(line))
            }

            i += 1
        }

        return result
    }

    // MARK: Serialize: NSAttributedString → Markdown String

    static func serialize(_ attributed: NSAttributedString) -> String {
        var output = ""
        let full = attributed.string as NSString
        let length = attributed.length
        guard length > 0 else { return "" }

        var pos = 0

        while pos < length {
            var paraEnd = pos
            while paraEnd < length && full.character(at: paraEnd) != 10 { // \n = 10
                paraEnd += 1
            }
            let paraRange = NSRange(location: pos, length: paraEnd - pos)

            if paraRange.length == 0 {
                // \n 단독 문자 처리: HR이면 출력, 일반 빈 줄이면 빈 줄 출력
                if paraEnd < length {
                    let nlAttrs = attributed.attributes(at: paraEnd, effectiveRange: nil)
                    if (nlAttrs[.mdBlockType] as? String) == "hr" {
                        output += "---\n"
                    } else {
                        output += "\n"
                    }
                }
                pos = paraEnd + 1
                continue
            }

            let paraAttrs = attributed.attributes(at: pos, effectiveRange: nil)
            // 헤딩 인라인 문자에는 mdBlockType이 없을 수 있음 → 단락 끝 \n에서 읽기
            let blockType: String = {
                if let bt = paraAttrs[.mdBlockType] as? String { return bt }
                if paraEnd < length {
                    return (attributed.attributes(at: paraEnd, effectiveRange: nil)[.mdBlockType] as? String) ?? "body"
                }
                return "body"
            }()
            let paraText = full.substring(with: paraRange)

            // 헤딩은 기본 폰트가 이미 bold — 인라인 직렬화 시 기준 폰트 전달
            let baseFont: NSFont
            switch blockType {
            case "h1": baseFont = MemoFont.h1
            case "h2": baseFont = MemoFont.h2
            case "h3": baseFont = MemoFont.h3
            default:   baseFont = MemoFont.body
            }

            // ul/ol은 paraRange에 "•\t" 또는 "N.\t" 접두사가 포함되어 있으므로 제거 후 직렬화
            let inlineRange: NSRange
            if blockType == "ul" {
                let skip = (paraRange.length >= 2 &&
                            full.character(at: paraRange.location) == 0x2022 &&
                            full.character(at: paraRange.location + 1) == 9) ? 2 : 0
                inlineRange = NSRange(location: paraRange.location + skip, length: paraRange.length - skip)
            } else if blockType == "ol" {
                var skip = 0
                for ch in paraText {
                    skip += 1
                    if ch == "\t" { break }
                }
                inlineRange = NSRange(location: paraRange.location + skip, length: max(0, paraRange.length - skip))
            } else {
                inlineRange = paraRange
            }
            let inlineMarkdown = serializeInline(attributed, range: inlineRange, baseFont: baseFont)

            // 테이블 셀: 테이블 전체를 한 번에 직렬화
            if blockType == "table-cell" {
                if let paraStyle = paraAttrs[.paragraphStyle] as? NSParagraphStyle,
                   let block = paraStyle.textBlocks.first as? NSTextTableBlock {
                    let (tableOutput, newPos) = serializeTable(attributed, startPos: pos, table: block.table)
                    output += tableOutput + "\n"
                    pos = newPos
                    continue
                }
            }

            switch blockType {
            case "h1": output += "# \(inlineMarkdown)\n"
            case "h2": output += "## \(inlineMarkdown)\n"
            case "h3": output += "### \(inlineMarkdown)\n"
            case "blockquote": output += "> \(inlineMarkdown)\n"
            case "ul": output += "- \(inlineMarkdown)\n"
            case "ol":
                let idx = paraAttrs[.mdListIndex] as? Int ?? 1
                output += "\(idx). \(inlineMarkdown)\n"
            case "hr": output += "---\n"
            case "codeblock":
                let prevIsCB = pos > 0 &&
                    (attributed.attributes(at: pos - 1, effectiveRange: nil)[.mdBlockType] as? String) == "codeblock"
                if !prevIsCB { output += "```\n" }
                output += "\(paraText)\n"
                if paraEnd + 1 >= length {
                    output += "```\n"
                } else {
                    let nextBlock = (attributed.attributes(at: paraEnd + 1, effectiveRange: nil)[.mdBlockType] as? String) ?? "body"
                    if nextBlock != "codeblock" { output += "```\n" }
                }
            default:
                output += "\(inlineMarkdown)\n"
            }

            pos = paraEnd + 1
        }

        return output.trimmingCharacters(in: .newlines) + "\n"
    }

    // MARK: - Private: Table Serialize

    private static func serializeTable(_ attributed: NSAttributedString,
                                       startPos: Int,
                                       table: NSTextTable) -> (String, Int) {
        let full = attributed.string as NSString
        let length = attributed.length
        var pos = startPos

        struct CellInfo { let row: Int; let col: Int; let text: String; let isHeader: Bool }
        var cells: [CellInfo] = []

        while pos < length {
            var paraEnd = pos
            while paraEnd < length && full.character(at: paraEnd) != 10 { paraEnd += 1 }
            let paraRange = NSRange(location: pos, length: paraEnd - pos)
            let attrs = attributed.attributes(at: pos, effectiveRange: nil)

            guard let paraStyle = attrs[.paragraphStyle] as? NSParagraphStyle,
                  let block = paraStyle.textBlocks.first as? NSTextTableBlock,
                  block.table === table else { break }

            let text = serializeInline(attributed, range: paraRange)
            let isHeader = attrs[.mdTableHeader] as? Bool == true
            cells.append(CellInfo(row: block.startingRow, col: block.startingColumn, text: text, isHeader: isHeader))
            pos = paraEnd + 1
        }

        guard !cells.isEmpty else { return ("", pos) }

        let maxRow = cells.map(\.row).max() ?? 0
        let maxCol = cells.map(\.col).max() ?? 0
        var grid = Array(repeating: Array(repeating: "", count: maxCol + 1), count: maxRow + 1)
        var headerRow = 0
        for cell in cells {
            grid[cell.row][cell.col] = cell.text
            if cell.isHeader { headerRow = cell.row }
        }

        var output = ""
        for (rowIdx, row) in grid.enumerated() {
            output += "| " + row.joined(separator: " | ") + " |\n"
            if rowIdx == headerRow {
                output += "| " + row.map { _ in "---" }.joined(separator: " | ") + " |\n"
            }
        }
        return (output, pos)
    }

    // MARK: - Private: Inline Serialize

    private static func serializeInline(_ attributed: NSAttributedString, range: NSRange,
                                        baseFont: NSFont = MemoFont.body) -> String {
        var result = ""
        var i = range.location
        let end = range.location + range.length
        let baseTraits = baseFont.fontDescriptor.symbolicTraits

        while i < end {
            var effectiveRange = NSRange()
            let attrs = attributed.attributes(at: i, effectiveRange: &effectiveRange)
            // effectiveRange는 i보다 앞에서 시작할 수 있음 (인접 run 병합 시)
            // → 시작점을 반드시 i로 클램핑해야 이전 단락 텍스트 포함 방지
            let clampedStart = max(effectiveRange.location, i)
            let clampedEnd = min(effectiveRange.location + effectiveRange.length, end)
            let clampedRange = NSRange(location: clampedStart, length: max(0, clampedEnd - clampedStart))
            let text = (attributed.string as NSString).substring(with: clampedRange)

            let isInlineCode = attrs[.mdInlineCode] as? Bool == true
            let font = attrs[.font] as? NSFont ?? MemoFont.body
            let fontTraits = font.fontDescriptor.symbolicTraits
            // 기준 폰트에 이미 있는 trait은 사용자가 명시적으로 적용한 것이 아님
            let isBold   = fontTraits.contains(.bold)   && !baseTraits.contains(.bold)
            let isItalic = fontTraits.contains(.italic) && !baseTraits.contains(.italic)
            let hasCustomColor = attrs[.mdCustomColor] as? Bool == true

            var output: String
            if isInlineCode {
                output = "`\(text)`"
            } else {
                output = text
                if isBold && isItalic {
                    output = "***\(output)***"
                } else if isBold {
                    output = "**\(output)**"
                } else if isItalic {
                    output = "*\(output)*"
                }
                if let url = attrs[.link] as? URL {
                    output = "[\(output)](\(url.absoluteString))"
                } else if let urlStr = attrs[.link] as? String {
                    output = "[\(output)](\(urlStr))"
                }
            }
            // 색상은 가장 바깥쪽 래퍼로 — 파서가 색을 추출한 뒤 내부를 재귀 파싱
            if hasCustomColor, let color = attrs[.foregroundColor] as? NSColor {
                output = "<span style=\"color: \(MarkdownColor.toHex(color))\">\(output)</span>"
            }
            result += output

            i = effectiveRange.location + effectiveRange.length
        }

        return result
    }

    // MARK: - Private: Table Builder

    private static func makeTable(_ lines: [String]) -> NSAttributedString {
        // 구분선 제외
        let dataLines = lines.filter { !isTableSeparatorLine($0) }
        guard !dataLines.isEmpty else { return NSAttributedString() }

        let rows = dataLines.map { parseTableCells($0) }
        let colCount = rows.map(\.count).max() ?? 1

        let table = NSTextTable()
        table.numberOfColumns = colCount
        table.setContentWidth(100, type: .percentageValueType)
        table.collapsesBorders = false

        let result = NSMutableAttributedString()

        let colWidthPct = CGFloat(100.0 / Double(colCount))

        for (rowIdx, row) in rows.enumerated() {
            let isHeader = rowIdx == 0
            for colIdx in 0..<colCount {
                let cellText = colIdx < row.count ? row[colIdx] : ""

                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIdx, rowSpan: 1,
                    startingColumn: colIdx, columnSpan: 1
                )

                // 열 너비 (균등 분할) — 이 설정이 없으면 모든 셀이 세로로 쌓임
                block.setValue(colWidthPct, type: .percentageValueType, for: .width)

                // 테두리
                for edge: NSRectEdge in [.minX, .minY, .maxX, .maxY] {
                    block.setWidth(1, type: .absoluteValueType, for: .border, edge: edge)
                    block.setBorderColor(NSColor.separatorColor, for: edge)
                }
                // 패딩
                for edge: NSRectEdge in [.minX, .minY, .maxX, .maxY] {
                    block.setWidth(6, type: .absoluteValueType, for: .padding, edge: edge)
                }
                // 헤더 배경
                if isHeader {
                    block.backgroundColor = NSColor.controlBackgroundColor
                }

                let paraStyle = NSMutableParagraphStyle()
                paraStyle.textBlocks = [block]

                let font = isHeader ? MemoFont.bold(from: MemoFont.body) : MemoFont.body
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paraStyle,
                    .mdBlockType: "table-cell"
                ]
                if isHeader { attrs[.mdTableHeader] = true }

                // 셀 내 인라인 서식 파싱
                let inlineContent = parseInline(cellText, baseFont: font)
                let cell = NSMutableAttributedString(string: "", attributes: attrs)
                let inlineMutable = NSMutableAttributedString(attributedString: inlineContent)
                inlineMutable.addAttributes(attrs, range: NSRange(location: 0, length: inlineMutable.length))
                cell.append(inlineMutable)
                cell.append(NSAttributedString(string: "\n", attributes: attrs))
                result.append(cell)
            }
        }

        return result
    }

    // MARK: - Private: Horizontal Rule

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let ch = trimmed.first!
        return (ch == "-" || ch == "*" || ch == "_") && trimmed.allSatisfy { $0 == ch }
    }

    static func makeHorizontalRule() -> NSAttributedString {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setValue(1, type: .absoluteValueType, for: .minimumHeight)
        block.setValue(1, type: .absoluteValueType, for: .maximumHeight)
        // backgroundColor 대신 border만 사용해 선 영역만 색상 적용
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(NSColor.separatorColor, for: .minY)
        block.setWidth(8, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.textBlocks = [block]
        paraStyle.minimumLineHeight = 1
        paraStyle.maximumLineHeight = 1

        return NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .foregroundColor: NSColor.clear,
            .paragraphStyle: paraStyle,
            .mdBlockType: "hr"
        ])
    }

    // MARK: - Private: Table Helpers

    private static func isTableDataLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty
    }

    private static func isTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let inner = trimmed.hasPrefix("|") ? String(trimmed.dropFirst()) : trimmed
        let parts = inner.components(separatedBy: "|")
        return parts.filter { !$0.isEmpty }.allSatisfy { cell in
            let s = cell.trimmingCharacters(in: .whitespaces)
            return !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseTableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Private: Block Builders

    private static func makeHeading(_ text: String, level: Int) -> NSAttributedString {
        let font: NSFont
        let blockType: String
        switch level {
        case 1: font = MemoFont.h1; blockType = "h1"
        case 2: font = MemoFont.h2; blockType = "h2"
        default: font = MemoFont.h3; blockType = "h3"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .mdBlockType: blockType,
            .paragraphStyle: headingParagraphStyle()
        ]
        let inline = parseInline(text, baseFont: font)
        let result = NSMutableAttributedString(string: "", attributes: attrs)
        result.append(inline)
        result.append(NSAttributedString(string: "\n", attributes: attrs))
        return result
    }

    private static func makeBlockquote(_ text: String) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MemoFont.body,
            .foregroundColor: NSColor.secondaryLabelColor,
            .mdBlockType: "blockquote",
            .paragraphStyle: blockquoteParagraphStyle()
        ]
        let fullInline = NSMutableAttributedString(attributedString: parseInline(text, baseFont: MemoFont.body))
        // 구조 속성만 추가 — font/foregroundColor는 parseInline이 설정한 bold/italic 유지
        let structuralAttrs: [NSAttributedString.Key: Any] = [
            .mdBlockType: "blockquote",
            .paragraphStyle: blockquoteParagraphStyle()
        ]
        fullInline.addAttributes(structuralAttrs, range: NSRange(location: 0, length: fullInline.length))
        fullInline.append(NSAttributedString(string: "\n", attributes: attrs))
        return fullInline
    }

    private static func makeListItem(_ text: String, ordered: Bool, index: Int) -> NSAttributedString {
        let blockType = ordered ? "ol" : "ul"
        var attrs: [NSAttributedString.Key: Any] = [
            .font: MemoFont.body,
            .foregroundColor: NSColor.labelColor,
            .mdBlockType: blockType,
            .paragraphStyle: listParagraphStyle()
        ]
        if ordered { attrs[.mdListIndex] = index }

        let prefix = ordered ? "\(index).\t" : "•\t"
        let inline = parseInline(text, baseFont: MemoFont.body)
        let result = NSMutableAttributedString(string: prefix, attributes: attrs)
        let inlineMutable = NSMutableAttributedString(attributedString: inline)
        // 구조 속성만 추가 — font/foregroundColor는 parseInline이 설정한 bold/italic 유지
        let structuralAttrs: [NSAttributedString.Key: Any] = [
            .mdBlockType: blockType,
            .paragraphStyle: listParagraphStyle()
        ]
        inlineMutable.addAttributes(structuralAttrs, range: NSRange(location: 0, length: inlineMutable.length))
        result.append(inlineMutable)
        result.append(NSAttributedString(string: "\n", attributes: attrs))
        return result
    }

    private static func makeCodeBlock(_ text: String) -> NSAttributedString {
        let block = NSTextBlock()
        // 너비를 명시해야 여러 단락이 하나의 박스로 묶임 (없으면 줄마다 별도 박스)
        block.setValue(100, type: .percentageValueType, for: .width)
        block.backgroundColor = NSColor(name: nil) { trait in
            trait.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1) // #1E1E1E (VS Code dark)
                : NSColor(red: 0.965, green: 0.969, blue: 0.976, alpha: 1) // #F6F8FA (GitHub light)
        }
        for edge: NSRectEdge in [.minX, .minY, .maxX, .maxY] {
            block.setWidth(14, type: .absoluteValueType, for: .padding, edge: edge)
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: edge)
            block.setBorderColor(NSColor(white: 0.5, alpha: 0.25), for: edge)
        }
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.textBlocks = [block]
        paraStyle.paragraphSpacing = 0
        paraStyle.paragraphSpacingBefore = 0

        // 문법 하이라이팅 적용
        let highlighted = SyntaxHighlighter.highlight(text)
        let result = NSMutableAttributedString(attributedString: highlighted)
        result.addAttributes([
            .mdBlockType: "codeblock",
            .paragraphStyle: paraStyle
        ], range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func makeParagraph(_ text: String) -> NSAttributedString {
        let inline = parseInline(text, baseFont: MemoFont.body)
        let result = NSMutableAttributedString(attributedString: inline)
        // 구조 속성(mdBlockType, paragraphStyle)만 추가 — font/foregroundColor는 parseInline이 설정한 값 유지
        let structuralAttrs: [NSAttributedString.Key: Any] = [
            .mdBlockType: "body",
            .paragraphStyle: bodyParagraphStyle()
        ]
        result.addAttributes(structuralAttrs, range: NSRange(location: 0, length: result.length))
        result.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
        return result
    }

    // MARK: - Private: Inline Parser

    static func parseInline(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var remaining = text[...]
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ]

        while !remaining.isEmpty {
            // <span style="color: ...">...</span> — 사용자 지정 색상 (가장 먼저 검사)
            if remaining.hasPrefix("<span "),
               let parsed = parseColorSpan(in: remaining, baseFont: baseFont) {
                result.append(parsed.attributed)
                remaining = parsed.remaining
                continue
            }
            if remaining.hasPrefix("***"), let end = remaining.dropFirst(3).range(of: "***") {
                let content = String(remaining[remaining.index(remaining.startIndex, offsetBy: 3)..<end.lowerBound])
                result.append(NSAttributedString(string: content, attributes: [.font: MemoFont.boldItalic(from: baseFont), .foregroundColor: NSColor.labelColor]))
                remaining = remaining[end.upperBound...]
            }
            else if remaining.hasPrefix("**"), let end = remaining.dropFirst(2).range(of: "**") {
                let content = String(remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<end.lowerBound])
                result.append(NSAttributedString(string: content, attributes: [.font: MemoFont.bold(from: baseFont), .foregroundColor: NSColor.labelColor]))
                remaining = remaining[end.upperBound...]
            }
            else if remaining.hasPrefix("__"), let end = remaining.dropFirst(2).range(of: "__") {
                let content = String(remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<end.lowerBound])
                result.append(NSAttributedString(string: content, attributes: [.font: MemoFont.bold(from: baseFont), .foregroundColor: NSColor.labelColor]))
                remaining = remaining[end.upperBound...]
            }
            else if remaining.hasPrefix("*"), !remaining.hasPrefix("**"), let end = findItalicEnd(in: remaining.dropFirst(1), marker: "*") {
                let content = String(remaining[remaining.index(after: remaining.startIndex)..<end.lowerBound])
                result.append(NSAttributedString(string: content, attributes: [.font: MemoFont.italic(from: baseFont), .foregroundColor: NSColor.labelColor]))
                remaining = remaining[end.upperBound...]
            }
            else if remaining.hasPrefix("_"), !remaining.hasPrefix("__"), let end = findItalicEnd(in: remaining.dropFirst(1), marker: "_") {
                let content = String(remaining[remaining.index(after: remaining.startIndex)..<end.lowerBound])
                result.append(NSAttributedString(string: content, attributes: [.font: MemoFont.italic(from: baseFont), .foregroundColor: NSColor.labelColor]))
                remaining = remaining[end.upperBound...]
            }
            else if remaining.hasPrefix("`"), let end = remaining.dropFirst(1).range(of: "`") {
                let content = String(remaining[remaining.index(after: remaining.startIndex)..<end.lowerBound])
                result.append(NSAttributedString(string: content, attributes: [
                    .font: MemoFont.code, .foregroundColor: NSColor.labelColor, .mdInlineCode: true
                ]))
                remaining = remaining[end.upperBound...]
            }
            else if remaining.hasPrefix("["),
                    let textEnd = remaining.range(of: "]("),
                    let urlEnd = remaining[textEnd.upperBound...].range(of: ")") {
                let linkText = String(remaining[remaining.index(after: remaining.startIndex)..<textEnd.lowerBound])
                let urlStr = String(remaining[textEnd.upperBound..<urlEnd.lowerBound])
                result.append(NSAttributedString(string: linkText, attributes: [
                    .font: baseFont, .foregroundColor: NSColor.linkColor,
                    .link: urlStr, .underlineStyle: NSUnderlineStyle.single.rawValue
                ]))
                remaining = remaining[urlEnd.upperBound...]
            }
            else {
                result.append(NSAttributedString(string: String(remaining.removeFirst()), attributes: defaultAttrs))
            }
        }

        return result
    }

    /// `<span style="color: #RRGGBB">...</span>`를 파싱.
    /// 내부 텍스트는 재귀적으로 인라인 서식 파싱하여 색상 + 굵게/기울임 등의 중첩을 보존한다.
    private static func parseColorSpan(in text: Substring, baseFont: NSFont)
        -> (attributed: NSAttributedString, remaining: Substring)? {

        guard text.hasPrefix("<span "),
              let openEnd = text.range(of: ">") else { return nil }
        let openTag = String(text[text.startIndex..<openEnd.upperBound])
        // 인용 부호 정규화: 작은따옴표/큰따옴표 둘 다 허용
        let normalized = openTag.replacingOccurrences(of: "'", with: "\"")
        guard let colorRange = normalized.range(of: "color:") else { return nil }

        let afterColor = normalized[colorRange.upperBound...]
        // hex 값을 추출 — `#`로 시작하는 토큰만 인정 (이름색은 미지원)
        guard let hashIdx = afterColor.firstIndex(of: "#") else { return nil }
        let hexStart = hashIdx
        var hexEnd = afterColor.index(after: hexStart)
        while hexEnd < afterColor.endIndex,
              let scalar = afterColor[hexEnd].unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) {
            hexEnd = afterColor.index(after: hexEnd)
        }
        let hex = String(afterColor[hexStart..<hexEnd])
        guard let color = MarkdownColor.fromHex(hex) else { return nil }

        let afterOpen = text[openEnd.upperBound...]
        guard let closeRange = afterOpen.range(of: "</span>") else { return nil }
        let inner = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])

        // 내부 콘텐츠 재귀 파싱 → 색상·플래그를 전체 범위에 덧씌움
        let innerParsed = parseInline(inner, baseFont: baseFont)
        let mutable = NSMutableAttributedString(attributedString: innerParsed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttributes([
            .foregroundColor: color,
            .mdCustomColor: true
        ], range: fullRange)

        return (mutable, afterOpen[closeRange.upperBound...])
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

    // MARK: - Private: Paragraph Styles & Attributes

    private static func bodyAttributes() -> [NSAttributedString.Key: Any] {
        [.font: MemoFont.body, .foregroundColor: NSColor.labelColor,
         .mdBlockType: "body", .paragraphStyle: bodyParagraphStyle()]
    }

    private static func bodyParagraphStyle() -> NSParagraphStyle {
        let s = NSMutableParagraphStyle(); s.paragraphSpacingBefore = 4; s.paragraphSpacing = 4; return s
    }
    private static func headingParagraphStyle() -> NSParagraphStyle {
        let s = NSMutableParagraphStyle(); s.paragraphSpacingBefore = 12; s.paragraphSpacing = 6; return s
    }
    private static func listParagraphStyle() -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.headIndent = 20; s.firstLineHeadIndent = 0
        s.tabStops = [NSTextTab(type: .leftTabStopType, location: 20)]; s.paragraphSpacing = 2; return s
    }
    private static func blockquoteParagraphStyle() -> NSParagraphStyle {
        let s = NSMutableParagraphStyle(); s.headIndent = 16; s.firstLineHeadIndent = 16; s.paragraphSpacing = 4; return s
    }
    private static func codeParagraphStyle() -> NSParagraphStyle {
        let s = NSMutableParagraphStyle(); s.headIndent = 12; s.firstLineHeadIndent = 12; s.paragraphSpacing = 2; return s
    }

    // MARK: - Private: Ordered List Prefix Parser

    private static func parseOrderedListPrefix(_ line: String) -> (Int, String)? {
        var i = line.startIndex
        var numStr = ""
        while i < line.endIndex && line[i].isNumber { numStr.append(line[i]); i = line.index(after: i) }
        guard !numStr.isEmpty, i < line.endIndex, line[i] == ".", let num = Int(numStr) else { return nil }
        let afterDot = line.index(after: i)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (num, String(line[line.index(after: afterDot)...]))
    }
}
