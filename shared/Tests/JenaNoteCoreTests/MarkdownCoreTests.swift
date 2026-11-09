import XCTest
import JenaNoteCoreTestSupport
@testable import JenaNoteCore

final class MarkdownCoreTests: XCTestCase {
    func testCorpusSavesAsExpected() {
        for item in MarkdownCorpus.cases {
            XCTAssertEqual(MarkdownWriter.write(MarkdownParser.parse(item.input)), item.expected, item.name)
        }
    }

    /// Autosave runs again and again, so a saved file must not change on the next save.
    func testSavingAgainChangesNothing() {
        for item in MarkdownCorpus.cases {
            let once = MarkdownWriter.write(MarkdownParser.parse(item.input))
            var current = once
            for _ in 0..<3 {
                let next = MarkdownWriter.write(MarkdownParser.parse(current))
                // A line left blank by an empty heading or quote settles to an empty file.
                if once != "\n" { XCTAssertEqual(next, once, item.name) }
                current = next
            }
        }
    }

    /// Punctuation marks can start a line with spaces or a dash. Saving must keep them as written.
    func testIndentedDialogueSurvivesSavingAndOpening() {
        for line in ["  \"네\"", " '네'", "  - 네", "— 네"] {
            let blocks = MarkdownParser.parse(line + "\n\n다음\n")
            XCTAssertEqual(blocks.first, .paragraph([MarkdownRun(text: line)]), line)
            XCTAssertEqual(MarkdownWriter.write(blocks), line + "\n\n다음\n", line)
        }
    }

    func testJSONKeepsTheWholeModel() throws {
        for item in MarkdownCorpus.cases {
            let blocks = MarkdownParser.parse(item.input)
            XCTAssertEqual(try MarkdownJSON.decode(MarkdownJSON.encode(blocks)), blocks, item.name)
        }
    }

    func testJSONRejectsWhatItCannotRead() {
        XCTAssertThrowsError(try MarkdownJSON.decode("not json"))
        XCTAssertThrowsError(try MarkdownJSON.decode("[{\"type\":\"nope\"}]"))
        XCTAssertThrowsError(try MarkdownJSON.decode("[{\"type\":\"paragraph\",\"runs\":[{}]}]"))
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
            .codeBlock(lines: ["code"], language: nil),
        ])
    }

    func testParsesInlineContentKinds() {
        XCTAssertEqual(MarkdownParser.parseInline("[x](u)[^1]![a](b.png)<img src=\"c.png\" width=\"9\">`d`"), [
            MarkdownRun(text: "x", link: "u"),
            MarkdownRun(.noteReference("1")),
            MarkdownRun(.image(path: "b.png", alt: "a", width: nil)),
            MarkdownRun(.image(path: "c.png", alt: "", width: 9), rawTag: "<img src=\"c.png\" width=\"9\">"),
            MarkdownRun(text: "d", code: true),
        ])
    }

    func testColorAppliesToEveryInnerRun() {
        XCTAssertEqual(MarkdownParser.parseInline("<span style=\"color: #ABC\">a**b**</span>"), [
            MarkdownRun(text: "a", color: "#AABBCC"),
            MarkdownRun(text: "b", bold: true, color: "#AABBCC"),
        ])
    }

    func testTableCellsKeepTheirFormattingAndSeparator() throws {
        let blocks = MarkdownParser.parse("| *a* | c |\n|:--|--:|\n| **b** |")
        guard case .table(let table)? = blocks.first else { return XCTFail("expected a table") }
        XCTAssertEqual(table.rows, [
            [[MarkdownRun(text: "a", italic: true)], [MarkdownRun(text: "c")]],
            [[MarkdownRun(text: "b", bold: true)], []],
        ])
        XCTAssertEqual(table.headerRow, 0)
        XCTAssertEqual(table.separators, [":--", "--:"])
    }

    func testFenceKeepsItsLanguageAndNeighborsStaySeparate() {
        XCTAssertEqual(MarkdownParser.parse("```swift\nx\n```\n```\ny\n```"), [
            .codeBlock(lines: ["x"], language: "swift"),
            .codeBlock(lines: ["y"], language: nil),
        ])
    }

    func testCellPipesAreEscapedBothWays() throws {
        guard case .table(let table)? = MarkdownParser.parse("| a\\|b |\n|---|").first else { return XCTFail("expected a table") }
        XCTAssertEqual(table.rows, [[[MarkdownRun(text: "a|b")]]])
        XCTAssertEqual(MarkdownWriter.write([.table(table)]), "| a\\|b |\n| --- |\n")
    }

    /// AppKit overwrites a cell's color with the label color and saves that as the author's choice.
    func testColorInATableCellIsKept() {
        let input = "| A |\n|---|\n| <span style=\"color: #FF0000\">x</span> |"
        XCTAssertEqual(MarkdownWriter.write(MarkdownParser.parse(input)),
                       "| A |\n| --- |\n| <span style=\"color: #FF0000\">x</span> |\n")
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
