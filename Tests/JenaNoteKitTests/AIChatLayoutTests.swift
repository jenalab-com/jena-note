import AppKit
import XCTest
@testable import JenaNoteKit

final class AIChatLayoutTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }

    func testUserBubbleIsOnRightAndAIHasNoBoxOnLeft() throws {
        let transcript = AIChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        transcript.setMessages([
            .init(role: "user", text: "선택한 글을 다듬어줘."),
            .init(role: "assistant", text: "원문의 뜻을 유지하면서 문장을 다듬었습니다."),
            .init(role: "status", text: "수정 완료")
        ])
        transcript.layout()
        let user = transcript.messageViews[0], assistant = transcript.messageViews[1]
        XCTAssertTrue(user.hasBubble)
        XCTAssertGreaterThan(user.bubbleFrame.minX, 0)
        XCTAssertEqual(user.bubbleFrame.maxX, user.bounds.width, accuracy: 1)
        XCTAssertFalse(assistant.hasBubble)
        XCTAssertEqual(assistant.textView.frame.minX, 0, accuracy: 1)
        XCTAssertFalse(transcript.messageViews[2].hasBubble)
        XCTAssertTrue(user.textView.isSelectable, "Bubble text must remain copyable")
        XCTAssertFalse(user.textView.isEditable)
    }

    func testLongMessagesReflowWhenPanelWidthChangesWithoutLosingText() {
        let transcript = AIChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        let text = String(repeating: "한글과 English 👩🏽‍💻를 포함한 긴 문장입니다. ", count: 20)
        transcript.setMessages([.init(role: "user", text: text), .init(role: "assistant", text: text)])
        transcript.layout()
        let user = transcript.messageViews[0]
        let narrowHeight = user.frame.height
        transcript.setFrameSize(NSSize(width: 580, height: 400))
        transcript.layout()
        XCTAssertLessThan(user.frame.height, narrowHeight, "Wider panels should wrap to fewer lines")
        XCTAssertEqual(user.textView.string, text)
        XCTAssertLessThanOrEqual(user.bubbleFrame.width, user.bounds.width * 0.86 + 1)
        XCTAssertLessThanOrEqual(transcript.documentView!.frame.width, transcript.contentSize.width + 1,
                                 "A long message must not impose a horizontal minimum on the split view")
        XCTAssertGreaterThan(transcript.messageViews[1].frame.minY, user.frame.maxY)
    }

    func testSplitDividerAllowsResizeUpToDoubleInitialWidthAndRestoresWidth() throws {
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("본문"))
        let controller = EditorWindowController()
        document.addWindowController(controller)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.close(); document.removeWindowController(controller) }
        window.setContentSize(NSSize(width: 1600, height: 760))
        controller.editorVC.loadContent(of: document)
        controller.toggleAI(nil)
        window.layoutIfNeeded()
        let chat = try XCTUnwrap(controller.aiChatVC)
        let split = try XCTUnwrap(chat.parent as? NSSplitViewController)
        let item = try XCTUnwrap(split.splitViewItems.last)
        let initial = chat.view.bounds.width
        XCTAssertEqual(initial, AIChatViewController.defaultPanelWidth, accuracy: 2)
        XCTAssertEqual(item.maximumThickness, initial * 2, accuracy: 4)
        split.splitView.setPosition(split.splitView.bounds.width - 450 - split.splitView.dividerThickness, ofDividerAt: 1)
        window.layoutIfNeeded()
        XCTAssertEqual(chat.view.bounds.width, 450, accuracy: 2, "Dragging the divider must actually change the pane width")
        split.splitView.setPosition(split.splitView.bounds.width - 900 - split.splitView.dividerThickness, ofDividerAt: 1)
        window.layoutIfNeeded()
        XCTAssertLessThanOrEqual(chat.view.bounds.width, AIChatViewController.maximumPanelWidth + 2)
        let width = chat.view.bounds.width
        controller.toggleAI(nil)
        controller.toggleAI(nil)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.aiChatVC!.view.bounds.width, width, accuracy: 2)
    }
}
