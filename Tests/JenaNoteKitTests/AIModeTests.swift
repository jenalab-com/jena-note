import AppKit
import XCTest
@testable import JenaNoteKit

final class AIModeTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }

    func testConversationsFollowFilesAndSeparateUnsavedNotes() {
        let store = AIConversationStore()
        let a = MarkdownDocument(), b = MarkdownDocument()
        let first = store.conversation(for: a)
        first.messages.append(.init(role: "user", text: "Keep this conversation"))
        XCTAssertFalse(first === store.conversation(for: b))
        a.fileURL = URL(fileURLWithPath: "/tmp/\(UUID()).md")
        XCTAssertTrue(first === store.conversation(for: a), "Save As must preserve an unsaved note's conversation")
        let reopened = MarkdownDocument()
        reopened.fileURL = a.fileURL
        XCTAssertTrue(first === store.conversation(for: reopened), "Sidebar reopen should restore the file's conversation")
    }

    func testSnapshotRejectsAnotherDocumentAndTextOrStyleChanges() {
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("A 문장 👩🏽‍💻 B"))
        let snapshot = AIEditSnapshot(document: document, selection: NSRange(location: 2, length: 2))
        XCTAssertTrue(snapshot.canApply(to: document))
        let other = MarkdownDocument()
        other.content = NSMutableAttributedString(attributedString: document.content)
        XCTAssertFalse(snapshot.canApply(to: other))
        document.content.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
        XCTAssertFalse(snapshot.canApply(to: document), "Formatting edits while waiting must not be overwritten")
        document.content = NSMutableAttributedString(attributedString: snapshot.content)
        document.content.append(NSAttributedString(string: "!"))
        XCTAssertFalse(snapshot.canApply(to: document))
    }

    func testSelectedUnicodeEditPreservesOutsideFormattingAndUndo() throws {
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("**보존** 👩🏽‍💻 원문 끝"))
        let original = NSAttributedString(attributedString: document.content)
        let selection = (original.string as NSString).range(of: "👩🏽‍💻 원문")
        let snapshot = AIEditSnapshot(document: document, selection: selection)
        let (range, replacement) = try snapshot.replacement("👩🏽‍💻 수정문")
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        document.replaceReaderContent(in: range, with: replacement)
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.content.string, "보존 👩🏽‍💻 수정문 끝\n")
        XCTAssertTrue(MarkdownSerializer.serialize(document.content).contains("**보존**"))
        document.undoManager?.undo()
        XCTAssertTrue(document.content.isEqual(to: original))
        document.undoManager?.redo()
        XCTAssertEqual(document.content.string, "보존 👩🏽‍💻 수정문 끝\n")
    }

    func testAttachmentCannotBeReplacedByPlainText() {
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(attributedString: NSAttributedString(attachment: NSTextAttachment()))
        let snapshot = AIEditSnapshot(document: document, selection: NSRange(location: 0, length: 0))
        XCTAssertThrowsError(try snapshot.replacement("lost image"))
    }

    func testPromptContainsCurrentDocumentSelectionAndOnlyItsHistory() throws {
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(string: "앞 선택 뒤")
        let snapshot = AIEditSnapshot(document: document, selection: NSRange(location: 2, length: 2))
        let prompt = try AIPrompt.make(snapshot: snapshot, messages: [.init(role: "assistant", text: "이전 답변")],
                                       request: "고쳐줘", mode: .edit, hasSelection: true)
        XCTAssertTrue(prompt.contains("앞 선택 뒤"))
        XCTAssertTrue(prompt.contains("\"selectedText\":\"선택\""))
        XCTAssertTrue(prompt.contains("이전 답변"))
        XCTAssertTrue(prompt.contains("고쳐줘"))
        document.content = NSMutableAttributedString(string: String(repeating: "가", count: 200_000))
        XCTAssertThrowsError(try AIPrompt.make(snapshot: AIEditSnapshot(document: document, selection: .init(location: 0, length: 0)),
                                              messages: [], request: "test", mode: .guide, hasSelection: false))
    }

    func testMalformedEditsAndProviderErrorsCannotBecomeDocumentText() throws {
        XCTAssertThrowsError(try AIPrompt.parseEdit("Here is the answer"))
        XCTAssertThrowsError(try AIPrompt.parseEdit("{\"explanation\":\"x\"}"))
        XCTAssertNil(try AIPrompt.parseEdit("{\"explanation\":\"advice\",\"replacement\":null}").replacement)
        XCTAssertEqual(try AIPrompt.parseEdit("```json\n{\"explanation\":\"x\",\"replacement\":\"y\"}\n```").replacement, "y")
        XCTAssertThrowsError(try AIClient.answer(from: .init(status: 0, stdout: "{\"is_error\":true,\"result\":\"quota\"}", stderr: ""), provider: .claude))
        XCTAssertThrowsError(try AIClient.answer(from: .init(status: 1, stdout: "partial response", stderr: "login required"), provider: .grok))
        XCTAssertThrowsError(try AIClient.answer(from: .init(status: 0, stdout: "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"partial\"}}", stderr: ""), provider: .codex))
        XCTAssertEqual(try AIClient.answer(from: .init(status: 0, stdout: "{\"response\":\"OK\"}", stderr: ""), provider: .gemini), "OK")
    }

    func testAIForcesScrollAndRestoresPagedPreferenceWithoutChangingDocument() throws {
        let previous = SettingsManager.shared.readingPageMode
        defer { SettingsManager.shared.readingPageMode = previous }
        SettingsManager.shared.readingPageMode = .paged
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("본문입니다."))
        let controller = EditorWindowController()
        document.addWindowController(controller)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.close(); document.removeWindowController(controller) }
        window.setContentSize(NSSize(width: 1100, height: 760))
        controller.editorVC.loadContent(of: document)
        controller.applyReadingPageMode(.paged)
        let original = NSAttributedString(attributedString: document.content)
        controller.toggleAI(nil)
        XCTAssertTrue(controller.isAIActive)
        XCTAssertNotNil(controller.aiChatVC)
        XCTAssertNotNil(controller.editorVC.view.window, "The scroll editor must be attached while chatting")
        XCTAssertEqual(SettingsManager.shared.readingPageMode, .paged, "AI must not erase the user's page preference")
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.selectedSegment = 1
        controller.changeReaderPageMode(control)
        XCTAssertNotNil(controller.editorVC.view.window)
        controller.toggleAI(nil)
        XCTAssertFalse(controller.isAIActive)
        XCTAssertNil(controller.editorVC.view.window, "The paged reader should return on close")
        XCTAssertTrue(document.content.isEqual(to: original))
    }

    func testSeparatedEditsKeepBoldTextBetweenThem() throws {
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("old **bold** old"))
        let snapshot = AIEditSnapshot(document: document, selection: .init(location: 0, length: 0))
        let (range, replacement) = try snapshot.replacement("new bold new")
        let result = NSMutableAttributedString(attributedString: document.content)
        result.replaceCharacters(in: range, with: replacement)
        XCTAssertEqual(result.string, "new bold new")
        XCTAssertTrue(MarkdownSerializer.serialize(result).contains("**bold**"), "Unchanged formatting between edits must survive")
    }

    func testCancellationFinishesWhenAChildRetainsPipes() {
        let done = expectation(description: "child group cancelled")
        let runner = AIProcess()
        runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                   arguments: ["-c", "trap '' TERM; sleep 30 & wait"], timeout: 10) { result in
            if case .success = result { XCTFail("Must report cancellation") }
            done.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { runner.cancel() }
        wait(for: [done], timeout: 4)
    }

    func testChatDirectEditUsesCLIResponseAndDocumentUndo() throws {
        let previousPath = AISettings.customPath(for: .claude)
        let previousProvider = AISettings.provider
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AISettings.setPath(previousPath, for: .claude)
            AISettings.provider = previousProvider
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = directory.appendingPathComponent("claude")
        let edit = "{\"explanation\":\"수정 설명\",\"replacement\":\"수정\"}"
        let response = String(decoding: try JSONSerialization.data(withJSONObject: ["result": edit]), as: UTF8.self)
        let script = "#!/bin/sh\ncat >/dev/null\nsleep 0.2\nprintf '%s' " + AITerminal.quote(response) + "\n"
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        AISettings.provider = .claude
        AISettings.setPath(fixture.path, for: .claude)
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("앞 원문 뒤"))
        let controller = EditorWindowController()
        document.addWindowController(controller)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.close(); document.removeWindowController(controller) }
        window.setContentSize(NSSize(width: 1100, height: 760))
        controller.editorVC.loadContent(of: document)
        controller.selectDocumentRange(NSRange(location: 2, length: 2))
        controller.toggleAI(nil)
        let chat = try XCTUnwrap(controller.aiChatVC)
        AIConversationStore.shared.conversation(for: document).mode = .edit
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let input = try XCTUnwrap(descendants(chat.view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        input.string = "선택한 부분을 수정해줘"
        chat.send()
        XCTAssertTrue(chat.isAwaitingResponse)
        XCTAssertFalse(chat.responseProgress.isHiddenOrHasHiddenAncestor)
        let deadline = Date().addingTimeInterval(5)
        while document.content.string != "앞 수정 뒤\n" && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(document.content.string, "앞 수정 뒤\n")
        XCTAssertFalse(chat.isAwaitingResponse)
        XCTAssertTrue(chat.responseProgress.isHiddenOrHasHiddenAncestor)
        input.string = "또 요청"
        chat.send()
        XCTAssertTrue(chat.isAwaitingResponse)
        chat.cancel()
        XCTAssertFalse(chat.isAwaitingResponse)
        XCTAssertTrue(chat.responseProgress.isHiddenOrHasHiddenAncestor)
        document.undoManager?.undo()
        XCTAssertEqual(document.content.string, "앞 원문 뒤\n")
        // Produce a local review artifact without launching or closing the user's running app.
        window.layoutIfNeeded()
        if let bitmap = window.contentView?.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) {
            window.contentView?.cacheDisplay(in: window.contentView!.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/jena-ai-ui-preview.png"))
        }
    }

    func testSettingsRecheckRequiresAnActualSuccessfulResponse() throws {
        let previousPath = AISettings.customPath(for: .claude)
        let previousProvider = AISettings.provider
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AISettings.setPath(previousPath, for: .claude)
            AISettings.provider = previousProvider
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = directory.appendingPathComponent("claude")
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo fixture-1; else cat >/dev/null; echo '{\"result\":\"JENANOTE_OK\"}'; fi\n"
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        AISettings.provider = .claude
        AISettings.setPath(fixture.path, for: .claude)
        let settings = AISettingsViewController()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = settings
        window.setContentSize(.init(width: 620, height: 440))
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let controls = descendants(settings.view)
        let recheck = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == L10n.tr("ai.recheck") })
        let login = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == L10n.tr("ai.login") })
        XCTAssertTrue(login.isEnabled)
        recheck.performClick(nil)
        XCTAssertFalse(login.isEnabled, "Do not start a second login while checking the existing session")
        XCTAssertFalse(recheck.isEnabled, "Checking must not be represented as connected")
        let deadline = Date().addingTimeInterval(4)
        while !recheck.isEnabled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let labels = controls.compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains { $0.contains(L10n.tr("ai.connected")) })
        window.layoutIfNeeded()
        XCTAssertGreaterThan(recheck.frame.width, 20)
        XCTAssertFalse(login.isEnabled, "A successful CLI request must disable redundant login")
        XCTAssertEqual(login.title, L10n.tr("ai.loggedIn"))

        let provider = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first)
        provider.selectItem(at: 1)
        NSApp.sendAction(try XCTUnwrap(provider.action), to: provider.target, from: provider)
        provider.selectItem(at: 0)
        NSApp.sendAction(try XCTUnwrap(provider.action), to: provider.target, from: provider)
        XCTAssertFalse(login.isEnabled, "Switching providers must preserve the verified provider's state")

        let path = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString == L10n.tr("ai.pathPlaceholder") })
        path.stringValue = "/bin/sh"
        NSApp.sendAction(try XCTUnwrap(path.action), to: path.target, from: path)
        XCTAssertTrue(login.isEnabled, "A different executable must not inherit verified credentials")
        path.stringValue = fixture.path
        NSApp.sendAction(try XCTUnwrap(path.action), to: path.target, from: path)
        XCTAssertFalse(login.isEnabled)

        try "#!/bin/sh\nexit 1\n".write(to: fixture, atomically: false, encoding: .utf8)
        recheck.performClick(nil)
        let failureDeadline = Date().addingTimeInterval(4)
        while !recheck.isEnabled && Date() < failureDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(login.isEnabled, "A failed recheck must allow reauthentication")
        XCTAssertEqual(login.title, L10n.tr("ai.login"))
    }

    func testLargeRewriteStopsBeforeExpensiveDiff() {
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(string: String(repeating: "a", count: 10_000))
        let snapshot = AIEditSnapshot(document: document, selection: .init(location: 0, length: 0))
        XCTAssertThrowsError(try snapshot.replacement(String(repeating: "b", count: 10_000)))
        XCTAssertEqual(document.content.string, String(repeating: "a", count: 10_000))
    }

    func testGrokOnlyAcceptsCompletedJSONResponse() throws {
        let completed = AIProcessOutput(status: 0, stdout: "{\"text\":\"JENANOTE_OK\",\"stopReason\":\"end_turn\"}", stderr: "")
        XCTAssertEqual(try AIClient.answer(from: completed, provider: .grok), "JENANOTE_OK")
        let partial = AIProcessOutput(status: 0, stdout: "{\"text\":\"partial\",\"stopReason\":\"cancelled\"}", stderr: "")
        XCTAssertThrowsError(try AIClient.answer(from: partial, provider: .grok), "Exit 0 alone is not a completed AI answer")
        let repeated = AIProcessOutput(status: 0, stdout: "{\"text\":\"repeated\",\"stopReason\":\"end_turn\",\"num_turns\":9}", stderr: "")
        XCTAssertThrowsError(try AIClient.answer(from: repeated, provider: .grok), "Hook-driven extra turns must not be silently applied")
    }

    func testGrokProfileIsPassedToChildWithoutReplacingUserHome() {
        let done = expectation(description: "isolated Grok profile")
        let runner = AIProcess()
        let profile = AIProvider.grok.environmentOverrides
        XCTAssertNotNil(profile["GROK_HOME"])
        XCTAssertNil(profile["HOME"])
        XCTAssertNil(profile["CODEX_HOME"])
        runner.run(executable: URL(fileURLWithPath: "/usr/bin/printenv"), arguments: ["GROK_HOME"],
                   environmentOverrides: profile) { result in
            switch result {
            case .success(let output): XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), AISettings.grokProfile.path)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    func testShellQuoteDoesNotInterpolatePath() {
        XCTAssertEqual(AITerminal.quote("a'b $(whoami)"), "'a'\\''b $(whoami)'")
    }

    func testProcessDrainsBothPipesAndPassesPromptLiterally() {
        let done = expectation(description: "process")
        let runner = AIProcess()
        let prompt = "$(touch /tmp/not-a-command) '한글'\n"
        runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: prompt, timeout: 2) { result in
            switch result {
            case .success(let output): XCTAssertEqual(output.stdout, prompt); XCTAssertEqual(output.status, 0)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testProcessTimeoutAndPrelaunchCancellationFinish() {
        let done = expectation(description: "timeout")
        let runner = AIProcess()
        runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1) { result in
            if case .success = result { XCTFail("Hung processes must time out") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let cancelled = expectation(description: "cancel")
        let stopped = AIProcess()
        stopped.cancel()
        stopped.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: []) { result in
            if case .success = result { XCTFail("Cancelled request must never launch") }
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 3)
    }
}
