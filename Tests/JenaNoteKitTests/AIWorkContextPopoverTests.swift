import AppKit
import XCTest
@testable import JenaNoteKit

/// Minimal copy of the fake in AIEpisodeSummaryStoreTests (that one is file-private).
private final class PopoverFakeGenerator: AISummaryGenerating {
    var responses: [String] = []
    var tokenUsage: Int?

    func summarize(prompt: String, provider: AIProvider, model: String?,
                   completion: @escaping (Result<String, Error>) -> Void) {
        let result: Result<String, Error> = responses.isEmpty
            ? .failure(AIError(message: "no response"))
            : .success(responses.removeFirst())
        DispatchQueue.main.async { completion(result) }
    }

    func cancel() {}
}

final class AIWorkContextPopoverTests: XCTestCase {
    private var tmp: URL!
    private var root: URL!
    private var fake: PopoverFakeGenerator!
    private var store: AIEpisodeSummaryStore!
    private var originalLanguage: SettingsManager.Language!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        originalLanguage = SettingsManager.shared.language
        SettingsManager.shared.language = .ko
        AIWorkContextResolver.openDocuments = { [] }
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = tmp.appendingPathComponent("작품")
        for (path, text) in [
            ("집필/01화.md", "첫 화 본문"), ("집필/02화.md", "둘째 화 본문"), ("집필/03화.md", "셋째 화 본문"),
            ("설정/세계관.md", "세계관 설정"), ("설정/인물/하연.md", "하연 설정"), ("설정/금지.md", "빼둔 설정"),
        ] { try write(path, text) }
        // Invalid UTF-8 → unreadable setting.
        try Data([0xFF, 0xFE, 0xFD]).write(to: root.appendingPathComponent("설정/깨짐.md"))
        fake = PopoverFakeGenerator()
        let generator = fake!
        store = AIEpisodeSummaryStore(rootURL: root, makeGenerator: { generator })
    }

    override func tearDownWithError() throws {
        SettingsManager.shared.language = originalLanguage
        AIWorkContextResolver.openDocuments = {
            NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
        }
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func resolve(current: String, excluded: [String] = [], summarized: [String] = []) -> AIResolvedWorkContext {
        let config = AIWorkContextConfig(title: "달빛도시", settingsSources: ["설정"], excludedSettings: excluded,
                                         summarizedSettings: summarized, writingFolder: "집필")
        let context = AIWorkContext(rootURL: root, config: config, invalidPaths: [])
        return AIWorkContextResolver.resolve(context, currentFile: root.appendingPathComponent(current))
    }

    private func prepare(episodes: [AIWorkFile], responses: [String]) {
        fake.responses = responses
        let done = expectation(description: "prepare")
        store.prepare(episodes: episodes, settings: [], provider: .claude, model: nil,
                      progress: { _, _ in }) { result in
            if case .failure(let error) = result { XCTFail("prepare failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Tests

    func testSettingRowsReflectExclusionsAndSummarized() {
        let resolved = resolve(current: "집필/03화.md", excluded: ["설정/금지.md"], summarized: ["설정/세계관.md"])
        let rows = AIWorkContextPopoverController.settingRows(resolved)
        let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.file.relativePath, $0) })

        XCTAssertEqual(Set(byPath.keys), ["설정/세계관.md", "설정/인물/하연.md", "설정/금지.md", "설정/깨짐.md"])
        XCTAssertEqual(byPath["설정/세계관.md"].map { [$0.included, $0.summarized, $0.unreadable] }, [true, true, false])
        XCTAssertEqual(byPath["설정/인물/하연.md"].map { [$0.included, $0.summarized, $0.unreadable] }, [true, false, false])
        XCTAssertEqual(byPath["설정/금지.md"].map { [$0.included, $0.summarized, $0.unreadable] }, [false, false, false])
        XCTAssertEqual(byPath["설정/깨짐.md"].map { [$0.included, $0.summarized, $0.unreadable] }, [true, false, true])
        // Natural order by path, so rows do not jump around when a file is excluded/included.
        XCTAssertEqual(rows.map(\.file.relativePath),
                       AIWorkContextResolver.naturalSort(rows.map(\.file)).map(\.relativePath))
    }

    func testEpisodeRowsCarryStoreState() throws {
        let resolved = resolve(current: "집필/03화.md")
        XCTAssertEqual(resolved.previousEpisodes.map(\.relativePath), ["01화.md", "02화.md"])
        prepare(episodes: [resolved.previousEpisodes[0]], responses: ["요약1"])

        var rows = AIWorkContextPopoverController.episodeRows(resolved, store: store)
        XCTAssertEqual(rows.map(\.file), resolved.previousEpisodes)
        XCTAssertEqual(rows.map(\.state), [.ready, .missing])

        try "직접 고친 요약".write(to: store.summaryURL(for: resolved.previousEpisodes[0], isSetting: false),
                             atomically: true, encoding: .utf8)
        rows = AIWorkContextPopoverController.episodeRows(resolved, store: store)
        XCTAssertEqual(rows.map(\.state), [.manuallyEdited(sourceChanged: false), .missing])
    }

    func testToggleIncludedMovesPathInExcludedSettings() {
        var config = AIWorkContextConfig(title: "t", settingsSources: ["설정"], excludedSettings: ["설정/금지.md"],
                                         writingFolder: "집필")
        let original = config
        AIWorkContextPopoverController.toggleIncluded(&config, path: "설정/세계관.md")
        XCTAssertEqual(config.excludedSettings, ["설정/금지.md", "설정/세계관.md"])
        AIWorkContextPopoverController.toggleIncluded(&config, path: "설정/세계관.md")
        XCTAssertEqual(config, original)
        AIWorkContextPopoverController.toggleIncluded(&config, path: "설정/금지.md")
        XCTAssertEqual(config.excludedSettings, [])
    }

    func testToggleSummarizedMovesPathInSummarizedSettings() {
        var config = AIWorkContextConfig(title: "t", settingsSources: ["설정"], writingFolder: "집필")
        let original = config
        AIWorkContextPopoverController.toggleSummarized(&config, path: "설정/세계관.md")
        XCTAssertEqual(config.summarizedSettings, ["설정/세계관.md"])
        XCTAssertEqual(config.excludedSettings, [])
        AIWorkContextPopoverController.toggleSummarized(&config, path: "설정/세계관.md")
        XCTAssertEqual(config, original)
    }

    func testStateTextForManualWithSourceChange() {
        XCTAssertEqual(AIWorkContextPopoverController.stateText(.manuallyEdited(sourceChanged: true)),
                       "직접 수정됨 · 원본 변경 있음")
        XCTAssertEqual(AIWorkContextPopoverController.stateText(.manuallyEdited(sourceChanged: false)), "직접 수정됨")
        XCTAssertEqual(AIWorkContextPopoverController.stateText(.ready), "준비됨")
        XCTAssertEqual(AIWorkContextPopoverController.stateText(.missing), "없음")
        XCTAssertEqual(AIWorkContextPopoverController.stateText(.stale), "오래됨")
    }

    func testLargeFileThresholdAndInvalidPathsLine() {
        let url = root.appendingPathComponent("설정/큰.md")
        XCTAssertEqual(AIWorkContextPopoverController.largeFileThreshold, 200_000)
        XCTAssertFalse(AIWorkContextPopoverController.isLarge(AIWorkFile(relativePath: "a", url: url, byteCount: 200_000)))
        XCTAssertTrue(AIWorkContextPopoverController.isLarge(AIWorkFile(relativePath: "a", url: url, byteCount: 200_001)))

        let config = AIWorkContextConfig(title: "t", settingsSources: ["설정"], writingFolder: "집필")
        let clean = AIWorkContext(rootURL: root, config: config, invalidPaths: [])
        XCTAssertNil(AIWorkContextPopoverController.invalidPathsText(clean))
        let broken = AIWorkContext(rootURL: root, config: config, invalidPaths: ["../밖", "/abs"])
        XCTAssertEqual(AIWorkContextPopoverController.invalidPathsText(broken), "무시된 경로: ../밖, /abs")
    }

    func testBudgetSegmentsSumToContextByteCount() {
        let resolved = resolve(current: "집필/03화.md")
        prepare(episodes: resolved.previousEpisodes, responses: ["요약하나", "요약둘"])
        let (payload, _) = AIWorkContextAssembler(resolved: resolved, store: store)
            .payload(currentFile: root.appendingPathComponent("집필/03화.md"))
        let segments = AIWorkContextPopoverController.budgetSegments(payload)

        XCTAssertEqual(segments.settings + segments.summaries + segments.previous, payload.contextByteCount)
        XCTAssertEqual(segments.settings, "세계관 설정".utf8.count + "하연 설정".utf8.count + "빼둔 설정".utf8.count)
        XCTAssertEqual(segments.summaries, "요약하나".utf8.count + "요약둘".utf8.count)
        XCTAssertEqual(segments.previous, "둘째 화 본문".utf8.count)
    }
}
