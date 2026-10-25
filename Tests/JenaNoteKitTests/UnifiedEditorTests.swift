import AppKit
import XCTest
@testable import JenaNoteKit

final class UnifiedEditorTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private let keys = ["jn_readingPageMode", "jn_readingFontScale", "jn_readingFont", "jn_readingWeight", "jn_readingLineSpacing"]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        SettingsManager.shared.readingPageMode = .paged
        SettingsManager.shared.readingWeight = .bold
        SettingsManager.shared.readingFontScale = 1.4
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func makeWindow(_ text: String) -> (MarkdownDocument, EditorWindowController, NSWindow) {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse(text))
        let controller = EditorWindowController()
        doc.addWindowController(controller)
        let window = controller.window!
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        controller.readerVC?.view.layoutSubtreeIfNeeded()
        return (doc, controller, window)
    }

    private func close(_ doc: MarkdownDocument, _ controller: EditorWindowController, _ window: NSWindow) {
        doc.updateChangeCount(.changeCleared)
        window.close()
        doc.removeWindowController(controller)
    }

    func testDocumentStartsEditableWithOneToolbarAndNoModeSwitches() throws {
        let (doc, controller, window) = makeWindow("본문")
        defer { close(doc, controller, window) }
        XCTAssertNotNil(controller.readerVC, "The saved page layout must be active without entering a separate mode")
        XCTAssertTrue(controller.readerVC!.visiblePageTextViews.first?.isEditable == true)
        XCTAssertTrue(controller.editorVC.isReadingLayout)
        XCTAssertFalse(doc.isDocumentEdited)
        let toolbar = try XCTUnwrap(window.toolbar as? ReaderToolbar)
        let ids = toolbar.toolbarDefaultItemIdentifiers(toolbar).map(\.rawValue)
        XCTAssertFalse(ids.contains("readingMode"))
        XCTAssertFalse(ids.contains("readerExit"))
        XCTAssertEqual(ids.filter { $0 == "aiChat" }.count, 1)
        XCTAssertTrue(ids.contains("bold") && ids.contains("heading") && ids.contains("insert"))
        XCTAssertFalse(ids.contains("lineSpacing"), "Duplicate spacing controls are merged into Appearance")
        let bold = try XCTUnwrap(toolbar.toolbar(toolbar, itemForItemIdentifier: .init("bold"), willBeInsertedIntoToolbar: true)?.view as? NSButton)
        XCTAssertTrue(bold.target === controller.editorVC)
        controller.editorVC.updateToolbarState()
        XCTAssertEqual(bold.state, .off, "Display weight must not activate the author-bold button")
    }

    func testPagedFormattingUsesOriginalTraitsAndSurvivesUndoAndLayoutChanges() throws {
        let (doc, controller, window) = makeWindow("첫 문단\n둘째 문단")
        defer { close(doc, controller, window) }
        let original = NSAttributedString(attributedString: doc.content)
        let reader = try XCTUnwrap(controller.readerVC)
        controller.selectDocumentRange(NSRange(location: 0, length: 2))
        controller.editorVC.toggleBold(nil)
        XCTAssertTrue(controller.readerVC === reader, "Formatting must not switch the page layout to scroll")
        let font = try XCTUnwrap(doc.content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "Display bold must not cause the first author-bold command to turn bold off")
        XCTAssertEqual(font.pointSize, MemoFont.body.pointSize)
        XCTAssertNil(doc.content.attribute(.mdBaseFont, at: 0, effectiveRange: nil))
        XCTAssertEqual(controller.documentSelection, NSRange(location: 0, length: 2))
        let saved = String(data: try doc.data(ofType: "net.daringfireball.markdown"), encoding: .utf8)!
        XCTAssertTrue(saved.contains("**첫 **"))
        controller.applyReadingPageMode(.scroll)
        XCTAssertNil(controller.readerVC)
        doc.undoManager?.undo()
        XCTAssertTrue(doc.content.isEqual(to: original))
        doc.undoManager?.redo()
        controller.applyReadingPageMode(.paged)
        XCTAssertTrue(controller.readerVC!.contentString == doc.content.string)
        controller.selectDocumentRange(NSRange(location: 0, length: 2))
        controller.editorVC.toggleBold(nil)
        XCTAssertTrue(doc.content.isEqual(to: original))
    }

    func testParagraphCommandsAndShortcutReachPagedDocument() throws {
        let (doc, controller, window) = makeWindow("첫 문단\n둘째 문단")
        defer { close(doc, controller, window) }
        controller.selectDocumentRange(NSRange(location: 0, length: 2))
        let reader = try XCTUnwrap(controller.readerVC)
        XCTAssertTrue(reader.tryToPerform(#selector(EditorViewController.setHeading1), with: nil))
        XCTAssertEqual(doc.content.attribute(.mdBlockType, at: 0, effectiveRange: nil) as? String, "h1")
        XCTAssertEqual(doc.content.attribute(.mdBlockType, at: 5, effectiveRange: nil) as? String, "body")
        controller.editorVC.setBodyText(nil)
        controller.editorVC.toggleUnorderedList(nil)
        XCTAssertTrue(doc.content.string.hasPrefix("•\t첫 문단"))
        XCTAssertTrue(controller.readerVC === reader)
        controller.editorVC.toggleUnorderedList(nil)
        XCTAssertFalse(doc.content.string.hasPrefix("•"))
    }

    func testFileSwitchAndSearchUseUnifiedVisibleDocument() throws {
        let (doc, controller, window) = makeWindow("이전 문서")
        defer { close(doc, controller, window) }
        let next = MarkdownDocument()
        next.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("새 문서의 검색 단어"))
        doc.removeWindowController(controller)
        next.addWindowController(controller)
        defer { next.removeWindowController(controller) }
        XCTAssertEqual(controller.readerVC?.contentString, next.content.string)
        controller.selectDocumentRange(NSRange(location: 6, length: 2))
        controller.editorVC.toggleItalic(nil)
        XCTAssertEqual(doc.content.string, "이전 문서\n")
        let font = next.content.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        controller.toggleAI(nil)
        XCTAssertEqual(controller.editorVC.textView.string, next.content.string)
        XCTAssertEqual(controller.documentSelection, NSRange(location: 6, length: 2))
        controller.toggleAI(nil)
        XCTAssertNotNil(controller.readerVC)
    }
}
