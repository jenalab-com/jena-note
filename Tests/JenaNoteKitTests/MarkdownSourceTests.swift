import AppKit
import XCTest
@testable import JenaNoteKit

final class MarkdownSourceTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }

    func testSourceShowsCurrentSaveRepresentationWithoutEditingDocument() throws {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("# 제목\n\n**강조**와 `code`"))
        let original = NSAttributedString(attributedString: doc.content)
        let source = MarkdownSourceViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = source
        window.setContentSize(NSSize(width: 760, height: 580))
        defer { window.close() }
        source.show(document: doc)
        window.layoutIfNeeded()
        XCTAssertFalse(source.textView.isEditable)
        XCTAssertTrue(source.textView.isSelectable)
        XCTAssertTrue(source.textView.string.contains("# 제목"))
        XCTAssertTrue(source.textView.string.contains("**강조**"))
        XCTAssertTrue(source.textView.string.contains("`code`"))
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertTrue(doc.content.isEqual(to: original))
        XCTAssertGreaterThan(source.textView.enclosingScrollView!.bounds.width, 300)
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("저장 전 **변경**"))
        source.refresh()
        XCTAssertTrue(source.textView.string.contains("저장 전 **변경**"))
        let plain = MarkdownDocument()
        plain.fileType = "public.plain-text"
        plain.content = NSMutableAttributedString(string: "**그대로인 텍스트**")
        source.setDocument(plain)
        XCTAssertEqual(source.textView.string, "**그대로인 텍스트**")
        source.setDocument(nil)
        XCTAssertEqual(source.textView.string, "", "A closed document must not leave stale source behind")
    }

    func testToolbarSeparatesSourceAndInlineCodeAndRequiresSelection() throws {
        let toolbar = ReaderToolbar(identifier: .init("SourceTestToolbar"))
        let ids = toolbar.toolbarDefaultItemIdentifiers(toolbar).map(\.rawValue)
        XCTAssertEqual(ids.filter { $0 == "markdownSource" }.count, 1)
        XCTAssertEqual(ids.filter { $0 == "inlineCode" }.count, 1)
        let inline = try XCTUnwrap(toolbar.toolbar(toolbar, itemForItemIdentifier: .init("inlineCode"), willBeInsertedIntoToolbar: true))
        let source = try XCTUnwrap(toolbar.toolbar(toolbar, itemForItemIdentifier: .init("markdownSource"), willBeInsertedIntoToolbar: true))
        let inlineButton = try XCTUnwrap(inline.view as? NSButton)
        let sourceButton = try XCTUnwrap(source.view as? NSButton)
        XCTAssertEqual(inlineButton.title, L10n.tr("toolbar.inlineCode"))
        XCTAssertEqual(sourceButton.title, L10n.tr("source.title"))
        XCTAssertNotEqual(inlineButton.action, sourceButton.action)
        XCTAssertFalse(inlineButton.isEnabled)
        toolbar.updateSelection(hasSelectedText: true)
        XCTAssertTrue(inlineButton.isEnabled)
        toolbar.updateSelection(hasSelectedText: false)
        XCTAssertFalse(inlineButton.isEnabled)
        XCTAssertTrue(sourceButton.isEnabled)
    }

    func testCodeFormattingRemainsMonospacedAfterDisplayStylingAndRoundTrip() throws {
        let original = MarkdownSerializer.parse("본문 `inline`\n\n```swift\nlet x = 1\n```")
        let styled = ReaderMetrics.styled(original, scale: 1.5, font: .serif,
                                          lineHeightMultiple: 1.5, weight: .bold)
        for word in ["inline", "let x"] {
            let index = (styled.string as NSString).range(of: word).location
            let font = try XCTUnwrap(styled.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace), "Display font must not obscure code formatting")
        }
        XCTAssertEqual(MarkdownSerializer.serialize(ReaderMetrics.unstyled(styled)), MarkdownSerializer.serialize(original))
    }

    func testSourceFollowsUnifiedEditsUndoAndClosesWithDocumentWindow() throws {
        let previous = SettingsManager.shared.readingPageMode
        defer { SettingsManager.shared.readingPageMode = previous }
        SettingsManager.shared.readingPageMode = .scroll
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("본문"))
        let host = EditorWindowController()
        doc.addWindowController(host)
        let window = try XCTUnwrap(host.window)
        window.isReleasedWhenClosed = false
        defer { window.close(); doc.removeWindowController(host) }
        window.makeKeyAndOrderFront(nil)
        host.showMarkdownSource(nil)
        let source = try XCTUnwrap(host.sourcePreview)
        doc.replaceReaderContent(in: NSRange(location: 0, length: doc.content.length), with: MarkdownSerializer.parse("`본문`"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(source.textView.string.contains("`본문`"))
        doc.undoManager?.undo()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(source.textView.string.contains("`본문`"))
        window.close()
        XCTAssertFalse(window.isVisible)
    }
    func testSourceReplacesTheDocumentPaneAndRestoresBothLayouts() throws {
        let previous = SettingsManager.shared.readingPageMode
        defer { SettingsManager.shared.readingPageMode = previous }
        for mode in [SettingsManager.ReadingPageMode.scroll, .paged] {
            SettingsManager.shared.readingPageMode = mode
            let doc = MarkdownDocument()
            doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("첫 문단\n둘째 문단"))
            let original = NSAttributedString(attributedString: doc.content)
            let host = EditorWindowController()
            doc.addWindowController(host)
            let window = try XCTUnwrap(host.window)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1200, height: 760))
            window.makeKeyAndOrderFront(nil)
            window.layoutIfNeeded()
            host.selectDocumentRange(NSRange(location: 0, length: 2))
            let reader = host.readerVC
            host.showMarkdownSource(nil)
            let source = try XCTUnwrap(host.sourcePreview)
            XCTAssertTrue(host.isShowingSource)
            XCTAssertTrue(source.view.window === window, "Source belongs in the same document window")
            window.layoutIfNeeded()
            XCTAssertGreaterThan(source.textView.enclosingScrollView!.bounds.width, 300)
            XCTAssertFalse(source.textView.isEditable)
            XCTAssertNil(reader?.view.window)
            host.editorVC.toggleBold(nil)
            XCTAssertTrue(doc.content.isEqual(to: original), "Formatting cannot mutate a hidden editor while viewing source")
            host.showMarkdownSource(nil)
            XCTAssertFalse(host.isShowingSource)
            XCTAssertNil(source.view.window)
            XCTAssertTrue(host.readerVC === reader)
            XCTAssertEqual(host.documentSelection, NSRange(location: 0, length: 2))
            XCTAssertEqual(SettingsManager.shared.readingPageMode, mode)
            XCTAssertFalse(doc.isDocumentEdited)
            window.close()
            doc.removeWindowController(host)
        }
    }

    func testSourceTracksDocumentSwitchAndAIUsesDocumentCoordinates() throws {
        let previous = SettingsManager.shared.readingPageMode
        defer { SettingsManager.shared.readingPageMode = previous }
        SettingsManager.shared.readingPageMode = .paged
        let first = MarkdownDocument()
        first.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("이전 문서"))
        let next = MarkdownDocument()
        next.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("# 새 문서"))
        let host = EditorWindowController()
        first.addWindowController(host)
        let window = try XCTUnwrap(host.window)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); next.removeWindowController(host) }
        host.showMarkdownSource(nil)
        first.removeWindowController(host)
        next.addWindowController(host)
        XCTAssertTrue(host.isShowingSource)
        XCTAssertTrue(host.sourcePreview!.view.window === window)
        XCTAssertTrue(host.sourcePreview!.textView.string.contains("# 새 문서"))
        host.toggleAI(nil)
        XCTAssertFalse(host.isShowingSource)
        XCTAssertTrue(host.isAIActive)
        XCTAssertNotNil(host.editorVC.view.window)
        host.showMarkdownSource(nil)
        host.sourcePreview!.textView.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertEqual(host.aiChatVC!.currentSelection?(), NSRange(location: 0, length: 0), "Markdown offsets must never become WYSIWYG edit offsets")
        host.toggleAI(nil)
        XCTAssertFalse(host.isShowingSource)
        XCTAssertFalse(host.isAIActive)
        XCTAssertNotNil(host.readerVC)
    }

}
