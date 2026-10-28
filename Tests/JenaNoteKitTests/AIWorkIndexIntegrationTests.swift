import AppKit
import XCTest
@testable import JenaNoteKit

/// Runs the actual AIClient/process adapter against a deterministic executable, never a paid provider.
final class AIWorkIndexIntegrationTests: XCTestCase {
    func testChatUsesLocalIndexThenRetrievesEvidenceAndAnswersThroughCLIAdapter() throws {
        try exerciseChat(holdSummaries: false)
    }

    func testChatAnswersWhileBackgroundSummaryNeverCompletes() throws {
        try exerciseChat(holdSummaries: true)
    }

    private func exerciseChat(holdSummaries: Bool) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("settings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        let automatic = AIWorkIndexStore.automaticPreparationEnabled
        AIWorkIndexStore.automaticPreparationEnabled = true
        let provider = AISettings.provider
        let oldPath = AISettings.customPath(for: .claude)
        defer {
            AIWorkIndexStore.shared(for: root).cancel()
            AIWorkIndexStore.automaticPreparationEnabled = automatic
            AISettings.provider = provider
            AISettings.setPath(oldPath, for: .claude)
            AIWorkContextWindowController.resetRegistryForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        try "부활은 불가능하다.".write(to: root.appendingPathComponent("settings/rules.md"), atomically: true, encoding: .utf8)
        try "서약 장면".write(to: root.appendingPathComponent("chapters/01.md"), atomically: true, encoding: .utf8)
        try "현재 화".write(to: root.appendingPathComponent("chapters/02.md"), atomically: true, encoding: .utf8)
        try "FUTURE_SECRET".write(to: root.appendingPathComponent("chapters/03.md"), atomically: true, encoding: .utf8)
        let context = AIWorkContext(rootURL: root, config: AIWorkContextConfig(title: "Test", settingsSources: ["settings"], writingFolder: "chapters"), invalidPaths: [])
        try context.save()
        let executable = root.appendingPathComponent("claude")
        let script = """
        #!/usr/bin/python3
        import sys, json
        prompt = sys.stdin.read()
        assert not prompt.startswith('Create a search index'), 'Indexing must never call the CLI'
        if prompt.startswith('Select source evidence'):
            assert 'FUTURE_SECRET' not in prompt
            data = json.loads(prompt.split('INPUT:', 1)[1])
            settings = [item['id'] for item in data['catalog'] if item.get('kind') == 'setting']
            answer = json.dumps({'reads': settings, 'done': True})
        else:
            assert 'FUTURE_SECRET' not in prompt
            assert '부활은 불가능하다.' in prompt
            assert '저장 전 열린 글' in prompt
            answer = '설정 원문에 따르면 부활은 불가능해요. [settings/rules.md:1-1]'
        print(json.dumps({'result': answer, 'usage': {'input_tokens': 20, 'output_tokens': 10}}))
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        AISettings.provider = .claude
        AISettings.setPath(executable.path, for: .claude)
        let localStore = AIWorkIndexStore.shared(for: root)
        localStore.availability = { .available }
        localStore.generate = { _, completion in
            if !holdSummaries { completion(.success(AIIndexSummary(text: "설정과 사건의 검색 요약", origin: .apple))) }
            return {}
        }
        let document = MarkdownDocument()
        document.fileURL = root.appendingPathComponent("chapters/02.md")
        document.content = NSMutableAttributedString(string: "저장 전 열린 글")
        let chat = AIChatViewController()
        chat.currentDocument = { document }
        chat.switchDocument()
        let prepared = expectation(description: "Automatic preparation on document open")
        let indexStore = AIWorkIndexStore.shared(for: root)
        let preparationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if indexStore.index.passages.count == 4 && (holdSummaries ? indexStore.isRunning : indexStore.done == 4) {
                timer.invalidate(); prepared.fulfill()
            }
        }
        defer { preparationTimer.invalidate() }
        wait(for: [prepared], timeout: 30)
        XCTAssertNil(indexStore.error)
        func inputs(_ view: NSView) -> [NSTextView] {
            ([view as? NSTextView].compactMap { $0 } + view.subviews.flatMap(inputs)).filter(\.isEditable)
        }
        let input = try XCTUnwrap(inputs(chat.view).first)
        input.string = "부활 장면이 설정에 맞는지 봐줘"
        chat.send()
        XCTAssertEqual(chat.sendButton.toolTip, L10n.tr("ai.stop"))
        XCTAssertFalse(chat.options.modelPicker.isEnabled)
        let finished = expectation(description: "CLI-backed request")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if !chat.isAwaitingResponse { timer.invalidate(); finished.fulfill() }
        }
        defer { timer.invalidate(); chat.cancel() }
        wait(for: [finished], timeout: 30)
        XCTAssertEqual(chat.sendButton.toolTip, L10n.tr("ai.send"))
        XCTAssertTrue(chat.options.modelPicker.isEnabled)
        let conversation = AIConversationStore.shared.conversation(for: document)
        XCTAssertTrue(conversation.messages.contains { $0.role == "assistant" && $0.text.contains("부활은 불가능해요") })
        XCTAssertEqual(conversation.tokenUsage[.claude], 30, "Small works send original evidence without an extra retrieval call")
        XCTAssertEqual(indexStore.index.passages.count, 4)
        if holdSummaries {
            XCTAssertTrue(indexStore.isRunning, "Chat must not cancel the background work")
            XCTAssertEqual(indexStore.done, 0, "No summary was needed to answer")
        } else {
            XCTAssertTrue(indexStore.index.passages.allSatisfy { !$0.summary.isEmpty })
        }
        XCTAssertEqual(document.content.string, "저장 전 열린 글", "Guide mode must not modify the author’s document")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".jenanote/work-index.json").path))
        let workWindow = AIWorkContextWindowController.shared(for: root, store: AIEpisodeSummaryStore.shared(for: root))
        workWindow.currentFile = document.fileURL
        let sources = try XCTUnwrap(workWindow.sourcesView as? AIWorkContextSourcesView)
        XCTAssertTrue(sources.budgetBar.isHidden)
        XCTAssertTrue(sources.tableView.tableColumns.first { $0.identifier.rawValue == "mode" }?.isHidden == true)
        XCTAssertTrue(workWindow.episodesView is AIWorkIndexView)
        if holdSummaries { return }
        for (tab, name) in [(AIWorkContextWindowController.Tab.sources, "sources"), (.episodes, "episodes")] {
            workWindow.select(tab)
            workWindow.window?.appearance = NSAppearance(named: .darkAqua)
            workWindow.showWindow(nil)
            let view = try XCTUnwrap(workWindow.window?.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/jena-index-\(name).png"))
        }
        workWindow.window?.orderOut(nil)

    }
}
