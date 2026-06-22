import XCTest
@testable import JenaNoteKit

final class TextMetricsTests: XCTestCase {

    func testEmptyString() {
        let c = TextMetrics.counts(for: "")
        XCTAssertEqual(c.noSpaces, 0)
        XCTAssertEqual(c.withSpaces, 0)
    }

    func testKoreanWithSpace() {
        // "안녕 하루" → 공백 제외 4, 공백 포함 5
        let c = TextMetrics.counts(for: "안녕 하루")
        XCTAssertEqual(c.noSpaces, 4)
        XCTAssertEqual(c.withSpaces, 5)
    }

    func testNewlineExcludedFromBoth() {
        // 개행은 양쪽 모두에서 제외
        let c = TextMetrics.counts(for: "가\n나")
        XCTAssertEqual(c.noSpaces, 2)
        XCTAssertEqual(c.withSpaces, 2)
    }

    func testImageAttachmentExcludedFromBoth() {
        // 이미지 첨부(object replacement char)는 양쪽 모두에서 제외
        let c = TextMetrics.counts(for: "가\u{FFFC}나")
        XCTAssertEqual(c.noSpaces, 2)
        XCTAssertEqual(c.withSpaces, 2)
    }

    func testTabsAndRepeatedSpacesOnlyCountInWithSpaces() {
        // 탭·연속 공백은 공백 포함에만 잡히고, 공백 제외에는 안 잡힌다
        let c = TextMetrics.counts(for: "가\t  나")
        XCTAssertEqual(c.noSpaces, 2)
        XCTAssertEqual(c.withSpaces, 5)  // 가, \t, ' ', ' ', 나
    }

    func testGraphemeClusterCountedAsOne() {
        // 결합 문자(grapheme cluster)는 한 글자로 센다
        let c = TextMetrics.counts(for: "👨‍👩‍👧")
        XCTAssertEqual(c.noSpaces, 1)
        XCTAssertEqual(c.withSpaces, 1)
    }
}
