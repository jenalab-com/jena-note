import XCTest
@testable import JenaNoteCore

final class MarkdownExportTests: XCTestCase {
    private func export(_ markdown: String, baseFolder: URL? = nil) -> MarkdownExport.Result {
        MarkdownExport.blocks(from: MarkdownParser.parse(markdown), baseFolder: baseFolder)
    }

    func testMapsBlocksAndKeepsInnerBlankLines() {
        XCTAssertEqual(export("# 제목\n\n본문 **굵게**\n- 항목\n2. 번호\n> 인용\n---\n```\ncode\n\nmore\n```\n\n").blocks, [
            .heading(level: 1, inlines: [Inline(text: "제목")]),
            .paragraph([]),
            .paragraph([Inline(text: "본문 "), Inline(text: "굵게", bold: true)]),
            .listItem(ordered: false, index: 0, inlines: [Inline(text: "항목")]),
            .listItem(ordered: true, index: 2, inlines: [Inline(text: "번호")]),
            .blockquote([Inline(text: "인용")]),
            .horizontalRule,
            .codeBlock("code\n\nmore"),
        ])
    }

    func testHeadingBoldFollowsTheSameRuleAsSaving() {
        XCTAssertEqual(export("# **a**\n### **b**").blocks, [
            .heading(level: 1, inlines: [Inline(text: "a")]),
            .heading(level: 3, inlines: [Inline(text: "b", bold: true)]),
        ])
    }

    func testInlineFormattingAndNotes() {
        XCTAssertEqual(export("[x](u) `c` <span style=\"color: #FF0000\">r</span>[^1]\n[^1]: 설명").blocks, [
            .paragraph([Inline(text: "x", link: "u"), Inline(text: " "), Inline(text: "c", code: true), Inline(text: " "),
                        Inline(text: "r", color: "#FF0000"), Inline(text: "[1]")]),
            .paragraph([Inline(text: "[1] "), Inline(text: "설명")]),
        ])
    }

    func testTableKeepsCellsWithoutImages() {
        XCTAssertEqual(export("| A |\n|---|\n| ![a](b.png)x |").blocks, [
            .table(rows: [[[Inline(text: "A", bold: true)]], [[Inline(text: "x")]]], headerRow: 0),
        ])
    }

    func testEmptyCellsAndCodeLinesStayInPlace() {
        XCTAssertEqual(export("|  | B |\n|---|---|\n| 1 | 2 |").blocks, [
            .table(rows: [[[], [Inline(text: "B", bold: true)]], [[Inline(text: "1")], [Inline(text: "2")]]], headerRow: 0),
        ])
        XCTAssertEqual(export("```\n\nabc\n```\n끝").blocks, [.codeBlock("\nabc"), .paragraph([Inline(text: "끝")])])
    }

    func testCellsKeepInlineFormatting() {
        XCTAssertEqual(export("| A |\n|---|\n| *b* **c** |").blocks, [
            .table(rows: [[[Inline(text: "A", bold: true)]],
                          [[Inline(text: "b", italic: true), Inline(text: " "), Inline(text: "c", bold: true)]]], headerRow: 0),
        ])
    }

    func testImagesSplitTextAndLoadRelativeToTheDocument() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true)
        let images = folder.appendingPathComponent("그림", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data([1, 2, 3])
        try bytes.write(to: images.appendingPathComponent("a.PNG"))

        let result = export("앞 ![a](그림/a.PNG) 뒤 <img src=\"그림/a.PNG\" width=\"9\"> ![x](없음.png)", baseFolder: folder)
        XCTAssertEqual(result.blocks, [
            .paragraph([Inline(text: "앞 ")]),
            .image(ImageRef(data: bytes, fileName: "image1.png", width: nil)),
            .paragraph([Inline(text: " 뒤 ")]),
            .image(ImageRef(data: bytes, fileName: "image2.png", width: 9)),
            .paragraph([Inline(text: " ")]),
        ])
        XCTAssertEqual(result.imageLoadFailures, 1)
    }

    func testImagesFailWithoutAFolder() {
        let result = export("![a](b.png)")
        XCTAssertEqual(result.blocks, [])
        XCTAssertEqual(result.imageLoadFailures, 1)
    }
}

final class ProofreadingCheckerTests: XCTestCase {
    func testReportsOffsetsInThePassageAcrossSentences() async throws {
        let checker = ProofreadingChecker { $0.replacingOccurrences(of: "오랫만", with: "오랜만") }
        let text = "😀 첫 문장이다. 오랫만에 만났다."
        let items = try await checker.suggestions(in: text, terms: [])
        XCTAssertEqual(items.count, 1)
        let range = try XCTUnwrap(items.first?.range)
        XCTAssertEqual((text as NSString).substring(with: range), items.first?.original)
        XCTAssertEqual(items.first?.original, "오랫만에")
        XCTAssertEqual(items.first?.replacement, "오랜만에")
        for mark in items.first?.marks ?? [] {
            XCTAssertGreaterThanOrEqual(mark.location, range.location)
        }
    }

    func testPersonalTermsFilterWithoutRunningTheEngineAgain() async throws {
        let calls = CallCounter()
        let checker = ProofreadingChecker { input in
            calls.increment()
            return input.replacingOccurrences(of: "서쥰", with: "서준")
        }
        let text = "서쥰이 왔다."
        let before = try await checker.suggestions(in: text, terms: [])
        XCTAssertEqual(before.count, 1)
        let after = try await checker.suggestions(in: text, terms: ["서쥰"])
        XCTAssertEqual(after.count, 0)
        XCTAssertEqual(calls.value, 1)
    }

    func testEngineFailureReachesTheCaller() async {
        let checker = ProofreadingChecker { _ in throw AIError(message: "boom") }
        do {
            _ = try await checker.suggestions(in: "문장.", terms: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? AIError)?.message, "boom")
        }
    }

    #if os(Windows)
    /// Windows paths are not UTF-8 for narrow file APIs, so a Korean folder must still load.
    func testEngineLoadsAModelFromAKoreanFolder() async throws {
        let model = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("JenaNoteCore/Resources/KiwiModel", isDirectory: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("한글 모델-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in try FileManager.default.contentsOfDirectory(atPath: model.path) {
            try FileManager.default.copyItem(at: model.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        let engine = KiwiProofreadingEngine(modelURL: { folder })
        let corrected = try await engine.check("오랫만에 친구를 만났다.")
        XCTAssertEqual(corrected, "오랜만에 친구를 만났다.")
    }
    #endif
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
