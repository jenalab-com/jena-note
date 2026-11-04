import AppKit
import XCTest
@testable import JenaNoteKit

/// 편집기에만 있는 마크된 텍스트(한글 조합, macOS 인라인 자동완성 예측) 때문에 편집기 선택이
/// 문서 내용보다 뒤에 있어도 툴바 상태 갱신이 범위를 넘어 읽지 않아야 한다.
///
/// 회귀 배경: `updateToolbarState` 는 선택은 편집기에서, 속성은 문서 내용에서 읽는다. 마크된 텍스트는
/// 확정 전까지 문서에 넘어가지 않으므로 문서 끝에서 예측이 붙으면 `sel.location - 1` 이 문서 길이를
/// 넘는다. 예외가 텍스트 스토리지 편집 도중에 삼켜져 레이아웃이 어긋났고, 다음 그리기에서 앱이 죽었다.
final class ToolbarStateMarkedTextTests: XCTestCase {
    private var savedMode: Any?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedMode = UserDefaults.standard.object(forKey: "jn_readingPageMode")
    }

    override func tearDown() {
        if let savedMode { UserDefaults.standard.set(savedMode, forKey: "jn_readingPageMode") }
        else { UserDefaults.standard.removeObject(forKey: "jn_readingPageMode") }
        super.tearDown()
    }

    func testMarkedTextPastDocumentEndDoesNotReadOutOfBounds() throws {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("- first item"))
        let controller = EditorWindowController()
        doc.addWindowController(controller)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { doc.updateChangeCount(.changeCleared); window.close(); doc.removeWindowController(controller) }
        controller.applyReadingPageMode(.scroll)
        let tv = try XCTUnwrap(controller.editorVC.textView)
        window.makeFirstResponder(tv)
        let end = (tv.string as NSString).range(of: "first item")
        tv.setSelectedRange(NSRange(location: NSMaxRange(end), length: 0))

        // 인라인 예측처럼 문서 끝 쪽에 마크된 텍스트를 붙인다 — 문서 내용에는 아직 없다.
        let prediction = " and the rest of a long predicted phrase"
        tv.setMarkedText(prediction, selectedRange: NSRange(location: prediction.utf16.count, length: 0),
                         replacementRange: tv.selectedRange())
        XCTAssertGreaterThan(NSMaxRange(tv.selectedRange()), doc.content.length, "전제: 선택이 문서 끝을 넘어야 한다")

        controller.editorVC.updateToolbarState()   // 수정 전에는 NSRangeException
        tv.unmarkText()
    }
}
