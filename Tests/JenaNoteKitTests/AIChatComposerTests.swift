import AppKit
import XCTest
@testable import JenaNoteKit

final class AIChatComposerTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }

    private func key(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                        isARepeat: false, keyCode: 36)!
    }

    func testReturnSubmitsOnceAndShiftReturnInsertsNewline() {
        let input = AIChatInputView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        input.isRichText = false
        input.string = "문장"
        input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        var submissions = 0
        input.onSubmit = { submissions += 1 }
        input.keyDown(with: key())
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(input.string, "문장")
        input.keyDown(with: key(.shift))
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(input.string, "문장\n")
        input.canSubmit = { false }
        input.keyDown(with: key())
        XCTAssertEqual(submissions, 1, "Return while awaiting an answer must not duplicate a request or stop it")
    }

    func testKoreanCompositionConfirmationNeverSubmits() {
        let input = AIChatInputView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        input.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(input.hasMarkedText())
        var submissions = 0
        input.onSubmit = { submissions += 1 }
        input.keyDown(with: key())
        XCTAssertEqual(submissions, 0)
        XCTAssertFalse(AIChatInputView.shouldSubmit(keyCode: 36, modifiers: [], hasMarkedText: true))
        XCTAssertFalse(AIChatInputView.shouldSubmit(keyCode: 36, modifiers: .shift, hasMarkedText: false))
        XCTAssertTrue(AIChatInputView.shouldSubmit(keyCode: 76, modifiers: [], hasMarkedText: false))
    }

    func testComposerContainsAllControlsAndFitsNarrowAndWidePanels() throws {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(string: "본문")
        AIConversationStore.shared.conversation(for: doc).messages = [
            AIChatMessage(role: "user", text: "이 장면의 대화를 조금 더 자연스럽게 다듬어줘."),
            AIChatMessage(role: "assistant", text: "인물의 말투는 유지하면서, 반복되는 설명을 줄이면 대화가 더 자연스럽게 이어져요.")
        ]
        let chat = AIChatViewController()
        chat.currentDocument = { doc }
        chat.switchDocument()
        defer { chat.suspend() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = chat
        defer { window.close() }
        XCTAssertTrue(chat.input.isDescendant(of: chat.composer))
        XCTAssertTrue(chat.modeControl.isDescendant(of: chat.composer))
        XCTAssertTrue(chat.options.modelPicker.isDescendant(of: chat.composer))
        XCTAssertTrue(chat.sendButton.isDescendant(of: chat.composer))
        XCTAssertEqual(chat.sendButton.toolTip, L10n.tr("ai.send"))
        XCTAssertFalse(chat.input.drawsBackground)
        for width in [260.0, 300.0, 600.0] {
            window.setContentSize(NSSize(width: width, height: 650))
            window.layoutIfNeeded()
            let mode = chat.options.convert(chat.modeControl.bounds, from: chat.modeControl)
            let model = chat.options.convert(chat.options.modelPicker.bounds, from: chat.options.modelPicker)
            let action = chat.options.convert(chat.sendButton.bounds, from: chat.sendButton)
            XCTAssertLessThanOrEqual(mode.maxX, model.minX)
            XCTAssertLessThanOrEqual(model.maxX, action.minX)
            XCTAssertEqual(action.maxX, chat.options.bounds.width, accuracy: 1, "Send/stop stays at the trailing edge")
            XCTAssertGreaterThanOrEqual(mode.minX, 0)
        }
        window.setContentSize(NSSize(width: 360, height: 700))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.layoutIfNeeded()
            let bitmap = try XCTUnwrap(chat.view.bitmapImageRepForCachingDisplay(in: chat.view.bounds))
            chat.view.cacheDisplay(in: chat.view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/jena-composer-\(name).png"))
        }
    }
}
