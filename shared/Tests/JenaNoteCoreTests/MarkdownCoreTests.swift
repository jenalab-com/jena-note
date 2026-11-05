import XCTest
import JenaNoteCoreTestSupport
@testable import JenaNoteCore

final class MarkdownCoreTests: XCTestCase {
    func testCorpusMatchesWhatMacOSSaves() {
        for item in MarkdownCorpus.cases {
            XCTAssertEqual(MarkdownWriter.write(MarkdownParser.parse(item.input)), item.expected, item.name)
        }
    }

    func testParsesBlocksIntoTheNeutralModel() {
        let blocks = MarkdownParser.parse("# 제목\n\n본문 **굵게**\n- 항목\n3. 번호\n> 인용\n---\n```\ncode\n```")
        XCTAssertEqual(blocks, [
            .heading(level: 1, runs: [MarkdownRun(text: "제목")]),
            .blank,
            .paragraph([MarkdownRun(text: "본문 "), MarkdownRun(text: "굵게", bold: true)]),
            .listItem(ordered: false, index: 0, runs: [MarkdownRun(text: "항목")]),
            .listItem(ordered: true, index: 3, runs: [MarkdownRun(text: "번호")]),
            .blockquote([MarkdownRun(text: "인용")]),
            .horizontalRule,
            .codeBlock(lines: ["code"]),
        ])
    }

    func testParsesInlineContentKinds() {
        XCTAssertEqual(MarkdownParser.parseInline("[x](u)[^1]![a](b.png)<img src=\"c.png\" width=\"9\">`d`"), [
            MarkdownRun(text: "x", link: "u"),
            MarkdownRun(.noteReference("1")),
            MarkdownRun(.image(path: "b.png", alt: "a", width: nil)),
            MarkdownRun(.image(path: "c.png", alt: "", width: 9)),
            MarkdownRun(text: "d", code: true),
        ])
    }

    func testColorAppliesToEveryInnerRun() {
        XCTAssertEqual(MarkdownParser.parseInline("<span style=\"color: #ABC\">a**b**</span>"), [
            MarkdownRun(text: "a", color: "#AABBCC"),
            MarkdownRun(text: "b", bold: true, color: "#AABBCC"),
        ])
    }

    func testTableCellsTakeWeightFromTheirRow() throws {
        let blocks = MarkdownParser.parse("| *a* | c |\n|---|---|\n| **b** |")
        guard case .table(let table)? = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(table.rows, [
            [[MarkdownRun(text: "a", bold: true)], [MarkdownRun(text: "c", bold: true)]],
            [[MarkdownRun(text: "b")], []],
        ])
        XCTAssertEqual(table.headerRow, 0)
    }

    /// Colors in cells are where this code differs from AppKit, which overwrites them with the
    /// label color and then saves that as if the author had chosen it.
    func testColorInATableCellIsKept() {
        let input = "| A |\n|---|\n| <span style=\"color: #FF0000\">x</span> |"
        XCTAssertEqual(MarkdownWriter.write(MarkdownParser.parse(input)),
                       "| **A** |\n| --- |\n| <span style=\"color: #FF0000\">x</span> |\n")
    }

    func testRejectsInvalidColors() {
        XCTAssertNil(MarkdownParser.normalizedColor("#12345"))
        XCTAssertNil(MarkdownParser.normalizedColor("#GGGGGG"))
        XCTAssertEqual(MarkdownParser.normalizedColor("#a1b2c3"), "#A1B2C3")
    }

    func testNoteIDsFollowTheAllowedCharacters() {
        XCTAssertTrue(MarkdownNote.validID("a-1_B"))
        XCTAssertFalse(MarkdownNote.validID(""))
        XCTAssertFalse(MarkdownNote.validID("가"))
        XCTAssertFalse(MarkdownNote.validID(String(repeating: "a", count: 65)))
    }
}
