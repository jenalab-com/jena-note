import AppKit
import XCTest
@testable import JenaNoteKit

/// Minimal copy of the fake in AIEpisodeSummaryStoreTests (that one is file-private).
private final class ModelFakeGenerator: AISummaryGenerating {
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

final class AIWorkContextModelTests: XCTestCase {
    private var tmp: URL!
    private var root: URL!
    private var fake: ModelFakeGenerator!
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
        fake = ModelFakeGenerator()
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
        let rows = AIWorkContextModel.settingRows(resolved)
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

        var rows = AIWorkContextModel.episodeRows(resolved, store: store)
        XCTAssertEqual(rows.map(\.file), resolved.previousEpisodes)
        XCTAssertEqual(rows.map(\.state), [.ready, .missing])

        try "직접 고친 요약".write(to: store.summaryURL(for: resolved.previousEpisodes[0], isSetting: false),
                             atomically: true, encoding: .utf8)
        rows = AIWorkContextModel.episodeRows(resolved, store: store)
        XCTAssertEqual(rows.map(\.state), [.manuallyEdited(sourceChanged: false), .missing])
    }

    func testToggleIncludedMovesPathInExcludedSettings() {
        var config = AIWorkContextConfig(title: "t", settingsSources: ["설정"], excludedSettings: ["설정/금지.md"],
                                         writingFolder: "집필")
        let original = config
        AIWorkContextModel.toggleIncluded(&config, path: "설정/세계관.md")
        XCTAssertEqual(config.excludedSettings, ["설정/금지.md", "설정/세계관.md"])
        AIWorkContextModel.toggleIncluded(&config, path: "설정/세계관.md")
        XCTAssertEqual(config, original)
        AIWorkContextModel.toggleIncluded(&config, path: "설정/금지.md")
        XCTAssertEqual(config.excludedSettings, [])
    }

    func testToggleSummarizedMovesPathInSummarizedSettings() {
        var config = AIWorkContextConfig(title: "t", settingsSources: ["설정"], writingFolder: "집필")
        let original = config
        AIWorkContextModel.toggleSummarized(&config, path: "설정/세계관.md")
        XCTAssertEqual(config.summarizedSettings, ["설정/세계관.md"])
        XCTAssertEqual(config.excludedSettings, [])
        AIWorkContextModel.toggleSummarized(&config, path: "설정/세계관.md")
        XCTAssertEqual(config, original)
    }

    func testStateTextForManualWithSourceChange() {
        XCTAssertEqual(AIWorkContextModel.stateText(.manuallyEdited(sourceChanged: true)),
                       "직접 수정됨 · 원본 변경 있음")
        XCTAssertEqual(AIWorkContextModel.stateText(.manuallyEdited(sourceChanged: false)), "직접 수정됨")
        XCTAssertEqual(AIWorkContextModel.stateText(.ready), "준비됨")
        XCTAssertEqual(AIWorkContextModel.stateText(.missing), "없음")
        XCTAssertEqual(AIWorkContextModel.stateText(.stale), "오래됨")
    }

    func testLargeFileThresholdAndInvalidPathsLine() {
        let url = root.appendingPathComponent("설정/큰.md")
        XCTAssertEqual(AIWorkContextModel.largeFileThreshold, 200_000)
        XCTAssertFalse(AIWorkContextModel.isLarge(AIWorkFile(relativePath: "a", url: url, byteCount: 200_000)))
        XCTAssertTrue(AIWorkContextModel.isLarge(AIWorkFile(relativePath: "a", url: url, byteCount: 200_001)))

        let config = AIWorkContextConfig(title: "t", settingsSources: ["설정"], writingFolder: "집필")
        let clean = AIWorkContext(rootURL: root, config: config, invalidPaths: [])
        XCTAssertNil(AIWorkContextModel.invalidPathsText(clean))
        let broken = AIWorkContext(rootURL: root, config: config, invalidPaths: ["../밖", "/abs"])
        XCTAssertEqual(AIWorkContextModel.invalidPathsText(broken), "무시된 경로: ../밖, /abs")
    }

    func testBudgetSegmentsSumToContextByteCount() {
        let resolved = resolve(current: "집필/03화.md")
        prepare(episodes: resolved.previousEpisodes, responses: ["요약하나", "요약둘"])
        let (payload, _) = AIWorkContextAssembler(resolved: resolved, store: store)
            .payload(currentFile: root.appendingPathComponent("집필/03화.md"))
        let segments = AIWorkContextModel.budgetSegments(payload)

        XCTAssertEqual(segments.settings + segments.summaries + segments.previous, payload.contextByteCount)
        XCTAssertEqual(segments.settings, "세계관 설정".utf8.count + "하연 설정".utf8.count + "빼둔 설정".utf8.count)
        XCTAssertEqual(segments.summaries, "요약하나".utf8.count + "요약둘".utf8.count)
        XCTAssertEqual(segments.previous, "둘째 화 본문".utf8.count)
    }

    // MARK: - Sources, budget, folders

    private func config(_ sources: [String], enabled: Bool = true) -> AIWorkContextConfig {
        AIWorkContextConfig(title: "달빛도시", settingsSources: sources, writingFolder: "집필", enabled: enabled)
    }

    private func resolved(_ config: AIWorkContextConfig) -> AIResolvedWorkContext {
        AIWorkContextResolver.resolve(AIWorkContext(rootURL: root, config: config, invalidPaths: []),
                                      currentFile: root.appendingPathComponent("집필/03화.md"))
    }

    func testSourceRowsCountFilesAndBytes() throws {
        let rows = AIWorkContextModel.sourceRows(resolved(config(["설정", "설정/금지.md", "설정/없음.md"])))
        XCTAssertEqual(rows.map(\.relativePath), ["설정", "설정/금지.md", "설정/없음.md"])
        // 세계관, 인물/하연, 금지, 깨짐 (all .md) = 4
        XCTAssertEqual(rows[0].isDirectory, true)
        XCTAssertEqual(rows[0].fileCount, 4)
        XCTAssertNil(rows[0].byteCount)
        XCTAssertEqual(rows[1].isDirectory, false)
        XCTAssertNil(rows[1].fileCount)
        XCTAssertEqual(rows[1].byteCount, "빼둔 설정".utf8.count)
        // Vanished entries stay visible so they can be removed.
        XCTAssertEqual(rows[2].fileCount, 0)
        XCTAssertNil(rows[2].byteCount)
    }

    func testSortedBySizeThenName() {
        let rows = AIWorkContextModel.settingRows(resolved(config(["설정"])))
        let bySize = AIWorkContextModel.sortedSettingRows(rows, by: .sizeDescending)
        XCTAssertEqual(bySize.map(\.file.byteCount), bySize.map(\.file.byteCount).sorted(by: >))
        let byName = AIWorkContextModel.sortedSettingRows(bySize, by: .name)
        XCTAssertEqual(byName.map(\.file.relativePath),
                       AIWorkContextResolver.naturalSort(rows.map(\.file)).map(\.relativePath))
        // Equal sizes fall back to name order.
        let a = AIWorkContextModel.SettingRow(file: AIWorkFile(relativePath: "b.md", url: root, byteCount: 5),
                                              included: true, summarized: false, unreadable: false)
        let b = AIWorkContextModel.SettingRow(file: AIWorkFile(relativePath: "a.md", url: root, byteCount: 5),
                                              included: true, summarized: false, unreadable: false)
        XCTAssertEqual(AIWorkContextModel.sortedSettingRows([a, b], by: .sizeDescending).map(\.file.relativePath),
                       ["a.md", "b.md"])
    }

    func testBudgetFactLineUnderAndOverLimit() {
        let under = AIWorkPayload(
            title: "t", currentEpisode: "",
            settings: [AIWorkSetting(name: "s", text: String(repeating: "a", count: 180_000), summarized: false)],
            previousSummaries: [AIWorkSummary(name: "e", summary: String(repeating: "b", count: 40_000))],
            previousEpisode: nil)
        XCTAssertEqual(AIWorkContextModel.budgetFactLine(under), "설정 180KB + 지난 화 요약 40KB = 220KB / 500KB")

        let over = AIWorkPayload(
            title: "t", currentEpisode: "",
            settings: [AIWorkSetting(name: "s", text: String(repeating: "a", count: 600_000), summarized: false)],
            previousSummaries: [AIWorkSummary(name: "e", summary: String(repeating: "b", count: 40_000))],
            previousEpisode: nil)
        XCTAssertEqual(AIWorkContextModel.budgetFactLine(over),
                       "설정 600KB + 지난 화 요약 40KB = 640KB. 한도는 500KB예요. 140KB를 줄여야 보낼 수 있어요.")
    }

    func testBudgetFactLineIncludesPreviousEpisodeWhenPresent() {
        func payload(settings: Int) -> AIWorkPayload {
            AIWorkPayload(
                title: "t", currentEpisode: "",
                settings: [AIWorkSetting(name: "s", text: String(repeating: "a", count: settings), summarized: false)],
                previousSummaries: [AIWorkSummary(name: "e", summary: String(repeating: "b", count: 40_000))],
                previousEpisode: AIWorkEpisodeText(name: "p", text: String(repeating: "c", count: 30_000)))
        }
        XCTAssertEqual(AIWorkContextModel.budgetFactLine(payload(settings: 180_000)),
                       "설정 180KB + 지난 화 요약 40KB + 앞 화 30KB = 250KB / 500KB")
        XCTAssertEqual(AIWorkContextModel.budgetFactLine(payload(settings: 600_000)),
                       "설정 600KB + 지난 화 요약 40KB + 앞 화 30KB = 670KB. 한도는 500KB예요. 170KB를 줄여야 보낼 수 있어요.")
    }

    func testAddingSourceRejectsOutsideRootAndRoot() throws {
        var cfg = config([])
        XCTAssertThrowsError(try AIWorkContextModel.addingSource(root, to: &cfg, root: root)) {
            XCTAssertEqual($0 as? AIWorkContextValidationError, .settingsIsRoot)
        }
        let outside = tmp.appendingPathComponent("다른작품/설정")
        XCTAssertThrowsError(try AIWorkContextModel.addingSource(outside, to: &cfg, root: root)) {
            XCTAssertEqual($0 as? AIWorkContextValidationError, .settingsOutsideRoot(outside.path))
        }
        XCTAssertEqual(cfg.settingsSources, [])
        // Adding the same source twice is a no-op.
        try AIWorkContextModel.addingSource(root.appendingPathComponent("설정"), to: &cfg, root: root)
        try AIWorkContextModel.addingSource(root.appendingPathComponent("설정"), to: &cfg, root: root)
        XCTAssertEqual(cfg.settingsSources, ["설정"])
    }

    func testAddingFirstSourceEnablesContext() throws {
        var cfg = config([], enabled: false)
        try AIWorkContextModel.addingSource(root.appendingPathComponent("설정"), to: &cfg, root: root)
        XCTAssertTrue(cfg.enabled)

        // A user who switched it off keeps it off when a source is added later.
        var manual = config([], enabled: false)
        manual.disabledByUser = true
        try AIWorkContextModel.addingSource(root.appendingPathComponent("설정"), to: &manual, root: root)
        XCTAssertFalse(manual.enabled)

        // Adding a second source never flips a deliberately disabled context.
        var off = config(["설정"], enabled: false)
        try AIWorkContextModel.addingSource(root.appendingPathComponent("집필"), to: &off, root: root)
        XCTAssertFalse(off.enabled)
    }

    func testRemovingLastSourceDisablesButKeepsChoices() {
        var cfg = config(["설정"])
        cfg.excludedSettings = ["설정/금지.md"]
        cfg.summarizedSettings = ["설정/세계관.md"]
        AIWorkContextModel.removingSource("설정", from: &cfg)
        XCTAssertEqual(cfg.settingsSources, [])
        XCTAssertFalse(cfg.enabled)
        XCTAssertEqual(cfg.excludedSettings, ["설정/금지.md"])
        XCTAssertEqual(cfg.summarizedSettings, ["설정/세계관.md"])
    }

    func testOverlappingSourcesDedupeFilesOnly() {
        let cfg = config(["설정", "설정/금지.md"])
        let result = resolved(cfg)
        let rows = AIWorkContextModel.settingRows(result)
        XCTAssertEqual(rows.count, Set(rows.map(\.file.relativePath)).count)
        XCTAssertEqual(rows.filter { $0.file.relativePath == "설정/금지.md" }.count, 1)
        XCTAssertEqual(AIWorkContextModel.sourceRows(result).map(\.relativePath), ["설정", "설정/금지.md"])
    }

    func testConfigWithoutDisabledByUserKeyStillDecodes() throws {
        let json = #"{"version":1,"title":"t","settingsSources":["설정"],"writingFolder":"집필","enabled":false}"#
        let decoded = try JSONDecoder().decode(AIWorkContextConfig.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.disabledByUser)
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.excludedSettings, [])
        XCTAssertTrue(decoded.includePreviousEpisode)
    }

    func testFoldersDraftFromSuggestionAndApply() throws {
        let file = root.appendingPathComponent("집필/01화.md")
        let draft = AIWorkContextModel.foldersDraft(suggestionFor: file)
        let norm: (URL) -> URL = { $0.standardizedFileURL.resolvingSymlinksInPath() }
        XCTAssertEqual(norm(draft.rootURL), norm(root))
        XCTAssertEqual(norm(draft.writingFolder), norm(root.appendingPathComponent("집필")))
        XCTAssertEqual(draft.title, "작품")
        XCTAssertTrue(draft.errors.isEmpty)
        XCTAssertTrue(draft.canApply)

        var edited = draft
        edited.title = "새 제목"
        edited = AIWorkContextModel.FoldersDraft(rootURL: edited.rootURL, writingFolder: edited.rootURL, title: edited.title)
        let applied = AIWorkContextModel.applying(edited, to: config(["설정"]))
        XCTAssertEqual(applied.title, "새 제목")
        XCTAssertEqual(applied.writingFolder, "")
        XCTAssertEqual(applied.settingsSources, ["설정"])

        let outside = AIWorkContextModel.FoldersDraft(rootURL: root, writingFolder: tmp.appendingPathComponent("밖"), title: "x")
        XCTAssertEqual(outside.errors, [.writingFolderOutsideRoot])
        XCTAssertFalse(outside.canApply)

        let existing = AIWorkContext(rootURL: root, config: config(["설정"]), invalidPaths: [])
        let fromContext = AIWorkContextModel.foldersDraft(from: existing)
        XCTAssertEqual(fromContext.title, "달빛도시")
        XCTAssertEqual(norm(fromContext.writingFolder), norm(root.appendingPathComponent("집필")))
    }

    func testFolderPreviewSkipsHiddenAndLimits() throws {
        for n in 1...7 { try write("미리보기/\(n)화.md", "x") }
        try write("미리보기/.숨김.md", "x")
        let preview = AIWorkContextModel.folderPreview(root.appendingPathComponent("미리보기"), limit: 5)
        XCTAssertEqual(preview, ["1화.md", "2화.md", "3화.md", "4화.md", "5화.md"])
        XCTAssertEqual(AIWorkContextModel.folderPreview(root.appendingPathComponent("없음")), [])
    }
}
