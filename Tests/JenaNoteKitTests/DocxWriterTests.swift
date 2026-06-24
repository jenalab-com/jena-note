import XCTest
import AppKit
@testable import JenaNoteKit

final class DocxWriterTests: XCTestCase {

    // 헬퍼: docx 생성 → 임시파일 → unzip으로 특정 엔트리 내용 추출
    private func docxEntry(_ blocks: [Block], entry: String) throws -> String {
        let data = DocxWriter.write(blocks)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docxtest-\(UUID().uuidString).docx")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docxout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", tmp.path, "-d", outDir.path]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run(); proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "docx unzip 실패")

        return try String(contentsOf: outDir.appendingPathComponent(entry), encoding: .utf8)
    }

    // MARK: - 무결성

    func testDocxIsValidZip() throws {
        let data = DocxWriter.write([.paragraph([Inline(text: "안녕")])])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docxvalid-\(UUID().uuidString).docx")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-t", tmp.path]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run(); proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, out)
        XCTAssertTrue(out.contains("No errors detected"), out)
    }

    // MARK: - 본문 노드

    func testHeadingAndParagraph() throws {
        let xml = try docxEntry([
            .heading(level: 1, inlines: [Inline(text: "제목")]),
            .paragraph([Inline(text: "본문 ", bold: false), Inline(text: "굵게", bold: true)])
        ], entry: "word/document.xml")
        XCTAssertTrue(xml.contains("제목"))
        XCTAssertTrue(xml.contains("굵게"))
        XCTAssertTrue(xml.contains("<w:b/>"), "굵게 run property가 있어야 한다")
    }

    func testTableCells() throws {
        let xml = try docxEntry([
            .table(rows: [
                [[Inline(text: "이름")], [Inline(text: "나이")]],
                [[Inline(text: "철수")], [Inline(text: "20")]]
            ], headerRow: 0)
        ], entry: "word/document.xml")
        XCTAssertTrue(xml.contains("<w:tbl>"))
        XCTAssertTrue(xml.contains("이름"))
        XCTAssertTrue(xml.contains("철수"))
        XCTAssertTrue(xml.contains("<w:tc>"))
    }

    func testInlineColorAndCode() throws {
        let xml = try docxEntry([
            .paragraph([
                Inline(text: "빨강", color: "#FF0000"),
                Inline(text: "코드", code: true)
            ])
        ], entry: "word/document.xml")
        XCTAssertTrue(xml.contains("FF0000"), "색상 hex가 있어야 한다")
        XCTAssertTrue(xml.contains("Menlo"), "코드 폰트가 있어야 한다")
    }

    func testLinkCreatesRelationship() throws {
        let rels = try docxEntry([
            .paragraph([Inline(text: "링크", link: "https://example.com")])
        ], entry: "word/_rels/document.xml.rels")
        XCTAssertTrue(rels.contains("https://example.com"))
        XCTAssertTrue(rels.contains("hyperlink"))
        XCTAssertTrue(rels.contains("TargetMode=\"External\""))
    }

    // MARK: - Word 호환 (textutil 파싱) + 수동 검증 샘플 저장

    func testComprehensiveDocxParsesWithTextutil() throws {
        let blocks: [Block] = [
            .heading(level: 1, inlines: [Inline(text: "내보내기 테스트 문서")]),
            .paragraph([Inline(text: "일반 본문과 "), Inline(text: "굵게", bold: true),
                        Inline(text: ", "), Inline(text: "기울임", italic: true),
                        Inline(text: ", "), Inline(text: "코드", code: true), Inline(text: " 서식.")]),
            .heading(level: 2, inlines: [Inline(text: "목록")]),
            .listItem(ordered: false, index: 0, inlines: [Inline(text: "사과")]),
            .listItem(ordered: false, index: 0, inlines: [Inline(text: "바나나")]),
            .listItem(ordered: true, index: 1, inlines: [Inline(text: "첫째")]),
            .listItem(ordered: true, index: 2, inlines: [Inline(text: "둘째")]),
            .blockquote([Inline(text: "인용문입니다.")]),
            .codeBlock("let x = 1\nlet y = 2"),
            .heading(level: 3, inlines: [Inline(text: "표")]),
            .table(rows: [
                [[Inline(text: "이름")], [Inline(text: "나이")]],
                [[Inline(text: "철수")], [Inline(text: "20")]],
                [[Inline(text: "영희")], [Inline(text: "21")]]
            ], headerRow: 0),
            .horizontalRule,
            .paragraph([Inline(text: "링크: "), Inline(text: "예시", link: "https://example.com")]),
            .paragraph([Inline(text: "색상", color: "#1E88E5")])
        ]
        let data = DocxWriter.write(blocks)

        // 수동 검증용 샘플을 스크래치패드에 남긴다(Word/Pages/한글에서 직접 열어보기).
        let sample = URL(fileURLWithPath: "/private/tmp/claude-502/-Volumes-Backup-Project-jena-source-jena-note/751f28cb-dc26-482f-8e9b-babe7511c476/scratchpad/sample-export.docx")
        try? data.write(to: sample)

        // textutil로 파싱 가능한지 = Word 호환의 강한 신호.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("textutil-\(UUID().uuidString).docx")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-convert", "txt", "-stdout", tmp.path]
        let pipe = Pipe(); proc.standardOutput = pipe
        let errPipe = Pipe(); proc.standardError = errPipe
        try proc.run(); proc.waitUntilExit()
        let txt = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(proc.terminationStatus, 0, "textutil이 docx를 열지 못했다:\n\(err)")
        // 핵심 텍스트가 변환 결과에 살아 있는지
        XCTAssertTrue(txt.contains("내보내기 테스트 문서"), "제목 누락:\n\(txt)")
        XCTAssertTrue(txt.contains("굵게"), "본문 누락")
        XCTAssertTrue(txt.contains("철수"), "표 셀 누락")
        XCTAssertTrue(txt.contains("예시"), "링크 텍스트 누락")
    }

    // MARK: - 이미지

    func testImageEmbedAndRelationship() throws {
        // 2x2 PNG
        let img = NSImage(size: NSSize(width: 2, height: 2))
        img.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); img.unlockFocus()
        let tiff = img.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!

        let blocks: [Block] = [.image(ImageRef(data: png, fileName: "image1.png", width: nil))]
        let data = DocxWriter.write(blocks)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docximg-\(UUID().uuidString).docx")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docximgout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", tmp.path, "-d", outDir.path]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run(); proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        // 이미지 바이너리가 패키지 안에 있고
        let mediaPath = outDir.appendingPathComponent("word/media/image1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaPath.path), "이미지가 임베드돼야 한다")
        // 관계가 걸려 있어야 한다
        let rels = try String(contentsOf: outDir.appendingPathComponent("word/_rels/document.xml.rels"), encoding: .utf8)
        XCTAssertTrue(rels.contains("media/image1.png"))
        let doc = try String(contentsOf: outDir.appendingPathComponent("word/document.xml"), encoding: .utf8)
        XCTAssertTrue(doc.contains("<w:drawing>"), "drawing 노드가 있어야 한다")
        XCTAssertTrue(doc.contains("r:embed="), "blip embed 참조가 있어야 한다")
    }
}
