import AppKit
import XCTest
import JenaNoteCoreTestSupport
@testable import JenaNoteKit

/// Compares the AppKit serializer the app uses today with the shared library, on the same
/// inputs. All of this must pass before parse and serialize switch to the shared library.
final class MarkdownCoreParityTests: XCTestCase {

    /// The expected text in the corpus was written from reading the code, so check it first.
    func testCorpusDescribesTheCurrentSerializer() {
        for item in MarkdownCorpus.cases {
            XCTAssertEqual(MarkdownSerializer.serialize(MarkdownSerializer.parse(item.input)), item.expected, item.name)
        }
    }

    func testSharedParserAndWriterMatchTheCurrentSerializer() {
        for item in MarkdownCorpus.cases {
            let current = MarkdownSerializer.serialize(MarkdownSerializer.parse(item.input))
            XCTAssertEqual(MarkdownWriter.write(MarkdownParser.parse(item.input)), current, item.name)
        }
    }

    func testSavingAgainMatchesTheCurrentSerializer() {
        for item in MarkdownCorpus.cases {
            let current = MarkdownSerializer.serialize(MarkdownSerializer.parse(item.expected))
            XCTAssertEqual(MarkdownWriter.write(MarkdownParser.parse(item.expected)), current, item.name)
        }
    }

    func testReadingAttributedTextMatchesTheCurrentSerializer() {
        for item in MarkdownCorpus.cases {
            let attributed = MarkdownSerializer.parse(item.input)
            XCTAssertEqual(MarkdownSerializer.coreSerialize(attributed), MarkdownSerializer.serialize(attributed), item.name)
        }
    }

    func testRenderingProducesTheSameTextAndSaves() {
        for item in MarkdownCorpus.cases {
            let current = MarkdownSerializer.parse(item.input)
            let rendered = MarkdownSerializer.coreParse(item.input)
            XCTAssertEqual(rendered.string, current.string, item.name)
            XCTAssertEqual(MarkdownSerializer.serialize(rendered), MarkdownSerializer.serialize(current), item.name)
            XCTAssertEqual(MarkdownSerializer.coreSerialize(rendered), MarkdownSerializer.serialize(current), item.name)
        }
    }

    /// Text typed or edited in the app does not come from the parser and may lack block types.
    func testAttributedTextThatDidNotComeFromTheParser() {
        let plain = NSAttributedString(string: "그냥 글\n둘째 줄")
        XCTAssertEqual(MarkdownSerializer.coreSerialize(plain), MarkdownSerializer.serialize(plain))

        let edited = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("# 제목\n본문"))
        edited.addAttribute(.font, value: MemoFont.bold(from: MemoFont.body), range: NSRange(location: 3, length: 2))
        XCTAssertEqual(MarkdownSerializer.coreSerialize(edited), MarkdownSerializer.serialize(edited))
    }

    /// The one intended difference: AppKit overwrites a cell's color with the label color and
    /// saves that as if the author had chosen it. The shared path keeps the chosen color.
    func testColorInTableCellSurvivesTheSharedPath() {
        let input = "| A |\n|---|\n| <span style=\"color: #FF0000\">x</span> |"
        let expected = "| **A** |\n| --- |\n| <span style=\"color: #FF0000\">x</span> |\n"
        XCTAssertEqual(MarkdownSerializer.coreSerialize(MarkdownSerializer.coreParse(input)), expected)
    }
}
