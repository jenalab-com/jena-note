import Foundation

// MARK: - HwpxWriter
//
// `[Block]`(IR) → `.hwpx`(OWPML) Data. 의존성 0, ZipArchive로 패키징.
//
// 실제 한글(Hancom Office) 산출물의 OWPML 구조를 그대로 복제한다 — 네임스페이스,
// charPr/paraPr 스키마, 섹션 설정(secPr), 문단(hp:p)·런(hp:run)·텍스트(hp:t) 구조.
// 서식은 한글 방식대로: charPr를 header에 미리 정의하고 section에서 ID로 참조한다.
//
// 패키지 레이아웃 (mimetype이 첫 엔트리 + 무압축 — ZipArchive가 전부 stored라 자동 충족):
//   mimetype                  ← "application/hwp+zip"
//   version.xml
//   META-INF/container.xml
//   META-INF/manifest.xml
//   Contents/content.hpf
//   Contents/header.xml       ← 폰트·서식(charPr)·문단모양(paraPr)·스타일
//   Contents/section0.xml     ← 본문
//   settings.xml
//
// 1차 범위: 제목·본문·목록·인용·코드·구분선 + 인라인(굵게·기울임·색상·글자크기).
//   표는 행별 텍스트로 평탄화(내용 보존, 격자는 hwpx 2차), 이미지는 생략하고 건너뜀 집계.

enum HwpxWriter {

    /// 결과(데이터 + 건너뛴 이미지 수). 메뉴 액션에서 경고에 쓸 수 있도록 분리.
    struct Output {
        var data: Data
        var imageSkipped: Int
    }

    static func write(_ blocks: [Block]) -> Data {
        build(blocks).data
    }

    static func build(_ blocks: [Block]) -> Output {
        var ctx = Context()
        ctx.build(blocks)

        var zip = ZipArchive()
        zip.addEntry(path: "mimetype", data: Data("application/hwp+zip".utf8))   // 첫 엔트리 + 무압축
        zip.addEntry(path: "version.xml", data: versionXML())
        zip.addEntry(path: "META-INF/container.xml", data: containerXML())
        zip.addEntry(path: "META-INF/manifest.xml", data: manifestXML())
        zip.addEntry(path: "Contents/content.hpf", data: contentHpf())
        zip.addEntry(path: "Contents/header.xml", data: ctx.headerXML())
        zip.addEntry(path: "Contents/section0.xml", data: ctx.sectionXML())
        zip.addEntry(path: "settings.xml", data: settingsXML())
        return Output(data: zip.finalize(), imageSkipped: ctx.imageSkipped)
    }

    // MARK: - CharStyle (charPr로 변환될 서식 조합)

    private struct CharStyle: Hashable {
        var bold = false
        var italic = false
        var height = 1000          // 글자 크기 (1/100 pt). 1000 = 10pt.
        var color = "#000000"      // "#RRGGBB"
    }

    /// 블록 컨텍스트가 인라인에 강제하는 기본 서식.
    private struct BlockStyle {
        var bold = false
        var italic = false
        var height = 1000
        var color = "#000000"
    }

    // MARK: - Context (본문 + charPr 수집)

    private struct Context {
        var body = ""
        var charStyles: [CharStyle] = []
        var styleMap: [CharStyle: Int] = [:]
        var imageSkipped = 0
        private var firstParaEmitted = false

        mutating func charPrID(_ s: CharStyle) -> Int {
            if let id = styleMap[s] { return id }
            let id = charStyles.count
            charStyles.append(s)
            styleMap[s] = id
            return id
        }

        mutating func build(_ blocks: [Block]) {
            _ = charPrID(CharStyle())   // id 0 = 기본 서식 보장

            for block in blocks {
                switch block {
                case let .heading(level, inlines):
                    let h = level == 1 ? 1600 : (level == 2 ? 1400 : 1200)
                    emitPara(paraPr: 0, runs: runsXML(inlines, base: BlockStyle(bold: true, height: h)))
                case let .paragraph(inlines):
                    emitPara(paraPr: 0, runs: runsXML(inlines, base: BlockStyle()))
                case let .listItem(ordered, index, inlines):
                    let marker = ordered ? "\(index). " : "• "
                    let runs = runXML(text: marker, style: CharStyle()) + runsXML(inlines, base: BlockStyle())
                    emitPara(paraPr: 1, runs: runs)
                case let .blockquote(inlines):
                    emitPara(paraPr: 1, runs: runsXML(inlines, base: BlockStyle(italic: true, color: "#666666")))
                case let .codeBlock(code):
                    for line in code.components(separatedBy: "\n") {
                        emitPara(paraPr: 1, runs: runXML(text: line, style: CharStyle(color: "#444444")))
                    }
                case let .table(rows, headerRow):
                    // 행별 텍스트 평탄화 (내용 보존, 격자는 hwpx 2차).
                    for (r, row) in rows.enumerated() {
                        let cellTexts = row.map { plainText($0) }
                        let line = cellTexts.joined(separator: "   |   ")
                        let style = r == headerRow ? CharStyle(bold: true) : CharStyle()
                        emitPara(paraPr: 0, runs: runXML(text: line, style: style))
                    }
                case .horizontalRule:
                    emitPara(paraPr: 0, runs: runXML(text: "────────────────────────",
                                                     style: CharStyle(color: "#999999")))
                case .image:
                    imageSkipped += 1   // 1차 hwpx는 이미지 생략
                }
            }

            // 블록이 없거나 첫 문단이 안 나왔으면, secPr를 담을 빈 문단을 둔다.
            if !firstParaEmitted {
                emitPara(paraPr: 0, runs: "<hp:run charPrIDRef=\"0\"/>")
            }
        }

        // MARK: 문단·런

        private mutating func emitPara(paraPr: Int, runs: String) {
            var content = runs
            if !firstParaEmitted {
                content = HwpxWriter.secPrRun() + runs   // 첫 문단 첫 런에 섹션 설정
                firstParaEmitted = true
            }
            body += "<hp:p id=\"0\" paraPrIDRef=\"\(paraPr)\" styleIDRef=\"0\" "
                + "pageBreak=\"0\" columnBreak=\"0\" merged=\"0\">\(content)</hp:p>"
        }

        private mutating func runsXML(_ inlines: [Inline], base: BlockStyle) -> String {
            var out = ""
            for inline in inlines {
                let style = CharStyle(
                    bold: inline.bold || base.bold,
                    italic: inline.italic || base.italic,
                    height: base.height,
                    color: inline.color ?? base.color
                )
                out += runXML(text: inline.text, style: style)
            }
            return out
        }

        private mutating func runXML(text: String, style: CharStyle) -> String {
            let id = charPrID(style)
            if text.isEmpty { return "<hp:run charPrIDRef=\"\(id)\"/>" }
            return "<hp:run charPrIDRef=\"\(id)\"><hp:t>\(XMLEscape.text(text))</hp:t></hp:run>"
        }

        private func plainText(_ inlines: [Inline]) -> String {
            inlines.map(\.text).joined()
        }

        // MARK: XML 조립

        func headerXML() -> Data {
            var charProps = ""
            for (id, style) in charStyles.enumerated() {
                charProps += HwpxWriter.charPrXML(id: id, style: style)
            }

            let xml = HwpxWriter.xmlDecl
                + "<hh:head " + HwpxWriter.namespaces + " version=\"1.5\" secCnt=\"1\">"
                + "<hh:beginNum page=\"1\" footnote=\"1\" endnote=\"1\" pic=\"1\" tbl=\"1\" equation=\"1\"/>"
                + "<hh:refList>"
                + HwpxWriter.fontfacesXML()
                + HwpxWriter.borderFillsXML()
                + "<hh:charProperties itemCnt=\"\(charStyles.count)\">\(charProps)</hh:charProperties>"
                + HwpxWriter.tabPropertiesXML()
                + "<hh:paraProperties itemCnt=\"2\">"
                + HwpxWriter.paraPrXML(id: 0, marginLeft: 0)
                + HwpxWriter.paraPrXML(id: 1, marginLeft: 2834)
                + "</hh:paraProperties>"
                + "<hh:styles itemCnt=\"1\">"
                + "<hh:style id=\"0\" type=\"PARA\" name=\"바탕글\" engName=\"Normal\" "
                + "paraPrIDRef=\"0\" charPrIDRef=\"0\" nextStyleIDRef=\"0\" langID=\"1042\" lockForm=\"0\"/>"
                + "</hh:styles>"
                + "</hh:refList>"
                + "</hh:head>"
            return Data(xml.utf8)
        }

        func sectionXML() -> Data {
            let xml = HwpxWriter.xmlDecl
                + "<hs:sec " + HwpxWriter.namespaces + ">"
                + body
                + "</hs:sec>"
            return Data(xml.utf8)
        }
    }

    // MARK: - 공통 XML 상수

    private static let xmlDecl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

    private static let namespaces =
        "xmlns:ha=\"http://www.hancom.co.kr/hwpml/2011/app\" "
        + "xmlns:hp=\"http://www.hancom.co.kr/hwpml/2011/paragraph\" "
        + "xmlns:hp10=\"http://www.hancom.co.kr/hwpml/2016/paragraph\" "
        + "xmlns:hs=\"http://www.hancom.co.kr/hwpml/2011/section\" "
        + "xmlns:hc=\"http://www.hancom.co.kr/hwpml/2011/core\" "
        + "xmlns:hh=\"http://www.hancom.co.kr/hwpml/2011/head\" "
        + "xmlns:hhs=\"http://www.hancom.co.kr/hwpml/2011/history\" "
        + "xmlns:hm=\"http://www.hancom.co.kr/hwpml/2011/master-page\" "
        + "xmlns:hpf=\"http://www.hancom.co.kr/schema/2011/hpf\" "
        + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
        + "xmlns:opf=\"http://www.idpf.org/2007/opf/\" "
        + "xmlns:epub=\"http://www.idpf.org/2007/ops\" "
        + "xmlns:config=\"urn:oasis:names:tc:opendocument:xmlns:config:1.0\""

    // MARK: - charPr / paraPr / 기타 refList

    private static func charPrXML(id: Int, style: CharStyle) -> String {
        var s = "<hh:charPr id=\"\(id)\" height=\"\(style.height)\" textColor=\"\(style.color)\" "
            + "shadeColor=\"none\" useFontSpace=\"0\" useKerning=\"0\" symMark=\"NONE\" borderFillIDRef=\"2\">"
        s += "<hh:fontRef hangul=\"0\" latin=\"0\" hanja=\"0\" japanese=\"0\" other=\"0\" symbol=\"0\" user=\"0\"/>"
        s += "<hh:ratio hangul=\"100\" latin=\"100\" hanja=\"100\" japanese=\"100\" other=\"100\" symbol=\"100\" user=\"100\"/>"
        s += "<hh:spacing hangul=\"0\" latin=\"0\" hanja=\"0\" japanese=\"0\" other=\"0\" symbol=\"0\" user=\"0\"/>"
        s += "<hh:relSz hangul=\"100\" latin=\"100\" hanja=\"100\" japanese=\"100\" other=\"100\" symbol=\"100\" user=\"100\"/>"
        s += "<hh:offset hangul=\"0\" latin=\"0\" hanja=\"0\" japanese=\"0\" other=\"0\" symbol=\"0\" user=\"0\"/>"
        if style.bold { s += "<hh:bold/>" }
        if style.italic { s += "<hh:italic/>" }
        s += "<hh:underline type=\"NONE\" shape=\"SOLID\" color=\"#000000\"/>"
        s += "<hh:strikeout shape=\"NONE\" color=\"#000000\"/>"
        s += "<hh:outline type=\"NONE\"/>"
        s += "<hh:shadow type=\"NONE\" color=\"#C0C0C0\" offsetX=\"10\" offsetY=\"10\"/>"
        s += "</hh:charPr>"
        return s
    }

    private static func paraPrXML(id: Int, marginLeft: Int) -> String {
        let margin = "<hh:margin>"
            + "<hc:intent value=\"0\" unit=\"HWPUNIT\"/>"
            + "<hc:left value=\"\(marginLeft)\" unit=\"HWPUNIT\"/>"
            + "<hc:right value=\"0\" unit=\"HWPUNIT\"/>"
            + "<hc:prev value=\"0\" unit=\"HWPUNIT\"/>"
            + "<hc:next value=\"0\" unit=\"HWPUNIT\"/>"
            + "</hh:margin>"
            + "<hh:lineSpacing type=\"PERCENT\" value=\"160\" unit=\"HWPUNIT\"/>"
        return "<hh:paraPr id=\"\(id)\" tabPrIDRef=\"0\" condense=\"0\" fontLineHeight=\"0\" "
            + "snapToGrid=\"1\" suppressLineNumbers=\"0\" checked=\"0\">"
            + "<hh:align horizontal=\"LEFT\" vertical=\"BASELINE\"/>"
            + "<hh:heading type=\"NONE\" idRef=\"0\" level=\"0\"/>"
            + "<hh:breakSetting breakLatinWord=\"KEEP_WORD\" breakNonLatinWord=\"KEEP_WORD\" "
            + "widowOrphan=\"0\" keepWithNext=\"0\" keepLines=\"0\" pageBreakBefore=\"0\" lineWrap=\"BREAK\"/>"
            + "<hh:autoSpacing eAsianEng=\"0\" eAsianNum=\"0\"/>"
            + "<hp:switch>"
            + "<hp:case hp:required-namespace=\"http://www.hancom.co.kr/hwpml/2016/HwpUnitChar\">\(margin)</hp:case>"
            + "<hp:default>\(margin)</hp:default>"
            + "</hp:switch>"
            + "<hh:border borderFillIDRef=\"2\" offsetLeft=\"0\" offsetRight=\"0\" offsetTop=\"0\" "
            + "offsetBottom=\"0\" connect=\"0\" ignoreMargin=\"0\"/>"
            + "</hh:paraPr>"
    }

    private static func fontfacesXML() -> String {
        let langs = ["HANGUL", "LATIN", "HANJA", "JAPANESE", "OTHER", "SYMBOL", "USER"]
        var faces = ""
        for lang in langs {
            faces += "<hh:fontface lang=\"\(lang)\" fontCnt=\"1\">"
                + "<hh:font id=\"0\" face=\"함초롬바탕\" type=\"TTF\" isEmbedded=\"0\">"
                + "<hh:typeInfo familyType=\"FCAT_GOTHIC\" weight=\"6\" proportion=\"4\" contrast=\"0\" "
                + "strokeVariation=\"1\" armStyle=\"1\" letterform=\"1\" midline=\"1\" xHeight=\"1\"/>"
                + "</hh:font></hh:fontface>"
        }
        return "<hh:fontfaces itemCnt=\"\(langs.count)\">\(faces)</hh:fontfaces>"
    }

    private static func borderFillsXML() -> String {
        func fill(_ id: Int) -> String {
            "<hh:borderFill id=\"\(id)\" threeD=\"0\" shadow=\"0\" centerLine=\"NONE\" breakCellSeparateLine=\"0\">"
            + "<hh:slash type=\"NONE\" Crooked=\"0\" isCounter=\"0\"/>"
            + "<hh:backSlash type=\"NONE\" Crooked=\"0\" isCounter=\"0\"/>"
            + "<hh:leftBorder type=\"NONE\" width=\"0.1 mm\" color=\"#000000\"/>"
            + "<hh:rightBorder type=\"NONE\" width=\"0.1 mm\" color=\"#000000\"/>"
            + "<hh:topBorder type=\"NONE\" width=\"0.1 mm\" color=\"#000000\"/>"
            + "<hh:bottomBorder type=\"NONE\" width=\"0.1 mm\" color=\"#000000\"/>"
            + "<hh:diagonal type=\"SOLID\" width=\"0.1 mm\" color=\"#000000\"/>"
            + "</hh:borderFill>"
        }
        return "<hh:borderFills itemCnt=\"2\">\(fill(1))\(fill(2))</hh:borderFills>"
    }

    private static func tabPropertiesXML() -> String {
        "<hh:tabProperties itemCnt=\"1\"><hh:tabPr id=\"0\" autoTabLeft=\"0\" autoTabRight=\"0\"/></hh:tabProperties>"
    }

    /// 첫 문단 첫 런에 들어가는 섹션 설정 (A4, 여백). 실제 한글 산출물 값 복제.
    private static func secPrRun() -> String {
        "<hp:run charPrIDRef=\"0\">"
        + "<hp:secPr id=\"\" textDirection=\"HORIZONTAL\" spaceColumns=\"1134\" tabStop=\"8000\" "
        + "tabStopVal=\"4000\" tabStopUnit=\"HWPUNIT\" outlineShapeIDRef=\"1\" memoShapeIDRef=\"0\" "
        + "textVerticalWidthHead=\"0\" masterPageCnt=\"0\">"
        + "<hp:grid lineGrid=\"0\" charGrid=\"0\" wonggojiFormat=\"0\"/>"
        + "<hp:startNum pageStartsOn=\"BOTH\" page=\"0\" pic=\"0\" tbl=\"0\" equation=\"0\"/>"
        + "<hp:visibility hideFirstHeader=\"0\" hideFirstFooter=\"0\" hideFirstMasterPage=\"0\" "
        + "border=\"SHOW_ALL\" fill=\"SHOW_ALL\" hideFirstPageNum=\"0\" hideFirstEmptyLine=\"0\" showLineNumber=\"0\"/>"
        + "<hp:lineNumberShape restartType=\"0\" countBy=\"0\" distance=\"0\" startNumber=\"0\"/>"
        + "<hp:pagePr landscape=\"WIDELY\" width=\"59528\" height=\"84186\" gutterType=\"LEFT_ONLY\">"
        + "<hp:margin header=\"4252\" footer=\"4252\" gutter=\"0\" left=\"8504\" right=\"8504\" top=\"5668\" bottom=\"4252\"/>"
        + "</hp:pagePr>"
        + "<hp:pageBorderFill type=\"BOTH\" borderFillIDRef=\"1\" textBorder=\"PAPER\" headerInside=\"0\" "
        + "footerInside=\"0\" fillArea=\"PAPER\"><hp:offset left=\"1417\" right=\"1417\" top=\"1417\" bottom=\"1417\"/></hp:pageBorderFill>"
        + "</hp:secPr>"
        + "<hp:ctrl><hp:colPr id=\"\" type=\"NEWSPAPER\" layout=\"LEFT\" colCount=\"1\" sameSz=\"1\" sameGap=\"0\"/></hp:ctrl>"
        + "</hp:run>"
    }

    // MARK: - 정적 패키지 파트

    private static func versionXML() -> Data {
        Data(("\(xmlDecl)<hv:HCFVersion xmlns:hv=\"http://www.hancom.co.kr/hwpml/2011/version\" "
            + "tagetApplication=\"WORDPROCESSOR\" major=\"5\" minor=\"1\" micro=\"1\" buildNumber=\"0\" "
            + "os=\"1\" xmlVersion=\"1.5\" application=\"Jena Note\" appVersion=\"1.3.0\"/>").utf8)
    }

    private static func containerXML() -> Data {
        Data(("\(xmlDecl)<ocf:container xmlns:ocf=\"urn:oasis:names:tc:opendocument:xmlns:container\" "
            + "xmlns:hpf=\"http://www.hancom.co.kr/schema/2011/hpf\"><ocf:rootfiles>"
            + "<ocf:rootfile full-path=\"Contents/content.hpf\" media-type=\"application/hwpml-package+xml\"/>"
            + "</ocf:rootfiles></ocf:container>").utf8)
    }

    private static func manifestXML() -> Data {
        Data(("\(xmlDecl)<odf:manifest xmlns:odf=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\"/>").utf8)
    }

    private static func contentHpf() -> Data {
        Data(("\(xmlDecl)<opf:package "
            + "xmlns:opf=\"http://www.idpf.org/2007/opf/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "version=\"\" unique-identifier=\"\" id=\"\">"
            + "<opf:metadata><opf:title>Jena Note</opf:title><opf:language>ko</opf:language></opf:metadata>"
            + "<opf:manifest>"
            + "<opf:item id=\"header\" href=\"Contents/header.xml\" media-type=\"application/xml\"/>"
            + "<opf:item id=\"section0\" href=\"Contents/section0.xml\" media-type=\"application/xml\"/>"
            + "<opf:item id=\"settings\" href=\"settings.xml\" media-type=\"application/xml\"/>"
            + "</opf:manifest>"
            + "<opf:spine><opf:itemref idref=\"header\" linear=\"yes\"/><opf:itemref idref=\"section0\" linear=\"yes\"/></opf:spine>"
            + "</opf:package>").utf8)
    }

    private static func settingsXML() -> Data {
        Data(("\(xmlDecl)<ha:HWPApplicationSetting "
            + "xmlns:ha=\"http://www.hancom.co.kr/hwpml/2011/app\" "
            + "xmlns:config=\"urn:oasis:names:tc:opendocument:xmlns:config:1.0\">"
            + "<ha:CaretPosition listIDRef=\"0\" paraIDRef=\"0\" pos=\"0\"/>"
            + "</ha:HWPApplicationSetting>").utf8)
    }
}
