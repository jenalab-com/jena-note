import AppKit
import XCTest
@testable import JenaNoteKit

/// 크래시 2026-10-31 16:49 (EditorViewController.viewDidLayout → ScrollReadingPosition.scroll →
/// NSLayoutManager boundingRect → NSString 범위 예외)의 재현 조건.
final class ScrollReadingPositionTests: XCTestCase {
    private func laidOutTextView(_ text: String) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.string = text
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    func testScrollWaitsWhileStorageIsEditing() throws {
        let textView = laidOutTextView(String(repeating: "문단입니다.\n", count: 200))
        let storage = try XCTUnwrap(textView.textStorage)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 100, length: 1100), with: "")
        // Layout still describes the longer text; touching it here raised NSRangeException.
        XCTAssertFalse(ScrollReadingPosition.scroll(textView: textView, to: 1150))
        storage.endEditing()
        XCTAssertTrue(ScrollReadingPosition.scroll(textView: textView, to: 1150))
    }

    func testScrollClampsOffsetsAndSurrogates() {
        XCTAssertTrue(ScrollReadingPosition.scroll(textView: laidOutTextView("가나다\n라마바 😀"), to: 100))
        XCTAssertTrue(ScrollReadingPosition.scroll(textView: laidOutTextView("😀😀😀"), to: 1))
        XCTAssertTrue(ScrollReadingPosition.scroll(textView: laidOutTextView(""), to: 10))
    }
}
