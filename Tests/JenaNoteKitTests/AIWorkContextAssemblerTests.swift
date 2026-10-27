import AppKit
import XCTest
@testable import JenaNoteKit

/// Minimal copy of the fake in AIEpisodeSummaryStoreTests (that one is file-private).
private final class AssemblerFakeGenerator: AISummaryGenerating {
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

final class AIWorkContextAssemblerTests: XCTestCase {
    private var tmp: URL!
    private var root: URL!
    private var fake: AssemblerFakeGenerator!
    private var store: AIEpisodeSummaryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        AIWorkContextResolver.openDocuments = { [] }
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = tmp.appendingPathComponent("작품")
        for (path, text) in [
            ("집필/01화.md", "첫 화 본문"), ("집필/02화.md", "둘째 화 본문"), ("집필/03화.md", "셋째 화 본문"),
            ("집필/04화.md", "넷째 화 본문"),
            ("설정/세계관.md", "세계관 설정"), ("설정/인물/하연.md", "하연 설정"),
        ] { try write(path, text) }
        fake = AssemblerFakeGenerator()
        let generator = fake!
        store = AIEpisodeSummaryStore(rootURL: root, makeGenerator: { generator })
    }

    override func tearDownWithError() throws {
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

    private func resolve(current: String, summarized: [String] = [], enabled: Bool = true) -> AIResolvedWorkContext {
        let config = AIWorkContextConfig(title: "달빛도시", settingsSources: ["설정"], summarizedSettings: summarized,
                                         writingFolder: "집필", enabled: enabled)
        let context = AIWorkContext(rootURL: root, config: config, invalidPaths: [])
        return AIWorkContextResolver.resolve(context, currentFile: root.appendingPathComponent(current))
    }

    private func prepare(episodes: [AIWorkFile], settings: [AIWorkFile] = [], responses: [String]) {
        fake.responses = responses
        let done = expectation(description: "prepare")
        store.prepare(episodes: episodes, settings: settings, provider: .claude, model: nil,
                      progress: { _, _ in }) { result in
            if case .failure(let error) = result { XCTFail("prepare failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Tests

    func testPayloadIncludesSettingsSummariesAndPreviousEpisode() {
        let resolved = resolve(current: "집필/04화.md")
        prepare(episodes: resolved.previousEpisodes, responses: ["요약1", "요약2", "요약3"])
        let assembler = AIWorkContextAssembler(resolved: resolved, store: store)
        let (payload, skipped) = assembler.payload(currentFile: root.appendingPathComponent("집필/04화.md"))

        XCTAssertEqual(skipped, [])
        XCTAssertEqual(payload.title, "달빛도시")
        XCTAssertEqual(payload.currentEpisode, "04화.md")
        XCTAssertEqual(Set(payload.settings.map(\.name)), ["설정/세계관.md", "설정/인물/하연.md"])
        XCTAssertEqual(payload.settings.map(\.name), resolved.settings.map(\.relativePath))
        XCTAssertTrue(payload.settings.allSatisfy { !$0.summarized })
        XCTAssertEqual(payload.settings.first { $0.name == "설정/세계관.md" }?.text, "세계관 설정")
        XCTAssertEqual(payload.previousSummaries, [
            AIWorkSummary(name: "01화.md", summary: "요약1"),
            AIWorkSummary(name: "02화.md", summary: "요약2"),
            AIWorkSummary(name: "03화.md", summary: "요약3"),
        ])
        XCTAssertEqual(payload.previousEpisode, AIWorkEpisodeText(name: "03화.md", text: "셋째 화 본문"))
    }

    func testSummarizedSettingUsesSummaryText() {
        let resolved = resolve(current: "집필/01화.md", summarized: ["설정/세계관.md"])
        let world = resolved.settings.filter { $0.relativePath == "설정/세계관.md" }
        XCTAssertEqual(world.count, 1)
        prepare(episodes: [], settings: world, responses: ["세계관 요약"])
        let (payload, _) = AIWorkContextAssembler(resolved: resolved, store: store)
            .payload(currentFile: root.appendingPathComponent("집필/01화.md"))

        XCTAssertEqual(payload.settings.first { $0.name == "설정/세계관.md" },
                       AIWorkSetting(name: "설정/세계관.md", text: "세계관 요약", summarized: true))
        XCTAssertEqual(payload.settings.first { $0.name == "설정/인물/하연.md" },
                       AIWorkSetting(name: "설정/인물/하연.md", text: "하연 설정", summarized: false))
        XCTAssertEqual(payload.previousSummaries, [])
        XCTAssertNil(payload.previousEpisode)
    }

    func testStatusCountsReadySummaries() {
        let resolved = resolve(current: "집필/04화.md")
        XCTAssertEqual(resolved.previousEpisodes.count, 3)
        prepare(episodes: Array(resolved.previousEpisodes.prefix(2)), responses: ["요약1", "요약2"])
        let assembler = AIWorkContextAssembler(resolved: resolved, store: store)
        let bytes = assembler.payload(currentFile: root.appendingPathComponent("집필/04화.md")).payload.contextByteCount

        XCTAssertEqual(assembler.status(isGenerating: nil),
                       .active(settingsCount: 2, summariesReady: 2, summariesTotal: 3,
                               outsideWriting: false, contextBytes: bytes, budget: AIPrompt.budget(for: bytes)))
        XCTAssertEqual(assembler.status(isGenerating: (1, 3)), .generating(done: 1, total: 3))
    }

    func testOutsideWritingFolderStatus() {
        let resolved = resolve(current: "설정/세계관.md")
        let assembler = AIWorkContextAssembler(resolved: resolved, store: store)
        let (payload, _) = assembler.payload(currentFile: root.appendingPathComponent("설정/세계관.md"))

        XCTAssertEqual(payload.previousSummaries, [])
        XCTAssertNil(payload.previousEpisode)
        XCTAssertEqual(payload.settings.count, 2)
        XCTAssertEqual(payload.currentEpisode, "세계관.md")
        guard case let .active(settingsCount, ready, total, outside, _, _) = assembler.status(isGenerating: nil) else {
            return XCTFail("expected active status")
        }
        XCTAssertEqual(settingsCount, 2)
        XCTAssertEqual(ready, 0)
        XCTAssertEqual(total, 0)
        XCTAssertTrue(outside)
    }

    func testLocateResultSurfacesCorruptConfig() throws {
        try write(".jenanote/context.json", "{ not json")
        let file = root.appendingPathComponent("집필/01화.md")
        guard case .failure = AIWorkContext.locateResult(from: file) else { return XCTFail("expected corrupt failure") }
        XCTAssertNil(AIWorkContext.locate(from: file))
    }

    func testDisabledStatus() {
        let resolved = resolve(current: "집필/02화.md", enabled: false)
        XCTAssertEqual(AIWorkContextAssembler(resolved: resolved, store: store).status(isGenerating: nil), .disabled)
    }
}
