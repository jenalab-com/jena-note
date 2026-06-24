import XCTest
import AppKit
@testable import JenaNoteKit

final class DocumentModelBuilderTests: XCTestCase {

    // 헬퍼: md → IR 블록
    private func blocks(_ md: String, baseURL: URL? = nil) -> [Block] {
        let attributed = MarkdownSerializer.parse(md, baseURL: baseURL)
        return DocumentModelBuilder.build(attributed, baseURL: baseURL).blocks
    }

    // MARK: - 제목

    func testHeadingLevels() {
        let bs = blocks("# 제목1\n## 제목2\n### 제목3")
        XCTAssertEqual(bs.count, 3)
        guard case let .heading(l1, i1) = bs[0] else { return XCTFail("h1 아님") }
        XCTAssertEqual(l1, 1)
        XCTAssertEqual(i1.first?.text, "제목1")
        guard case let .heading(l2, _) = bs[1] else { return XCTFail("h2 아님") }
        XCTAssertEqual(l2, 2)
        guard case let .heading(l3, _) = bs[2] else { return XCTFail("h3 아님") }
        XCTAssertEqual(l3, 3)
    }

    // MARK: - 본문 인라인 서식

    func testParagraphInlineFormatting() {
        let bs = blocks("일반 **굵게** 그리고 *기울임* 또 `코드`")
        guard case let .paragraph(inlines) = bs.first else { return XCTFail("paragraph 아님") }
        // 텍스트 결합 검증
        let joined = inlines.map(\.text).joined()
        XCTAssertEqual(joined, "일반 굵게 그리고 기울임 또 코드")
        XCTAssertTrue(inlines.contains { $0.text == "굵게" && $0.bold })
        XCTAssertTrue(inlines.contains { $0.text == "기울임" && $0.italic })
        XCTAssertTrue(inlines.contains { $0.text == "코드" && $0.code })
    }

    func testInlineColorAndLink() {
        let bs = blocks("<span style=\"color: #FF0000\">빨강</span> 그리고 [링크](https://example.com)")
        guard case let .paragraph(inlines) = bs.first else { return XCTFail("paragraph 아님") }
        XCTAssertTrue(inlines.contains { $0.text == "빨강" && $0.color == "#FF0000" })
        XCTAssertTrue(inlines.contains { $0.text == "링크" && $0.link == "https://example.com" })
    }

    // MARK: - 목록

    func testUnorderedList() {
        let bs = blocks("- 사과\n- 바나나")
        XCTAssertEqual(bs.count, 2)
        guard case let .listItem(ordered, _, inlines) = bs.first else { return XCTFail("list 아님") }
        XCTAssertFalse(ordered)
        XCTAssertEqual(inlines.first?.text, "사과")
    }

    func testOrderedList() {
        let bs = blocks("1. 첫째\n2. 둘째")
        guard case let .listItem(ordered, index, inlines) = bs.first else { return XCTFail("list 아님") }
        XCTAssertTrue(ordered)
        XCTAssertEqual(index, 1)
        XCTAssertEqual(inlines.first?.text, "첫째")
        guard case let .listItem(_, index2, _) = bs[1] else { return XCTFail("list 아님") }
        XCTAssertEqual(index2, 2)
    }

    // MARK: - 인용

    func testBlockquote() {
        let bs = blocks("> 인용문입니다")
        guard case let .blockquote(inlines) = bs.first else { return XCTFail("blockquote 아님") }
        XCTAssertEqual(inlines.first?.text, "인용문입니다")
    }

    // MARK: - 코드블록 (연속 묶기)

    func testCodeBlockMerged() {
        let bs = blocks("```\nlet x = 1\nlet y = 2\n```")
        let codeBlocks = bs.compactMap { block -> String? in
            if case let .codeBlock(s) = block { return s }
            return nil
        }
        XCTAssertEqual(codeBlocks.count, 1, "여러 줄이 하나의 코드블록으로 묶여야 한다")
        XCTAssertTrue(codeBlocks[0].contains("let x = 1"))
        XCTAssertTrue(codeBlocks[0].contains("let y = 2"))
    }

    // MARK: - 구분선

    func testHorizontalRule() {
        let bs = blocks("위\n\n---\n\n아래")
        XCTAssertTrue(bs.contains { if case .horizontalRule = $0 { return true }; return false })
    }

    // MARK: - 표

    func testTableGrid() {
        let md = "| 이름 | 나이 |\n|---|---|\n| 철수 | 20 |\n| 영희 | 21 |"
        let bs = blocks(md)
        guard let table = bs.first(where: { if case .table = $0 { return true }; return false }),
              case let .table(rows, headerRow) = table else { return XCTFail("table 아님") }
        XCTAssertEqual(rows.count, 3, "헤더 + 데이터 2행")
        XCTAssertEqual(headerRow, 0)
        XCTAssertEqual(rows[0][0].first?.text, "이름")
        XCTAssertEqual(rows[0][1].first?.text, "나이")
        XCTAssertEqual(rows[1][0].first?.text, "철수")
        XCTAssertEqual(rows[2][1].first?.text, "21")
    }

    // MARK: - 이미지

    func testImageLoadsBinaryWhenBaseURLPresent() throws {
        // 임시 폴더에 작은 PNG를 만들고 노트 옆 attachments/에 둔다.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jntest-\(UUID().uuidString)", isDirectory: true)
        let attachDir = tmp.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 1x1 PNG
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 1, height: 1).fill(); img.unlockFocus()
        let tiff = img.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try png.write(to: attachDir.appendingPathComponent("cat.png"))

        let md = "![고양이](attachments/cat.png)"
        let result = DocumentModelBuilder.build(MarkdownSerializer.parse(md, baseURL: tmp), baseURL: tmp)

        let images = result.blocks.compactMap { block -> ImageRef? in
            if case let .image(ref) = block { return ref }
            return nil
        }
        XCTAssertEqual(images.count, 1)
        XCTAssertFalse(images[0].data.isEmpty, "이미지 바이너리가 로드돼야 한다")
        XCTAssertTrue(images[0].fileName.hasSuffix(".png"))
        XCTAssertEqual(result.imageLoadFailures, 0)
    }

    func testImageFailsGracefullyWithoutBaseURL() {
        let md = "![고양이](attachments/cat.png)"
        let result = DocumentModelBuilder.build(MarkdownSerializer.parse(md), baseURL: nil)
        let hasImage = result.blocks.contains { if case .image = $0 { return true }; return false }
        XCTAssertFalse(hasImage, "baseURL 없으면 이미지 블록은 생기지 않는다")
        XCTAssertEqual(result.imageLoadFailures, 1, "로드 실패가 집계돼야 한다")
    }
}
