import AppKit
import XCTest
@testable import JenaNoteKit

private final class EpisodesFakeGenerator: AISummaryGenerating {
    var tokenUsage: Int?
    /// Completions are held so the store stays "generating" until the test cancels.
    var pending: [(Result<String, Error>) -> Void] = []
    func summarize(prompt: String, provider: AIProvider, model: String?,
                   completion: @escaping (Result<String, Error>) -> Void) {
        pending.append(completion)
    }
    func cancel() {}
}

final class AIWorkContextEpisodesViewTests: XCTestCase {
    private var tmp: URL!
    private var root: URL!
    private var fake: EpisodesFakeGenerator!
    private var store: AIEpisodeSummaryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = tmp.appendingPathComponent("작품")
        for (path, text) in [("설정/세계관.md", "세계관"), ("집필/01화.md", "첫 화"),
                             ("집필/02화.md", "둘째 화"), ("집필/03화.md", "셋째 화")] {
            try write(path, text)
        }
        let config = AIWorkContextConfig(title: "작품", settingsSources: ["설정"], writingFolder: "집필")
        try AIWorkContext(rootURL: root, config: config, invalidPaths: []).save()
        fake = EpisodesFakeGenerator()
        let generator = fake!
        store = AIEpisodeSummaryStore(rootURL: root, makeGenerator: { generator })
    }

    override func tearDownWithError() throws {
        store?.cancel()
        AIWorkContextWindowController.resetRegistryForTesting()
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes a summary file plus its index record as if the app had generated it from `source`.
    private func writeSummary(_ episode: String, summary: String, source: String) throws {
        let file = AIWorkFile(relativePath: episode, url: root.appendingPathComponent("집필/\(episode)"), byteCount: 0)
        let url = store.summaryURL(for: file, isSetting: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try summary.write(to: url, atomically: true, encoding: .utf8)
        var index = store.loadIndex()
        index.entries[episode] = AISummaryRecord(sourceHash: AIEpisodeSummaryStore.hash(source),
                                                 summaryHash: AIEpisodeSummaryStore.summaryHash(summary),
                                                 generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                 provider: "claude")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: store.indexURL)
    }

    private func open() -> (AIWorkContextWindowController, AIWorkContextEpisodesView) {
        let controller = AIWorkContextWindowController.shared(for: root, store: store)
        controller.currentFile = root.appendingPathComponent("집필/03화.md")
        guard let view = controller.episodesView as? AIWorkContextEpisodesView else {
            XCTFail("episodes tab is not AIWorkContextEpisodesView")
            return (controller, AIWorkContextEpisodesView(controller: controller))
        }
        return (controller, view)
    }

    // MARK: - Tests

    func testRowsShowStateTextAndTags() throws {
        let (controller, view) = open()
        XCTAssertEqual(view.shownRows.map(\.file.relativePath), ["01화.md", "02화.md"])
        XCTAssertEqual(view.tableView.numberOfRows, 2)
        XCTAssertEqual(view.hintLabel.stringValue, String(format: L10n.tr("ai.work.episodes.hint"), 3, 2, 2))

        // Missing: gray text, "지금 만들기"; the previous episode (02화) carries the tag.
        XCTAssertEqual(view.stateLabels.map(\.stringValue),
                       [L10n.tr("ai.work.episodes.missing"), L10n.tr("ai.work.episodes.missing")])
        XCTAssertEqual(view.remakeButtons.map(\.title),
                       [L10n.tr("ai.work.episodes.makeNow"), L10n.tr("ai.work.episodes.makeNow")])
        XCTAssertNil(view.previousTags[0])
        XCTAssertEqual(view.previousTags[1]?.stringValue, L10n.tr("ai.work.episodes.previousTag"))
        XCTAssertTrue(view.lastRefreshLabel.isHidden)

        // Ready.
        try writeSummary("01화.md", summary: "요약 1", source: "첫 화")
        try writeSummary("02화.md", summary: "요약 2", source: "둘째 화")
        controller.reload()
        XCTAssertEqual(view.stateLabels.map(\.stringValue),
                       [L10n.tr("ai.work.episodes.ready"), L10n.tr("ai.work.episodes.ready")])
        XCTAssertEqual(view.remakeButtons.map(\.title),
                       [L10n.tr("ai.work.episodes.remake"), L10n.tr("ai.work.episodes.remake")])
        XCTAssertFalse(view.lastRefreshLabel.isHidden)

        // Manual (01화 summary edited by hand) and stale (02화 source changed).
        try "고친 요약 1".write(to: store.summaryURL(for: view.shownRows[0].file, isSetting: false),
                             atomically: true, encoding: .utf8)
        try write("집필/02화.md", "둘째 화 고침")
        controller.reload()
        XCTAssertEqual(view.stateLabels.map(\.stringValue),
                       [L10n.tr("ai.work.episodes.manual"), L10n.tr("ai.work.episodes.stale")])

        // Manual + source changed.
        try write("집필/01화.md", "첫 화 고침")
        controller.reload()
        XCTAssertEqual(view.stateLabels[0].stringValue, L10n.tr("ai.work.episodes.manualChanged"))
        XCTAssertEqual(AIWorkContextModel.episodeStateLabel(.manuallyEdited(sourceChanged: true)).isManual, true)
        XCTAssertEqual(AIWorkContextModel.episodeStateLabel(.stale).isManual, false)

        // Toggle off: saved, and the tag goes away.
        XCTAssertEqual(view.includePreviousCheckbox.state, .on)
        view.setIncludePrevious(false)
        XCTAssertFalse(try AIWorkContext.load(rootURL: root).config.includePreviousEpisode)
        XCTAssertEqual(view.includePreviousCheckbox.state, .off)
        XCTAssertEqual(view.previousTags.compactMap { $0 }.count, 0)
    }

    func testOpenDisabledWhenSummaryMissing() throws {
        try writeSummary("01화.md", summary: "요약 1", source: "첫 화")
        let (_, view) = open()
        XCTAssertEqual(view.openButtons.map(\.isEnabled), [true, false])

        var opened: [URL] = []
        view.openDocumentHandler = { opened.append($0) }
        view.open(row: 1)
        XCTAssertTrue(opened.isEmpty)
        view.open(row: 0)
        XCTAssertEqual(opened, [store.summaryURL(for: view.shownRows[0].file, isSetting: false)])
        XCTAssertTrue(view.errorLabel.isHidden)
    }

    func testRefreshButtonTogglesToCancelWhileGenerating() throws {
        let (controller, view) = open()
        var refreshCalls = 0
        var cancelCalls = 0
        controller.onRefreshAll = { refreshCalls += 1 }
        controller.onCancelRefresh = { cancelCalls += 1 }

        XCTAssertEqual(view.refreshButton.title, L10n.tr("ai.work.episodes.refreshAll"))
        XCTAssertTrue(view.progressLabel.isHidden)
        view.refreshOrCancel()
        XCTAssertEqual(refreshCalls, 1)

        controller.maintenanceProgress = (1, 2)
        XCTAssertEqual(view.refreshButton.title, L10n.tr("ai.work.cancelRefresh"))
        XCTAssertFalse(view.progressLabel.isHidden)
        XCTAssertEqual(view.progressLabel.stringValue, "1/2")
        XCTAssertFalse(view.tableView.isEnabled)
        XCTAssertTrue(view.otherGeneratingLabel.isHidden)
        view.refreshOrCancel()
        XCTAssertEqual(cancelCalls, 1)
        XCTAssertEqual(refreshCalls, 1)

        controller.maintenanceProgress = nil
        XCTAssertEqual(view.refreshButton.title, L10n.tr("ai.work.episodes.refreshAll"))
        XCTAssertTrue(view.progressLabel.isHidden)
        XCTAssertTrue(view.tableView.isEnabled)

        // Another window's request is generating: label shown, list and tool button disabled.
        store.prepare(episodes: view.shownRows.map(\.file), settings: [], provider: .claude, model: nil,
                      progress: { _, _ in }, completion: { _ in })
        XCTAssertTrue(store.isGenerating)
        controller.reload()
        XCTAssertFalse(view.otherGeneratingLabel.isHidden)
        XCTAssertFalse(view.tableView.isEnabled)
        XCTAssertFalse(view.refreshButton.isEnabled)
        view.refreshOrCancel()
        XCTAssertEqual(refreshCalls, 1)
    }

    func testOpenSummaryRefusesSymlinkedLeaf() throws {
        let outside = tmp.appendingPathComponent("outside.txt")
        try "밖의 파일".write(to: outside, atomically: true, encoding: .utf8)
        let (controller, view) = open()
        let file = view.shownRows[0].file
        let summary = store.summaryURL(for: file, isSetting: false)
        try FileManager.default.createDirectory(at: summary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: summary, withDestinationURL: outside)
        controller.reload()

        var opened: [URL] = []
        view.openDocumentHandler = { opened.append($0) }
        view.openSummary(file, store: store)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(view.errorLabel.isHidden)
        XCTAssertFalse(view.errorLabel.stringValue.isEmpty)
    }
}
