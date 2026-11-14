import AppKit
import XCTest
@testable import JenaNoteKit

/// 실제 문서 창에서 스크롤·페이지 두 입력 뷰와 헤더·메뉴가 같은 상태를 보는지 확인한다.
final class PunctuationWindowTests: XCTestCase {
    private let keys = ["jn_readingPageMode", "jn_punctuationTriggersEnabled", "jn_punctuationClosesOnReturn"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func open(_ markdown: String, mode: SettingsManager.ReadingPageMode,
                      body: (EditorWindowController, MarkdownDocument, NSWindow) throws -> Void) throws {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse(markdown))
        let controller = EditorWindowController()
        doc.addWindowController(controller)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { doc.updateChangeCount(.changeCleared); window.close(); doc.removeWindowController(controller) }
        controller.applyReadingPageMode(mode)
        pump()
        try body(controller, doc, window)
    }

    private func punctuationControl(_ window: NSWindow) throws -> NSSegmentedControl {
        let item = window.toolbar?.items.first { $0.itemIdentifier.rawValue == "punctuation" }
        return try XCTUnwrap(item?.control as? NSSegmentedControl)
    }

    private func type(_ text: String, in view: NSTextView) {
        for character in text {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    func testScrollModeReachesTheDocumentAndHeader() throws {
        try open("앞\n", mode: .scroll) { controller, doc, window in
            let view = try XCTUnwrap(controller.editorVC.textView)
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            let control = try punctuationControl(window)

            controller.toggleDialogueMark(nil)
            XCTAssertEqual(doc.content.string.prefix(2), "앞\"")
            XCTAssertTrue(control.isSelected(forSegment: 0))
            type("네", in: view)
            controller.toggleDialogueMark(nil)
            XCTAssertEqual(doc.content.string.prefix(4), "앞\"네\"")
            XCTAssertFalse(control.isSelected(forSegment: 0))
        }
    }

    func testPagedModeReachesTheDocumentAndSequenceWorks() throws {
        SettingsManager.shared.punctuationTriggersEnabled = true
        try open("앞\n", mode: .paged) { controller, doc, window in
            let reader = try XCTUnwrap(controller.readerVC)
            let view = try XCTUnwrap(reader.inputTextView)
            XCTAssertTrue(view.punctuation === controller.punctuationController)
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 1, length: 0))

            controller.toggleQuotationMark(nil)
            type("네", in: view)
            pump()
            controller.toggleQuotationMark(nil)
            type(";;;", in: view)
            pump()
            XCTAssertEqual(doc.content.string.prefix(5), "앞'네'\"")
            XCTAssertTrue(controller.punctuationController.isActive(.dialogue))
            XCTAssertFalse(controller.punctuationController.isActive(.quotation))
        }
    }

    func testPagedReturnClosesWhenEnabled() throws {
        SettingsManager.shared.punctuationClosesOnReturn = true
        try open("앞\n", mode: .paged) { controller, doc, window in
            let view = try XCTUnwrap(controller.readerVC?.inputTextView)
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            controller.toggleDialogueMark(nil)
            type("네", in: view)
            view.insertNewline(nil)
            pump()
            XCTAssertEqual(doc.content.string.prefix(5), "앞\"네\"\n")
            XCTAssertTrue(controller.punctuationController.active.isEmpty)
        }
    }

    func testPagedUndoRemovesTheMark() throws {
        try open("앞\n", mode: .paged) { controller, doc, window in
            let view = try XCTUnwrap(controller.readerVC?.inputTextView)
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            let undo = try XCTUnwrap(doc.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            controller.toggleDialogueMark(nil)
            undo.endUndoGrouping()
            XCTAssertEqual(doc.content.string.prefix(2), "앞\"")
            undo.undo()
            pump()
            XCTAssertEqual(doc.content.string.prefix(2), "앞\n")
        }
    }

    func testHeaderClickTogglesWithoutTouchingOtherMarks() throws {
        try open("앞\n", mode: .scroll) { controller, doc, window in
            let view = try XCTUnwrap(controller.editorVC.textView)
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            let control = try punctuationControl(window)
            control.setSelected(true, forSegment: 2)
            controller.punctuationSegmentChanged(control)
            XCTAssertEqual(controller.punctuationController.active, [.thought])
            control.setSelected(true, forSegment: 0)
            controller.punctuationSegmentChanged(control)
            XCTAssertEqual(controller.punctuationController.active, [.thought, .dialogue])
            control.setSelected(false, forSegment: 2)
            controller.punctuationSegmentChanged(control)
            XCTAssertEqual(controller.punctuationController.active, [.dialogue])
            XCTAssertTrue(control.isSelected(forSegment: 0))
            XCTAssertFalse(control.isSelected(forSegment: 2))
        }
    }

    func testMenuReflectsStateAndSourceViewDisablesIt() throws {
        try open("앞\n", mode: .scroll) { controller, _, window in
            window.makeFirstResponder(controller.editorVC.textView)
            let item = NSMenuItem(title: "", action: #selector(EditorWindowController.toggleDialogueMark(_:)), keyEquivalent: "1")
            XCTAssertTrue(controller.validateMenuItem(item))
            XCTAssertEqual(item.state, .off)
            controller.toggleDialogueMark(nil)
            _ = controller.validateMenuItem(item)
            XCTAssertEqual(item.state, .on)

            controller.showMarkdownSource(nil)
            XCTAssertFalse(controller.validateMenuItem(item))
            XCTAssertTrue(controller.punctuationController.active.isEmpty, "원문 보기로 가면 이어 쓸 자리가 사라진다")
            let before = controller.editorVC.textView.string
            controller.toggleDialogueMark(nil)
            XCTAssertEqual(controller.editorVC.textView.string, before)
            controller.showMarkdownSource(nil)
        }
    }

    func testShortcutDoesNotStealInputFromAnotherTextField() throws {
        try open("앞\n", mode: .scroll) { controller, doc, window in
            let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
            window.contentView?.addSubview(other)
            window.makeFirstResponder(other)
            let before = doc.content.string
            let menu = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            controller.toggleDialogueMark(menu)
            XCTAssertEqual(doc.content.string, before)
            XCTAssertTrue(controller.punctuationController.active.isEmpty)
        }
    }

    func testMenuHasShortcuts() throws {
        let delegate = AppDelegate()
        delegate.rebuildMenu()
        let format = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.items.contains { $0.action == #selector(EditorWindowController.toggleDialogueMark(_:)) } }
        let keys = format?.items.filter { [#selector(EditorWindowController.toggleDialogueMark(_:)), #selector(EditorWindowController.toggleQuotationMark(_:)), #selector(EditorWindowController.toggleThoughtMark(_:))].contains($0.action) }.map(\.keyEquivalent)
        XCTAssertEqual(keys, ["1", "2", "3"])
    }

    /// 화면 확인용 캡처. 창 ID로만 찍어 다른 창이 끼어들지 않는다.
    func testCaptureScreens() throws {
        guard ProcessInfo.processInfo.environment["JN_CAPTURE"] != nil else { throw XCTSkip("캡처 시에만") }
        func shot(_ window: NSWindow, _ name: String) {
            window.orderFrontRegardless()
            pump(0.6)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-o", "-x", "-l", "\(window.windowNumber)", "/tmp/\(name).png"]
            try? task.run(); task.waitUntilExit()
        }
        try open("앞 문장입니다.\n", mode: .scroll) { controller, _, window in
            window.setContentSize(NSSize(width: 1280, height: 420))
            window.makeFirstResponder(controller.editorVC.textView)
            controller.toggleDialogueMark(nil)
            shot(window, "punct-header")
        }
        let tabs = NSTabViewController()
        tabs.tabStyle = .segmentedControlOnTop
        let item = NSTabViewItem(viewController: PunctuationSettingsViewController())
        item.label = L10n.tr("settings.tab.punctuation")
        tabs.addTabViewItem(item)
        let settings = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 620, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.contentViewController = tabs
        settings.setContentSize(NSSize(width: 620, height: 500))
        settings.makeKeyAndOrderFront(nil)
        shot(settings, "punct-settings")
        settings.close()
    }
}
