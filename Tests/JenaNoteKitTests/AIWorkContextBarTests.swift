import AppKit
import XCTest
@testable import JenaNoteKit

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
        let corrupt = makeChat(showing: document(at: broken.file), presented: record)
        XCTAssertEqual(corrupt.workBar.status, .corrupt)
        corrupt.openWorkWindow()
        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(try XCTUnwrap(presented.last).isProvisional)
        XCTAssertEqual(presented.last?.selectedTab, .folders)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jenanote.appendingPathComponent(AIWorkContext.fileName).path))
        let backup = jenanote.appendingPathComponent(AIWorkContext.fileName + ".bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not json")

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

        // Disabled without sources: cannot turn on; the window opens on the sources tab.
        let empty = try makeWork("출처없음")
        try save(AIWorkContextConfig(title: "출처없음", settingsSources: [], writingFolder: "집필", enabled: false),
                 at: empty.root)
        let noSources = makeChat(showing: document(at: empty.file), presented: record)
        XCTAssertEqual(noSources.workBar.status, .disabled)
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
