import AppKit
import XCTest
@testable import JenaNoteKit

/// 긴 문서는 문단 단위로 나눠 조판한다. 나눈 경계가 결과에 드러나면 안 된다.
final class ReaderMetricsChunkingTests: XCTestCase {
    private func longDocument() -> NSAttributedString {
        let blocks = (1...1500).map { index -> String in
            switch index % 5 {
            case 0: return "## 제목 \(index)"
            case 1: return "- 목록 **굵게** \(index)"
            case 2: return "> 인용 *기울임* \(index)"
            default: return "문단 \(index). 바다 건너 **등대**가 `깜빡`였다. 바람이 불었다."
            }
        }
        return MarkdownSerializer.parse(blocks.joined(separator: "\n\n"))
    }

    func testChunkedStylingMatchesStylingInOnePass() {
        let source = longDocument()
        XCTAssertGreaterThan(source.length, 20_000, "전제: 여러 묶음으로 나뉜다")

        let chunked = ReaderMetrics.styled(source, scale: 1.2, font: .sans, lineHeightMultiple: 1.4, weight: .regular)
        let whole = ReaderMetrics.styledInOnePass(source, scale: 1.2, font: .sans, lineHeightMultiple: 1.4, weight: .regular)

        XCTAssertTrue(chunked.isEqual(to: whole))
    }

    func testChunkedUnstylingMatchesAndRestoresTheOriginal() {
        let source = longDocument()
        let styled = ReaderMetrics.styled(source, scale: 1.2, font: .sans, lineHeightMultiple: 1.4, weight: .regular)

        let chunked = ReaderMetrics.unstyled(styled)

        XCTAssertTrue(chunked.isEqual(to: ReaderMetrics.unstyledInOnePass(styled)))
        XCTAssertEqual(MarkdownSerializer.serialize(chunked), MarkdownSerializer.serialize(source))
    }

    func testChunkingKeepsEveryCharacterWhenTheDocumentHasNoTrailingNewline() {
        let source = NSAttributedString(string: String(repeating: "가", count: 20_000) + "\n" + String(repeating: "나", count: 9_000))

        XCTAssertEqual(ReaderMetrics.unstyled(source).string, source.string)
    }
}
