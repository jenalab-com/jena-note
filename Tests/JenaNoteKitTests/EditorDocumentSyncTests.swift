import AppKit
import XCTest
@testable import JenaNoteKit

/// 스크롤 편집기는 바뀐 범위만 문서로 넘긴다. 어떤 편집 뒤에도 문서는 화면에서 조판을 벗긴 것과 같아야 한다.
final class EditorDocumentSyncTests: XCTestCase {
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

    private func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

    private func open(_ markdown: String, body: (EditorWindowController, MarkdownDocument, EditorTextView) throws -> Void) throws {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse(markdown))
        let controller = EditorWindowController()
        doc.addWindowController(controller)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { doc.updateChangeCount(.changeCleared); window.close(); doc.removeWindowController(controller) }
        controller.applyReadingPageMode(.scroll)
        pump()
        let view = try XCTUnwrap(controller.editorVC.textView)
        window.makeFirstResponder(view)
        try body(controller, doc, view)
    }

    /// 글꼴은 비교하지 않는다. 화면은 한글에 대체 글꼴을 입혀 기울임 같은 정보를 잃기 때문에, 문서가 화면보다
    /// 더 정확하다. 기울임이 살아남는지는 testItalicSurvivesTypingElsewhere 가 따로 본다.
    private func assertInSync(_ doc: MarkdownDocument, _ view: NSTextView, _ note: String = "", line: UInt = #line) {
        let expected = ReaderMetrics.unstyled(view.textStorage ?? NSTextStorage())
        XCTAssertEqual(doc.content.string, expected.string, note, line: line)
        guard doc.content.length == expected.length else { return }
        var index = 0
        while index < expected.length {
            var left = NSRange(), right = NSRange()
            var a = doc.content.attributes(at: index, effectiveRange: &left)
            var b = expected.attributes(at: index, effectiveRange: &right)
            let fontA = a.removeValue(forKey: .font) as? NSFont
            let fontB = b.removeValue(forKey: .font) as? NSFont
            XCTAssertEqual(fontA?.pointSize, fontB?.pointSize, "\(note) @\(index)", line: line)
            XCTAssertTrue((a as NSDictionary).isEqual(to: b), "\(note) @\(index): \(a.keys) vs \(b.keys)", line: line)
            index = min(NSMaxRange(left), NSMaxRange(right))
        }
    }

    private let none = NSRange(location: NSNotFound, length: 0)

    func testTypingAndDeletingStayInSync() throws {
        try open("첫 문단입니다.\n\n둘째 **굵은** 문단.\n") { _, doc, view in
            view.setSelectedRange(NSRange(location: 3, length: 0))
            view.insertText("가", replacementRange: none)
            assertInSync(doc, view)
            view.deleteBackward(nil)
            view.deleteBackward(nil)
            assertInSync(doc, view)
            view.setSelectedRange(NSRange(location: 1, length: 4))
            view.insertText("교체", replacementRange: none)
            assertInSync(doc, view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertText("끝", replacementRange: none)
            view.insertNewline(nil)
            assertInSync(doc, view)
        }
    }

    func testCompositionReachesTheDocumentOnlyWhenCommitted() throws {
        try open("앞뒤\n") { _, doc, view in
            view.setSelectedRange(NSRange(location: 1, length: 0))
            view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            XCTAssertEqual(doc.content.string.prefix(2), "앞뒤", "조합 중인 글자는 아직 문서에 없다")
            view.insertText("한", replacementRange: none)
            XCTAssertEqual(doc.content.string.prefix(3), "앞한뒤")
            assertInSync(doc, view)
        }
    }

    func testUndoAndRedoStayInSync() throws {
        try open("문단\n") { _, doc, view in
            let undo = try XCTUnwrap(view.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            view.setSelectedRange(NSRange(location: 1, length: 0))
            view.insertText("가나다", replacementRange: none)
            undo.endUndoGrouping()
            assertInSync(doc, view)
            undo.undo()
            XCTAssertEqual(doc.content.string.prefix(2), "문단")
            assertInSync(doc, view)
            undo.redo()
            assertInSync(doc, view)
        }
    }

    func testFormattingThenTypingStaysInSync() throws {
        try open("가나다라\n") { controller, doc, view in
            view.setSelectedRange(NSRange(location: 1, length: 2))
            controller.editorVC.toggleBold(nil)
            assertInSync(doc, view)
            view.setSelectedRange(NSRange(location: 4, length: 0))
            view.insertText("마", replacementRange: none)
            assertInSync(doc, view)
            XCTAssertTrue(MarkdownSerializer.serialize(doc.content).contains("**나다**"))
        }
    }

    func testRestyleBetweenEditsDoesNotLoseThem() throws {
        try open("가나다\n") { controller, doc, view in
            view.setSelectedRange(NSRange(location: 1, length: 0))
            view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            controller.editorVC.setReadingLayout(false)
            controller.editorVC.setReadingLayout(true)
            view.insertText("한", replacementRange: none)
            assertInSync(doc, view)
        }
    }

    func testChangingDocumentContentThenTypingStaysInSync() throws {
        try open("처음\n") { controller, doc, view in
            doc.replaceReaderContent(in: NSRange(location: 0, length: 2),
                                     with: MarkdownSerializer.parse("훨씬 긴 교체 문장").attributedSubstring(from: NSRange(location: 0, length: 9)))
            assertInSync(doc, view)
            view.setSelectedRange(NSRange(location: 2, length: 0))
            view.insertText("가", replacementRange: none)
            assertInSync(doc, view)
        }
    }

    func testManyRandomEditsStayInSync() throws {
        let text = (0..<30).map { "\($0)번 문단에 **굵은 글**과 *기울임*이 있습니다.\n\n" }.joined()
        try open(text) { _, doc, view in
            var generator = SystemRandomNumberGenerator()
            for step in 0..<400 {
                let length = (view.string as NSString).length
                let location = Int.random(in: 0...length, using: &generator)
                switch step % 5 {
                case 0:
                    view.setSelectedRange(NSRange(location: location, length: 0))
                    view.insertText("글", replacementRange: none)
                case 1:
                    view.setSelectedRange(NSRange(location: location, length: min(6, length - location)))
                    view.insertText("바꿈", replacementRange: none)
                case 2:
                    view.setSelectedRange(NSRange(location: location, length: 0))
                    view.deleteBackward(nil)
                case 3:
                    view.setSelectedRange(NSRange(location: location, length: 0))
                    view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
                    view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
                    view.insertText("한", replacementRange: none)
                default:
                    view.setSelectedRange(NSRange(location: location, length: 0))
                    view.insertNewline(nil)
                }
                assertInSync(doc, view, "step \(step)")
                if doc.content.string != view.string { return }
            }
        }
    }

    /// 회귀: 글자마다 화면 전체를 문서로 복사하던 때는 글자 하나만 쳐도 한글의 기울임이 전부 사라졌다.
    func testItalicSurvivesTypingElsewhere() throws {
        try open("앞 *기울임* 뒤\n\n**굵은 글** 끝\n") { _, doc, view in
            view.setSelectedRange(NSRange(location: 1, length: 0))
            view.insertText("가", replacementRange: none)
            let saved = MarkdownSerializer.serialize(doc.content)
            XCTAssertTrue(saved.contains("*기울임*"), saved)
            XCTAssertTrue(saved.contains("**굵은 글**"), saved)
        }
    }

    func testCharacterCountFollowsTypingAfterAPause() throws {
        try open("가나\n") { controller, _, view in
            view.setSelectedRange(NSRange(location: 2, length: 0))
            view.insertText("다", replacementRange: none)
            let expected = String(format: L10n.tr("status.charCount"), "3", "3")
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline, controller.statusBar.charCountText != expected { pump() }
            XCTAssertEqual(controller.statusBar.charCountText, expected)
        }
    }
}

