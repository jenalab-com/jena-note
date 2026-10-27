import AppKit
import XCTest
@testable import JenaNoteKit

/// Holds every completion so a summary run stays in progress until the test is done.
private final class HoldingGenerator: AISummaryGenerating {
    var tokenUsage: Int?
    var pending: [(Result<String, Error>) -> Void] = []
    func summarize(prompt: String, provider: AIProvider, model: String?,
                   completion: @escaping (Result<String, Error>) -> Void) {
        pending.append(completion)
    }
    func cancel() {}
}

/// Completes every summary at once, so a run finishes inside the call that started it.
private final class ImmediateGenerator: AISummaryGenerating {
    var tokenUsage: Int?
    func summarize(prompt: String, provider: AIProvider, model: String?,
                   completion: @escaping (Result<String, Error>) -> Void) {
        completion(.success("요약"))
    }
    func cancel() {}
}

final class AIWorkContextBarTests: XCTestCase {
    private var originalLanguage: SettingsManager.Language!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        originalLanguage = SettingsManager.shared.language
        SettingsManager.shared.language = .ko
    }

    private var tmp: URL?

    override func tearDown() {
        AIWorkContextWindowController.resetRegistryForTesting()
        if let tmp = tmp { try? FileManager.default.removeItem(at: tmp) }
        SettingsManager.shared.language = originalLanguage
        super.tearDown()
    }

    // MARK: - Chat panel wiring helpers

    /// <tmp>/<name>/설정/인물.md, <tmp>/<name>/집필/01화.md; returns (root, 01화.md).
    private func makeWork(_ name: String) throws -> (root: URL, file: URL) {
        let base: URL
        if let tmp = tmp { base = tmp } else {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            tmp = base
        }
        let fm = FileManager.default
        let root = base.appendingPathComponent(name)
        try fm.createDirectory(at: root.appendingPathComponent("설정"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("집필"), withIntermediateDirectories: true)
        try "인물".write(to: root.appendingPathComponent("설정/인물.md"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("집필/01화.md")
        try "본문".write(to: file, atomically: true, encoding: .utf8)
        return (root, file)
    }

    private func save(_ config: AIWorkContextConfig, at root: URL) throws {
        try AIWorkContext(rootURL: root, config: config, invalidPaths: []).save()
    }

    /// A chat panel showing `document`, with presenting intercepted.
    private func makeChat(showing document: MarkdownDocument,
                          presented: @escaping (AIWorkContextWindowController) -> Void) -> AIChatViewController {
        let chat = AIChatViewController()
        chat.currentDocument = { document }
        chat.windowPresenter = { presented($0 as! AIWorkContextWindowController) }
        chat.switchDocument()
        return chat
    }

    private func document(at url: URL?) -> MarkdownDocument {
        let document = MarkdownDocument()
        document.fileURL = url
        return document
    }

    func testOpenWorkWindowRoutesByStatus() throws {
        var presented: [AIWorkContextWindowController] = []
        let record: (AIWorkContextWindowController) -> Void = { presented.append($0) }

        // Unsaved document: nothing happens.
        let unsaved = makeChat(showing: document(at: nil), presented: record)
        XCTAssertEqual(unsaved.workBar.status, .unavailable(reason: .unsavedDocument))
        unsaved.openWorkWindow()
        XCTAssertTrue(presented.isEmpty)

        // Not in a work: first setup on the folders tab, hooks attached.
        let fresh = try makeWork("미지정")
        let notInWork = makeChat(showing: document(at: fresh.file), presented: record)
        XCTAssertEqual(notInWork.workBar.status, .unavailable(reason: .notInWork))
        notInWork.openWorkWindow()
        XCTAssertEqual(presented.count, 1)
        let setup = try XCTUnwrap(presented.last)
        XCTAssertTrue(setup.isProvisional)
        XCTAssertEqual(setup.selectedTab, .folders)
        XCTAssertNotNil(setup.onChange)
        XCTAssertNotNil(setup.onRegenerate)
        XCTAssertNotNil(setup.onRefreshAll)
        XCTAssertNotNil(setup.onCancelRefresh)

        // Corrupt context.json: set aside as .bak, then the same first setup path.
        let broken = try makeWork("고장")
        let jenanote = broken.root.appendingPathComponent(AIWorkContext.folderName)
        try FileManager.default.createDirectory(at: jenanote, withIntermediateDirectories: true)
        try "{ not json".write(to: jenanote.appendingPathComponent(AIWorkContext.fileName), atomically: true, encoding: .utf8)
        let brokenDocument = document(at: broken.file)
        let corrupt = makeChat(showing: brokenDocument, presented: record)
        XCTAssertEqual(corrupt.workBar.status, .corrupt)
        corrupt.openWorkWindow()
        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(try XCTUnwrap(presented.last).isProvisional)
        XCTAssertEqual(presented.last?.selectedTab, .folders)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jenanote.appendingPathComponent(AIWorkContext.fileName).path))
        let backup = jenanote.appendingPathComponent(AIWorkContext.fileName + ".bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not json")
        // The move is stated in the conversation (minor: corrupt reset status line).
        XCTAssertTrue(AIConversationStore.shared.conversation(for: brokenDocument).messages.contains {
            $0.role == "status" && $0.text == L10n.tr("ai.work.corruptMoved")
        })

        // Disabled with sources ("켜기"): turned on, no window.
        let off = try makeWork("꺼짐")
        try save(AIWorkContextConfig(title: "꺼짐", settingsSources: ["설정"], writingFolder: "집필",
                                     enabled: false, disabledByUser: true), at: off.root)
        let disabled = makeChat(showing: document(at: off.file), presented: record)
        XCTAssertEqual(disabled.workBar.status, .disabled)
        disabled.openWorkWindow()
        XCTAssertEqual(presented.count, 2)
        let enabledConfig = try AIWorkContext.load(rootURL: off.root).config
        XCTAssertTrue(enabledConfig.enabled)
        XCTAssertFalse(enabledConfig.disabledByUser)
        guard case .active = disabled.workBar.status else {
            return XCTFail("row should be active after 켜기, got \(disabled.workBar.status)")
        }

        // Saved work without sources: "사용 안 함 · 설정…" (never "꺼짐 · 켜기"); the window opens on
        // the sources tab and nothing is turned on.
        let empty = try makeWork("출처없음")
        try save(AIWorkContextConfig(title: "출처없음", settingsSources: [], writingFolder: "집필", enabled: false),
                 at: empty.root)
        let noSources = makeChat(showing: document(at: empty.file), presented: record)
        XCTAssertEqual(noSources.workBar.status, .unavailable(reason: .noSources))
        XCTAssertEqual(noSources.workBar.currentAppearance.text, "작품 문맥 사용 안 함")
        XCTAssertEqual(noSources.workBar.currentAppearance.buttonTitle, "설정…")
        noSources.openWorkWindow()
        XCTAssertEqual(presented.count, 3)
        XCTAssertEqual(presented.last?.selectedTab, .sources)
        XCTAssertFalse(try AIWorkContext.load(rootURL: empty.root).config.enabled)

        // Active: the shared window for the root, on the sources tab.
        let on = try makeWork("사용중")
        try save(AIWorkContextConfig(title: "사용중", settingsSources: ["설정"], writingFolder: "집필"), at: on.root)
        let active = makeChat(showing: document(at: on.file), presented: record)
        guard case .active = active.workBar.status else {
            return XCTFail("expected active, got \(active.workBar.status)")
        }
        active.openWorkWindow()
        XCTAssertEqual(presented.count, 4)
        let shared = AIWorkContextWindowController.shared(for: on.root, store: AIEpisodeSummaryStore.shared(for: on.root))
        XCTAssertTrue(presented.last === shared)
        XCTAssertEqual(shared.selectedTab, .sources)
        XCTAssertFalse(shared.isProvisional)
    }

    /// A work with 01~03화 whose shared store never finishes a summary; returns (root, 03화).
    private func makeGeneratingWork(_ name: String) throws -> (root: URL, file: URL, store: AIEpisodeSummaryStore) {
        try makeStoredWork(name, generator: HoldingGenerator())
    }

    /// A saved work with 01~03화 whose shared store uses `generator`; returns (root, 03화, store).
    private func makeStoredWork(_ name: String, generator: AISummaryGenerating) throws
        -> (root: URL, file: URL, store: AIEpisodeSummaryStore) {
        let work = try makeWork(name)
        try "둘째 화".write(to: work.root.appendingPathComponent("집필/02화.md"), atomically: true, encoding: .utf8)
        let third = work.root.appendingPathComponent("집필/03화.md")
        try "셋째 화".write(to: third, atomically: true, encoding: .utf8)
        try save(AIWorkContextConfig(title: name, settingsSources: ["설정"], writingFolder: "집필"), at: work.root)
        let store = AIEpisodeSummaryStore(rootURL: work.root, makeGenerator: { generator })
        AIEpisodeSummaryStore.installSharedForTesting(store)
        addTeardownBlock { AIEpisodeSummaryStore.removeSharedForTesting(store) }
        return (work.root, third, store)
    }

    /// Points the claude provider at an executable fixture next to `root` (restored on teardown).
    private func useFakeClaude(near root: URL) throws {
        let previousProvider = AISettings.provider
        let previousPath = AISettings.customPath(for: .claude)
        let fixture = root.deletingLastPathComponent().appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        AISettings.provider = .claude
        AISettings.setPath(fixture.path, for: .claude)
        addTeardownBlock {
            AISettings.setPath(previousPath, for: .claude)
            AISettings.provider = previousProvider
        }
    }

    private func editableInput(of chat: AIChatViewController) throws -> NSTextView {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        return try XCTUnwrap(descendants(chat.view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
    }

    /// C2: the window's "다시 만들기" writes into the window's work even after the panel moved on to
    /// another work.
    func testWindowRegenerateUsesWindowStoreAfterDocumentSwitch() throws {
        let a = try makeStoredWork("작품A", generator: ImmediateGenerator())
        let b = try makeStoredWork("작품B", generator: ImmediateGenerator())
        var shown = document(at: a.file)
        var presented: AIWorkContextWindowController?
        let chat = AIChatViewController()
        chat.currentDocument = { shown }
        chat.windowPresenter = { presented = $0 as? AIWorkContextWindowController }
        chat.switchDocument()
        chat.openWorkWindow()
        let windowA = try XCTUnwrap(presented)
        XCTAssertTrue(windowA.store === a.store)

        // The editor moves on to work B; A's window stays around.
        shown = document(at: b.file)
        chat.switchDocument()
        guard case .active = chat.workBar.status else {
            return XCTFail("panel should show work B, got \(chat.workBar.status)")
        }

        let episode = try XCTUnwrap(windowA.resolved?.previousEpisodes.first { $0.relativePath == "02화.md" })
        windowA.onRegenerate?(episode, false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: a.store.summaryURL(for: episode, isSetting: false).path))
        let bSummaries = b.root.appendingPathComponent(AIWorkContext.folderName).appendingPathComponent("summaries")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bSummaries.appendingPathComponent("02화.md.txt").path))
        XCTAssertTrue(b.store.loadIndex().entries.isEmpty)
        XCTAssertNil(windowA.maintenanceProgress)

        // "요약 전부 새로 만들기" in A also stays in A (01화 is the only one still missing there).
        windowA.onRefreshAll?()
        XCTAssertEqual(Set(a.store.loadIndex().entries.keys), ["01화.md", "02화.md"])
        XCTAssertTrue(b.store.loadIndex().entries.isEmpty)
    }

    /// I5: during this panel's own send-flow preparation the episodes tab shows its progress, not
    /// "another request is generating".
    func testEpisodesTabShowsOwnSendProgressNotOther() throws {
        let work = try makeGeneratingWork("보내기진행")
        try useFakeClaude(near: work.root)
        let doc = document(at: work.file)
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("셋째 화"))
        var window: AIWorkContextWindowController?
        let chat = makeChat(showing: doc, presented: { window = $0 })
        chat.openWorkWindow()
        let controller = try XCTUnwrap(window)
        let episodes = try XCTUnwrap(controller.episodesView as? AIWorkContextEpisodesView)

        try editableInput(of: chat).string = "하연의 반응 봐줘"
        chat.send()
        XCTAssertTrue(work.store.isGenerating)
        XCTAssertEqual(controller.sendProgress?.done, 0)
        XCTAssertEqual(controller.sendProgress?.total, 2)
        XCTAssertFalse(episodes.sendProgressLabel.isHidden)
        XCTAssertEqual(episodes.sendProgressLabel.stringValue, "지난 화 요약 만드는 중 0/2")
        XCTAssertTrue(episodes.otherGeneratingLabel.isHidden)
        XCTAssertFalse(episodes.refreshButton.isEnabled)

        chat.cancel()
        XCTAssertNil(controller.sendProgress)
        XCTAssertTrue(episodes.sendProgressLabel.isHidden)
        XCTAssertTrue(episodes.otherGeneratingLabel.isHidden)
    }

    /// I4: settings over the limit vs. over the limit only until §6.4 drops old summaries.
    func testOverLimitDistinguishesSettingsOverFromTrimmable() throws {
        func payload(settings: Int, summaries: [Int]) -> AIWorkPayload {
            AIWorkPayload(
                title: "t", currentEpisode: "",
                settings: [AIWorkSetting(name: "s", text: String(repeating: "a", count: settings), summarized: false)],
                previousSummaries: summaries.enumerated().map {
                    AIWorkSummary(name: "\($0.offset + 1)화", summary: String(repeating: "b", count: $0.element))
                },
                previousEpisode: nil)
        }
        func row(_ work: AIWorkPayload) -> AIWorkContextBarAppearance {
            AIWorkContextBar.appearance(for: .active(
                settingsCount: 1, summariesReady: work.previousSummaries.count,
                summariesTotal: work.previousSummaries.count, outsideWriting: false,
                contextBytes: work.contextByteCount, budget: AIPrompt.budget(for: work)))
        }

        // Settings alone exceed the limit: "설정이 한도를 넘었어요" and how much to cut.
        let settingsOver = payload(settings: 600_000, summaries: [40_000])
        XCTAssertEqual(AIPrompt.budget(for: settingsOver), .over)
        XCTAssertEqual(row(settingsOver).text, "설정이 한도를 넘었어요")
        XCTAssertEqual(row(settingsOver).detail, "640KB / 500KB")
        XCTAssertEqual(AIWorkContextModel.budgetFactLine(settingsOver),
                       "설정 600KB + 지난 화 요약 40KB = 640KB. 한도는 500KB예요. 140KB를 줄여야 보낼 수 있어요.")

        // Settings fit; the two oldest summaries are left out and the request goes through.
        let trimmable = payload(settings: 300_000, summaries: Array(repeating: 50_000, count: 5))
        XCTAssertEqual(AIPrompt.budget(for: trimmable), .willTrim(omitted: 2, dropsPrevious: false))
        XCTAssertEqual(try AIPrompt.fit(trimmable, base: [:]).omittedEarlierEpisodes, 2)
        XCTAssertEqual(row(trimmable).text, "한도를 넘어 오래된 요약이 빠져요")
        XCTAssertEqual(row(trimmable).detail, "550KB / 500KB")
        XCTAssertEqual(row(trimmable).dotColor, .systemOrange)
        XCTAssertNotNil(row(trimmable).background)
        XCTAssertEqual(AIWorkContextModel.budgetFactLine(trimmable),
                       "설정 300KB + 지난 화 요약 250KB + 앞 화 0KB = 550KB. 한도는 500KB예요. 오래된 요약 2개가 이번 요청에서 빠져요.")
    }

    func testGeneratingRowActionCancelsInsteadOfOpening() throws {
        let work = try makeGeneratingWork("생성중")
        let previousProvider = AISettings.provider
        let previousPath = AISettings.customPath(for: .claude)
        let fixture = work.root.deletingLastPathComponent().appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        AISettings.provider = .claude
        AISettings.setPath(fixture.path, for: .claude)
        defer {
            AISettings.setPath(previousPath, for: .claude)
            AISettings.provider = previousProvider
        }
        let doc = document(at: work.file)
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("셋째 화"))
        var presented = 0
        let chat = makeChat(showing: doc, presented: { _ in presented += 1 })
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let input = try XCTUnwrap(descendants(chat.view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        input.string = "하연의 반응 봐줘"
        chat.send()
        guard case .generating = chat.workBar.status else {
            return XCTFail("send should be generating summaries, got \(chat.workBar.status)")
        }
        XCTAssertTrue(chat.isAwaitingResponse)
        // Minor 4: a refresh (KVO / viewWillAppear / onChange) keeps the send flow's row.
        chat.refreshWorkContext()
        guard case .generating = chat.workBar.status else {
            return XCTFail("refresh must not wipe the generating row, got \(chat.workBar.status)")
        }

        chat.workBar.onPrimaryAction?()
        XCTAssertEqual(presented, 0, "취소 must never open the window")
        XCTAssertFalse(chat.isAwaitingResponse, "the request (and its summary run) is cancelled")
        XCTAssertEqual(input.string, "하연의 반응 봐줘", "the unsent question goes back to the input")
        if case .generating = chat.workBar.status { XCTFail("row should leave the generating state") }
    }

    func testCorruptBackupFailureDoesNotOpenFirstSetup() throws {
        let broken = try makeWork("백업실패")
        let jenanote = broken.root.appendingPathComponent(AIWorkContext.folderName)
        let config = jenanote.appendingPathComponent(AIWorkContext.fileName)
        try FileManager.default.createDirectory(at: jenanote, withIntermediateDirectories: true)
        try "{ not json".write(to: config, atomically: true, encoding: .utf8)
        // A directory squatting on the backup path makes the rename fail; it must not be deleted.
        let squatter = jenanote.appendingPathComponent(AIWorkContext.fileName + ".bak")
        try FileManager.default.createDirectory(at: squatter, withIntermediateDirectories: true)
        try "keep".write(to: squatter.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        var presented = 0
        let chat = makeChat(showing: document(at: broken.file), presented: { _ in presented += 1 })
        XCTAssertEqual(chat.workBar.status, .corrupt)
        chat.openWorkWindow()
        XCTAssertEqual(presented, 0)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{ not json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: squatter.appendingPathComponent("note.txt").path))
        XCTAssertNil(AIWorkContextWindowController.existing(for: broken.root))
        XCTAssertEqual(chat.workBar.status, .corrupt)
    }

    func testPanelDeinitClearsWindowProgress() throws {
        let work = try makeGeneratingWork("패널닫기")
        let doc = document(at: work.file)
        var window: AIWorkContextWindowController?
        weak var weakChat: AIChatViewController?
        autoreleasepool {
            let chat = makeChat(showing: doc, presented: { window = $0 })
            chat.openWorkWindow()
            window?.onRefreshAll?()
            weakChat = chat
        }
        let controller = try XCTUnwrap(window)
        XCTAssertNil(weakChat, "the panel should be released")
        XCTAssertNil(controller.maintenanceProgress, "a closed panel must not leave the window on 갱신 취소 N/M")
        XCTAssertNil(controller.onCancelRefresh)
        XCTAssertNil(controller.onRefreshAll)
        XCTAssertNil(controller.onRegenerate)
        XCTAssertNil(controller.onChange)
    }

    func testPanelProgressReachesWindowWhileAlive() throws {
        let work = try makeGeneratingWork("진행")
        var window: AIWorkContextWindowController?
        let chat = makeChat(showing: document(at: work.file), presented: { window = $0 })
        chat.openWorkWindow()
        let controller = try XCTUnwrap(window)
        controller.onRefreshAll?()
        XCTAssertNotNil(controller.maintenanceProgress)
        guard case .generating = chat.workBar.status else {
            return XCTFail("maintenance should show on the row, got \(chat.workBar.status)")
        }
        chat.workBar.onPrimaryAction?()   // 취소 → cancelMaintenance
        XCTAssertNil(controller.maintenanceProgress)
    }

    func testSavingUntitledDocumentIntoWorkRefreshesRow() throws {
        let work = try makeWork("저장")
        try save(AIWorkContextConfig(title: "저장", settingsSources: ["설정"], writingFolder: "집필"), at: work.root)
        let untitled = document(at: nil)
        let chat = makeChat(showing: untitled, presented: { _ in })
        XCTAssertEqual(chat.workBar.status, .unavailable(reason: .unsavedDocument))
        untitled.fileURL = work.file   // what Save As does
        guard case .active = chat.workBar.status else {
            return XCTFail("row should follow the new file URL, got \(chat.workBar.status)")
        }
    }

    private func active(settings: Int = 6, ready: Int = 12, total: Int = 12, outside: Bool = false,
                        bytes: Int = 182_345, budget: AIPromptBudget = .ok) -> AIWorkContextStatus {
        .active(settingsCount: settings, summariesReady: ready, summariesTotal: total,
                outsideWriting: outside, contextBytes: bytes, budget: budget)
    }

    private func check(_ status: AIWorkContextStatus, dot: NSColor, text: String, detail: String?, button: String,
                       enabled: Bool = true, warning: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let a = AIWorkContextBar.appearance(for: status)
        XCTAssertEqual(a.dotColor, dot, file: file, line: line)
        XCTAssertEqual(a.text, text, file: file, line: line)
        XCTAssertEqual(a.detail, detail, file: file, line: line)
        XCTAssertEqual(a.buttonTitle, button, file: file, line: line)
        XCTAssertEqual(a.buttonEnabled, enabled, file: file, line: line)
        XCTAssertEqual(a.background != nil, warning, file: file, line: line)
    }

    func testAppearanceForEachStatusMatchesTable() {
        check(.unavailable(reason: .notInWork), dot: .systemGray, text: "작품 문맥 사용 안 함", detail: nil, button: "설정…")
        check(.unavailable(reason: .unsavedDocument), dot: .systemGray, text: "작품 문맥 사용 안 함", detail: nil,
              button: "설정…", enabled: false)
        check(.unavailable(reason: .noSources), dot: .systemGray, text: "작품 문맥 사용 안 함", detail: nil, button: "설정…")
        check(.disabled, dot: .systemGray, text: "작품 문맥 꺼짐", detail: nil, button: "켜기")
        check(active(), dot: .systemGreen, text: "작품 문맥 사용 중", detail: "설정 6개 · 지난 화 12화", button: "설정…")
        check(active(ready: 2), dot: .systemGreen, text: "작품 문맥 사용 중",
              detail: "설정 6개 · 지난 화 2/12화 준비", button: "설정…")
        check(active(ready: 0, total: 0, outside: true), dot: .systemGreen, text: "작품 문맥 사용 중",
              detail: "설정 6개 · 지난 화 없음", button: "설정…")
        check(active(bytes: 400_000, budget: .warning), dot: .systemOrange, text: "작품 문맥 사용 중",
              detail: "400KB / 500KB에 가까워요", button: "설정…", warning: true)
        check(active(bytes: 640_000, budget: .over), dot: .systemOrange, text: "설정이 한도를 넘었어요",
              detail: "640KB / 500KB", button: "설정…", warning: true)
        check(active(bytes: 550_000, budget: .willTrim(omitted: 2, dropsPrevious: false)), dot: .systemOrange,
              text: "한도를 넘어 오래된 요약이 빠져요", detail: "550KB / 500KB", button: "설정…", warning: true)
        check(active(bytes: 510_000, budget: .willTrim(omitted: 0, dropsPrevious: true)), dot: .systemOrange,
              text: "한도를 넘어 지난 화 요약과 앞 화가 빠져요", detail: "510KB / 500KB", button: "설정…", warning: true)
        check(.corrupt, dot: .systemRed, text: "작품 문맥 설정을 읽을 수 없어요", detail: nil, button: "다시 설정…")
        check(.generating(done: 3, total: 12), dot: .systemBlue, text: "지난 화 요약 만드는 중 3/12", detail: nil, button: "취소")
    }

    func testUnsavedDocumentDisablesSetupButton() {
        let a = AIWorkContextBar.appearance(for: .unavailable(reason: .unsavedDocument))
        XCTAssertFalse(a.buttonEnabled)
        XCTAssertEqual(a.tooltip, "먼저 저장하세요")
        let bar = AIWorkContextBar()
        bar.update(.unavailable(reason: .unsavedDocument))
        XCTAssertFalse(bar.button.isEnabled)
    }

    func testDetailCarriesNumbersNotSentence() {
        let a = AIWorkContextBar.appearance(for: active())
        XCTAssertEqual(a.text, "작품 문맥 사용 중")
        XCTAssertEqual(a.detail, "설정 6개 · 지난 화 12화")
    }

    func testRowClickAndButtonClickFireSameAction() throws {
        let bar = AIWorkContextBar()
        bar.frame = NSRect(x: 0, y: 0, width: 300, height: 32)
        bar.update(.disabled)
        var count = 0
        bar.onPrimaryAction = { count += 1 }
        bar.button.performClick(nil)
        XCTAssertEqual(count, 1)
        let click = try XCTUnwrap(bar.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)
        let action = try XCTUnwrap(click.action)
        _ = (click.target as AnyObject).perform(action, with: click)
        XCTAssertEqual(count, 2)
    }

    func testFormatBytes() {
        XCTAssertEqual(AIWorkContextBar.formatBytes(182_345), "182KB")
        XCTAssertEqual(AIWorkContextBar.formatBytes(1_234_567), "1.2MB")
        XCTAssertEqual(AIWorkContextBar.formatBytes(999), "1KB")
    }

    func testUpdateShowsTextAndKeepsStatus() {
        let bar = AIWorkContextBar()
        bar.update(.disabled)
        XCTAssertEqual(bar.status, .disabled)
        XCTAssertEqual(bar.displayedText, "작품 문맥 꺼짐")
    }

    func testBarSitsDirectlyBelowDocumentLabelInChatPanel() throws {
        let chat = AIChatViewController()
        chat.view.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        let stack = try XCTUnwrap(chat.view.subviews.compactMap { $0 as? NSStackView }.first)
        let views = stack.arrangedSubviews
        let label = try XCTUnwrap(views.firstIndex { $0 === chat.documentLabel })
        let bar = try XCTUnwrap(views.firstIndex { $0 === chat.workBar })
        XCTAssertEqual(bar, label + 1)
        chat.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(chat.workBar.frame.width, stack.frame.width, accuracy: 1)
    }
}
