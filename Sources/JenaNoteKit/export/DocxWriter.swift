import AppKit

// MARK: - DocxWriter
//
// `[Block]`(IR) → `.docx`(OOXML) Data. 의존성 0, ZipArchive로 패키징.
//
// 패키지 레이아웃:
//   [Content_Types].xml
//   _rels/.rels
//   word/document.xml            ← 본문
//   word/media/imageN.*          ← 이미지
//   word/_rels/document.xml.rels ← 이미지·하이퍼링크 관계
//
// 스타일 정의(styles.xml)에 의존하지 않도록 제목·코드 등은 직접 서식(run properties)으로 표현한다.

enum DocxWriter {

    /// 1px = 9525 EMU (96dpi 기준).
    private static let emuPerPx = 9525

    static func write(_ blocks: [Block]) -> Data {
        var ctx = Context()
        ctx.build(blocks)

        var zip = ZipArchive()
        zip.addEntry(path: "[Content_Types].xml", data: contentTypes())
        zip.addEntry(path: "_rels/.rels", data: rootRels())
        zip.addEntry(path: "word/document.xml", data: ctx.documentXML())
        zip.addEntry(path: "word/_rels/document.xml.rels", data: ctx.documentRels())
        for img in ctx.images {
            zip.addEntry(path: "word/media/\(img.fileName)", data: img.data)
        }
        return zip.finalize()
    }

    // MARK: - Context (본문 생성 + 관계 수집)

    private struct Context {
        var body = ""
        var images: [ImageRef] = []
        // 관계: (rId, type, target, external)
        var rels: [(id: String, type: String, target: String, external: Bool)] = []
        private var relCounter = 0

        mutating func nextRelId() -> String {
            relCounter += 1
            return "rId\(relCounter)"
        }

        mutating func build(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .heading(level, inlines):
                    appendHeading(level: level, inlines: inlines)
                case let .paragraph(inlines):
                    body += paragraph(runsXML(inlines))
                case let .listItem(ordered, index, inlines):
                    appendListItem(ordered: ordered, index: index, inlines: inlines)
                case let .blockquote(inlines):
                    appendBlockquote(inlines)
                case let .codeBlock(code):
                    appendCodeBlock(code)
                case let .table(rows, headerRow):
                    appendTable(rows: rows, headerRow: headerRow)
                case .horizontalRule:
                    appendHorizontalRule()
                case let .image(ref):
                    appendImage(ref)
                }
            }
        }

        // MARK: 블록별 생성

        private mutating func appendHeading(level: Int, inlines: [Inline]) {
            // 제목은 직접 서식: 굵게 + 레벨별 크기(half-point).
            let sz: Int
            switch level {
            case 1: sz = 36   // 18pt
            case 2: sz = 28   // 14pt
            default: sz = 24  // 12pt
            }
            let runs = runsXML(inlines, forceBold: true, forceSize: sz)
            let pPr = "<w:pPr><w:spacing w:before=\"240\" w:after=\"120\"/></w:pPr>"
            body += "<w:p>\(pPr)\(runs)</w:p>"
        }

        private mutating func appendListItem(ordered: Bool, index: Int, inlines: [Inline]) {
            // 1차: numbering.xml 없이 글머리 텍스트 + 들여쓰기로 표현.
            let marker = ordered ? "\(index). " : "•  "
            let pPr = "<w:pPr><w:ind w:left=\"360\" w:hanging=\"360\"/></w:pPr>"
            let markerRun = "<w:r><w:t xml:space=\"preserve\">\(XMLEscape.text(marker))</w:t></w:r>"
            body += "<w:p>\(pPr)\(markerRun)\(runsXML(inlines))</w:p>"
        }

        private mutating func appendBlockquote(_ inlines: [Inline]) {
            let pPr = "<w:pPr><w:ind w:left=\"480\"/><w:pBdr>"
                + "<w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"CCCCCC\"/></w:pBdr></w:pPr>"
            // 인용은 회색 기울임 기본.
            let runs = runsXML(inlines, defaultItalic: true, defaultColor: "666666")
            body += "<w:p>\(pPr)\(runs)</w:p>"
        }

        private mutating func appendCodeBlock(_ code: String) {
            let pPr = "<w:pPr><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F8FA\"/>"
                + "<w:spacing w:before=\"60\" w:after=\"60\"/></w:pPr>"
            let lines = code.components(separatedBy: "\n")
            var runs = ""
            for (i, line) in lines.enumerated() {
                if i > 0 { runs += "<w:r><w:br/></w:r>" }
                runs += "<w:r><w:rPr><w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/>"
                    + "<w:sz w:val=\"20\"/></w:rPr><w:t xml:space=\"preserve\">\(XMLEscape.text(line))</w:t></w:r>"
            }
            body += "<w:p>\(pPr)\(runs)</w:p>"
        }

        private mutating func appendHorizontalRule() {
            body += "<w:p><w:pPr><w:pBdr>"
                + "<w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"CCCCCC\"/>"
                + "</w:pBdr></w:pPr></w:p>"
        }

        private mutating func appendTable(rows: [[[Inline]]], headerRow: Int) {
            let colCount = rows.map(\.count).max() ?? 1
            var tbl = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
            for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
                tbl += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>"
            }
            tbl += "</w:tblBorders></w:tblPr><w:tblGrid>"
            for _ in 0..<colCount { tbl += "<w:gridCol/>" }
            tbl += "</w:tblGrid>"

            for (r, row) in rows.enumerated() {
                tbl += "<w:tr>"
                for c in 0..<colCount {
                    let cell = c < row.count ? row[c] : []
                    let isHeader = r == headerRow
                    let shd = isHeader ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F0F0F0\"/>" : ""
                    let runs = runsXML(cell, forceBold: isHeader)
                    let p = runs.isEmpty ? "<w:p/>" : "<w:p>\(runs)</w:p>"
                    tbl += "<w:tc><w:tcPr>\(shd)</w:tcPr>\(p)</w:tc>"
                }
                tbl += "</w:tr>"
            }
            tbl += "</w:tbl>"
            // Word는 표 바로 뒤에 문단을 요구한다.
            body += tbl + "<w:p/>"
        }

        private mutating func appendImage(_ ref: ImageRef) {
            images.append(ref)
            let rId = nextRelId()
            rels.append((rId, "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                         "media/\(ref.fileName)", false))

            let (pxW, pxH) = pixelSize(ref.data)
            let targetW = ref.width ?? pxW
            let scale = pxW > 0 ? Double(targetW) / Double(pxW) : 1
            let targetH = max(1, Int(Double(pxH) * scale))
            let cx = targetW * emuPerPx
            let cy = targetH * emuPerPx
            let docPrId = images.count

            let drawing = "<w:r><w:drawing>"
                + "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
                + "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
                + "<wp:docPr id=\"\(docPrId)\" name=\"\(ref.fileName)\"/>"
                + "<a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">"
                + "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
                + "<pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
                + "<pic:nvPicPr><pic:cNvPr id=\"\(docPrId)\" name=\"\(ref.fileName)\"/><pic:cNvPicPr/></pic:nvPicPr>"
                + "<pic:blipFill><a:blip r:embed=\"\(rId)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
                + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
                + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
                + "</pic:pic></a:graphicData></a:graphic></wp:inline>"
                + "</w:drawing></w:r>"
            body += "<w:p>\(drawing)</w:p>"
        }

        // MARK: 인라인 runs

        private mutating func runsXML(_ inlines: [Inline],
                                      forceBold: Bool = false, forceSize: Int? = nil,
                                      defaultItalic: Bool = false, defaultColor: String? = nil) -> String {
            var out = ""
            for inline in inlines {
                let run = runXML(inline, forceBold: forceBold, forceSize: forceSize,
                                 defaultItalic: defaultItalic, defaultColor: defaultColor)
                // 링크는 w:hyperlink로 감싼다(외부 관계).
                if let link = inline.link {
                    let rId = nextRelId()
                    rels.append((rId, "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
                                 link, true))
                    out += "<w:hyperlink r:id=\"\(rId)\">\(run)</w:hyperlink>"
                } else {
                    out += run
                }
            }
            return out
        }

        private func runXML(_ inline: Inline,
                            forceBold: Bool, forceSize: Int?,
                            defaultItalic: Bool, defaultColor: String?) -> String {
            var rPr = ""
            if forceBold || inline.bold { rPr += "<w:b/>" }
            if defaultItalic || inline.italic { rPr += "<w:i/>" }
            if inline.code {
                rPr += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/>"
            }
            if let size = forceSize { rPr += "<w:sz w:val=\"\(size)\"/>" }
            // 색상: 인라인 지정 > 기본색 > (링크면 파랑)
            if let color = inline.color {
                rPr += "<w:color w:val=\"\(hex6(color))\"/>"
            } else if inline.link != nil {
                rPr += "<w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/>"
            } else if let dc = defaultColor {
                rPr += "<w:color w:val=\"\(hex6(dc))\"/>"
            }
            let rPrXML = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
            return "<w:r>\(rPrXML)<w:t xml:space=\"preserve\">\(XMLEscape.text(inline.text))</w:t></w:r>"
        }

        private func paragraph(_ runs: String) -> String {
            runs.isEmpty ? "<w:p/>" : "<w:p>\(runs)</w:p>"
        }

        // MARK: XML 조립

        func documentXML() -> Data {
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<w:document "
                + "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" "
                + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
                + "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" "
                + "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
                + "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
                + "<w:body>\(body)"
                + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
                + "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr>"
                + "</w:body></w:document>"
            return Data(xml.utf8)
        }

        func documentRels() -> Data {
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            for rel in rels {
                let mode = rel.external ? " TargetMode=\"External\"" : ""
                xml += "<Relationship Id=\"\(rel.id)\" Type=\"\(rel.type)\" Target=\"\(XMLEscape.text(rel.target))\"\(mode)/>"
            }
            xml += "</Relationships>"
            return Data(xml.utf8)
        }
    }

    // MARK: - 정적 파트

    private static func contentTypes() -> Data {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Default Extension=\"png\" ContentType=\"image/png\"/>"
            + "<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>"
            + "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>"
            + "<Default Extension=\"gif\" ContentType=\"image/gif\"/>"
            + "<Override PartName=\"/word/document.xml\" "
            + "ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "</Types>"
        return Data(xml.utf8)
    }

    private static func rootRels() -> Data {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" "
            + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" "
            + "Target=\"word/document.xml\"/>"
            + "</Relationships>"
        return Data(xml.utf8)
    }

    // MARK: - 이미지 헬퍼

    /// 이미지 바이너리에서 픽셀 크기를 추출한다. 실패 시 (가로 400, 세로 300) 가정.
    private static func pixelSize(_ data: Data) -> (Int, Int) {
        if let rep = NSBitmapImageRep(data: data) {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return (400, 300)
    }

    /// "#RRGGBB" 또는 "RRGGBB" → "RRGGBB" (Word color는 # 없는 6자리 hex).
    private static func hex6(_ s: String) -> String {
        var v = s
        if v.hasPrefix("#") { v.removeFirst() }
        return v.count == 6 ? v.uppercased() : "000000"
    }
}
