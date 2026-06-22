import XCTest
import AppKit
@testable import JenaNoteKit

final class ReaderMetricsTests: XCTestCase {

    func testScaledDoublesFontSize() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let original = NSAttributedString(string: "한글", attributes: attrs)
        let scaled = ReaderMetrics.scaled(original, by: 2.0)
        let f = scaled.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(f.pointSize, 30, accuracy: 0.01)
    }

    func testScaledKeepsRelativeRatios() {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "본", attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        s.append(NSAttributedString(string: "큰", attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold)]))
        let scaled = ReaderMetrics.scaled(s, by: 1.5)
        let body = scaled.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let head = scaled.attribute(.font, at: 1, effectiveRange: nil) as! NSFont
        XCTAssertEqual(body.pointSize, 22.5, accuracy: 0.01)
        XCTAssertEqual(head.pointSize, 42.0, accuracy: 0.01)
    }

    func testScaledLeavesOriginalUnchanged() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let original = NSAttributedString(string: "한글", attributes: attrs)
        _ = ReaderMetrics.scaled(original, by: 2.0)
        let f = original.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(f.pointSize, 15, accuracy: 0.01)
    }

    func testSnappedPageHeightFloorsToLineMultiple() {
        // floor(100/30)=3 → 90
        XCTAssertEqual(ReaderMetrics.snappedPageHeight(viewHeight: 100, lineHeight: 30), 90, accuracy: 0.01)
    }

    func testSnappedPageHeightAtLeastOneLine() {
        // 한 줄도 안 들어가는 높이라도 최소 한 줄
        XCTAssertEqual(ReaderMetrics.snappedPageHeight(viewHeight: 10, lineHeight: 30), 30, accuracy: 0.01)
    }

    func testSnappedPageHeightZeroLineHeightReturnsZero() {
        XCTAssertEqual(ReaderMetrics.snappedPageHeight(viewHeight: 100, lineHeight: 0), 0, accuracy: 0.01)
    }

    func testColumnWidth() {
        XCTAssertEqual(ReaderMetrics.columnWidth(charCount: 35, glyphAdvance: 15), 525, accuracy: 0.01)
    }

    func testMobileColumnWidthIsFixed() {
        XCTAssertEqual(ReaderMetrics.mobileColumnWidth, 360, accuracy: 0.01)
    }

    func testMobileColumnWidthNarrowerThanDefaultBookColumn() {
        // 모바일 고정 폭은 기본 책 폭(한글 35자 × advance)보다 좁아야 한다.
        let bookWidth = ReaderMetrics.columnWidth(charCount: 35, glyphAdvance: 15)
        XCTAssertLessThan(ReaderMetrics.mobileColumnWidth, bookWidth)
    }
}
