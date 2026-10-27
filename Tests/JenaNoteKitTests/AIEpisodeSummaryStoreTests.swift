import XCTest
import AppKit
@testable import JenaNoteKit

private final class FakeGenerator: AISummaryGenerating {
    var responses: [Result<String, Error>] = []
    private(set) var calls: [String] = []
    var tokenUsage: Int?
    /// When true, completions are stored in `pending` instead of being delivered.
    var deferCompletion = false
    var pending: [(Result<String, Error>) -> Void] = []
    private(set) var cancelCount = 0

    func summarize(prompt: String, provider: AIProvider, model: String?,
                   completion: @escaping (Result<String, Error>) -> Void) {
        calls.append(prompt)
        if deferCompletion {
            pending.append(completion)
            return
        }
        let result = responses.isEmpty
            ? .failure(AIError(message: "no response"))
            : responses.removeFirst()
        DispatchQueue.main.async { completion(result) }
    }

    func cancel() { cancelCount += 1 }
}

final class AIEpisodeSummaryStoreTests: XCTestCase {
    private var tmp: URL!
    private var root: URL!
    private var fake: FakeGenerator!
    private var store: AIEpisodeSummaryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = tmp.appendingPathComponent("작품")
        for (path, text) in [
            ("집필/01화.md", "첫 화 본문"), ("집필/02화.md", "둘째 화 본문"), ("집필/03화.md", "셋째 화 본문"),
            ("설정/세계관.md", "세계관 설정"),
        ] { try write(path, text) }
        fake = FakeGenerator()
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

    private func episode(_ name: String) -> AIWorkFile {
        let url = root.appendingPathComponent("집필/\(name)")
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return AIWorkFile(relativePath: name, url: url, byteCount: size)
    }

    private func setting(_ path: String) -> AIWorkFile {
        let url = root.appendingPathComponent(path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return AIWorkFile(relativePath: path, url: url, byteCount: size)
    }

    private var episodes: [AIWorkFile] { ["01화.md", "02화.md", "03화.md"].map(episode) }

    @discardableResult
    private func prepare(_ episodes: [AIWorkFile], settings: [AIWorkFile] = []) -> Result<Int, Error> {
        let exp = expectation(description: "prepare")
        var outcome: Result<Int, Error>!
        store.prepare(episodes: episodes, settings: settings, provider: .claude, model: nil,
                      progress: { _, _ in }, completion: { result in
            outcome = result
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
        return outcome
    }

    @discardableResult
    private func regenerate(_ file: AIWorkFile, isSetting: Bool = false) -> Result<Int, Error> {
        let exp = expectation(description: "regenerate")
        var outcome: Result<Int, Error>!
        store.regenerate(file, isSetting: isSetting, provider: .claude, model: nil) { result in
            outcome = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return outcome
    }

    private func readIndex() throws -> AISummaryIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AISummaryIndex.self, from: Data(contentsOf: store.indexURL))
    }

    private func errorMessage(_ result: Result<Int, Error>) -> String? {
        guard case .failure(var error) = result else { return nil }
        if let failure = error as? AISummaryGenerationError { error = failure.underlying }
        return (error as? AIError)?.message ?? error.localizedDescription
    }

    private func failedFile(_ result: Result<Int, Error>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return (error as? AISummaryGenerationError)?.file.relativePath
    }

    // MARK: - Tests

    func testMissingThenReadyAfterPrepare() throws {
        let file = episode("01화.md")
        XCTAssertEqual(store.state(of: file, isSetting: false), .missing)
        fake.responses = [.success("첫 화 요약")]
        fake.tokenUsage = 12
        let result = prepare([file])
        XCTAssertEqual(try result.get(), 12)
        XCTAssertEqual(store.state(of: file, isSetting: false), .ready)
        let url = store.summaryURL(for: file, isSetting: false)
        XCTAssertEqual(url.path, root.appendingPathComponent(".jenanote/summaries/01화.md.txt").path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "첫 화 요약")
        let record = try XCTUnwrap(try readIndex().entries["01화.md"])
        XCTAssertEqual(record.sourceHash, AIEpisodeSummaryStore.hash("첫 화 본문"))
        XCTAssertEqual(record.summaryHash, AIEpisodeSummaryStore.summaryHash("첫 화 요약"))
        XCTAssertEqual(record.provider, AIProvider.claude.rawValue)
        XCTAssertTrue(record.sourceHash.hasPrefix("sha256:"))
    }

    func testUnchangedSourceSkipsGeneration() throws {
        fake.responses = [.success("요약")]
        XCTAssertNoThrow(try prepare([episode("01화.md")]).get())
        XCTAssertEqual(fake.calls.count, 1)
        let second = FakeGenerator()
        store = AIEpisodeSummaryStore(rootURL: root, makeGenerator: { second })
        XCTAssertEqual(try prepare([episode("01화.md")]).get(), 0)
        XCTAssertEqual(second.calls.count, 0)
    }

    func testChangedSourceBecomesStaleAndRegenerates() throws {
        fake.responses = [.success("요약"), .success("새 요약")]
        XCTAssertNoThrow(try prepare([episode("01화.md")]).get())
        try write("집필/01화.md", "고친 첫 화")
        let file = episode("01화.md")
        XCTAssertEqual(store.state(of: file, isSetting: false), .stale)
        XCTAssertEqual(store.pending([file], isSetting: false), [file])
        XCTAssertNoThrow(try prepare([file]).get())
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(store.state(of: file, isSetting: false), .ready)
        XCTAssertEqual(store.summaryText(for: file, isSetting: false), "새 요약")
    }

    func testManualEditFreezesSummary() throws {
        fake.responses = [.success("AI 요약")]
        XCTAssertNoThrow(try prepare([episode("01화.md")]).get())
        let file = episode("01화.md")
        try "작가가 손본 요약".write(to: store.summaryURL(for: file, isSetting: false), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.state(of: file, isSetting: false), .manuallyEdited(sourceChanged: false))
        try write("집필/01화.md", "고친 첫 화")
        let changed = episode("01화.md")
        XCTAssertEqual(store.state(of: changed, isSetting: false), .manuallyEdited(sourceChanged: true))
        XCTAssertEqual(store.pending([changed], isSetting: false), [])
        XCTAssertEqual(try prepare([changed]).get(), 0)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(store.summaryText(for: changed, isSetting: false), "작가가 손본 요약")
    }

    func testRoundTripThroughPlainTextDoesNotFlagManual() throws {
        fake.responses = [.success("요약 본문")]
        XCTAssertNoThrow(try prepare([episode("01화.md")]).get())
        let file = episode("01화.md")
        let url = store.summaryURL(for: file, isSetting: false)
        let text = try String(contentsOf: url, encoding: .utf8)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.state(of: file, isSetting: false), .ready)
    }

    func testFailureStopsAndKeepsEarlierSummaries() throws {
        fake.responses = [.success("1 요약"), .failure(AIError(message: "boom")), .success("3 요약")]
        let result = prepare(episodes)
        XCTAssertEqual(errorMessage(result), "boom")
        XCTAssertEqual(failedFile(result), "02화.md")
        if case .failure(let error) = result { XCTAssertEqual(error.localizedDescription, "02화.md: boom") }
        XCTAssertEqual(store.state(of: episode("01화.md"), isSetting: false), .ready)
        XCTAssertEqual(store.state(of: episode("02화.md"), isSetting: false), .missing)
        XCTAssertEqual(store.state(of: episode("03화.md"), isSetting: false), .missing)
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertFalse(store.isGenerating)
    }

    func testRetryResumesFromFailedFile() throws {
        fake.responses = [.success("1 요약"), .failure(AIError(message: "boom"))]
        prepare(episodes)
        let firstRunCalls = fake.calls
        fake.responses = [.success("2 요약"), .success("3 요약")]
        XCTAssertNoThrow(try prepare(episodes).get())
        let retryCalls = Array(fake.calls.dropFirst(firstRunCalls.count))
        XCTAssertEqual(retryCalls, [
            try AIPrompt.makeSummary(episodeName: "02화.md", text: "둘째 화 본문"),
            try AIPrompt.makeSummary(episodeName: "03화.md", text: "셋째 화 본문"),
        ])
        for name in ["01화.md", "02화.md", "03화.md"] {
            XCTAssertEqual(store.state(of: episode(name), isSetting: false), .ready)
        }
    }

    func testNoPendingFilesMakesNoCalls() throws {
        XCTAssertEqual(try prepare([]).get(), 0)
        XCTAssertEqual(fake.calls.count, 0)
        XCTAssertFalse(store.isGenerating)
    }

    func testRenamedEpisodeIsMissingAndOrphanKept() throws {
        fake.responses = [.success("요약")]
        XCTAssertNoThrow(try prepare([episode("01화.md")]).get())
        let oldSummary = store.summaryURL(for: episode("01화.md"), isSetting: false)
        try FileManager.default.moveItem(at: root.appendingPathComponent("집필/01화.md"),
                                         to: root.appendingPathComponent("집필/1화.md"))
        let renamed = episode("1화.md")
        XCTAssertEqual(store.state(of: renamed, isSetting: false), .missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSummary.path))
        XCTAssertEqual(oldSummary.lastPathComponent, "01화.md.txt")
    }

    func testCancelStopsQueue() throws {
        fake.deferCompletion = true
        let exp = expectation(description: "cancelled")
        var outcome: Result<Int, Error>?
        var completions = 0
        store.prepare(episodes: episodes, settings: [], provider: .claude, model: nil,
                      progress: { _, _ in }, completion: { result in
            completions += 1
            outcome = result
            exp.fulfill()
        })
        XCTAssertTrue(store.isGenerating)
        XCTAssertEqual(fake.calls.count, 1)
        store.cancel()
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(errorMessage(try XCTUnwrap(outcome)), L10n.tr("ai.cancelled"))
        XCTAssertEqual(fake.cancelCount, 1)
        XCTAssertFalse(store.isGenerating)

        // A late response from the cancelled request must be ignored.
        let late = expectation(description: "late")
        fake.pending.first?(.success("늦은 요약"))
        DispatchQueue.main.async { late.fulfill() }
        wait(for: [late], timeout: 5)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(store.state(of: episode("01화.md"), isSetting: false), .missing)
    }

    func testSharedRegistryReturnsSameInstancePerRoot() throws {
        let other = tmp.appendingPathComponent("다른 작품")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let a = AIEpisodeSummaryStore.shared(for: root)
        let b = AIEpisodeSummaryStore.shared(for: root.appendingPathComponent("집필/..", isDirectory: true))
        XCTAssertTrue(a === b)
        XCTAssertFalse(a === AIEpisodeSummaryStore.shared(for: other))
    }

    func testRegenerateForceOverwritesManual() throws {
        fake.responses = [.success("AI 요약"), .success("다시 만든 요약")]
        XCTAssertNoThrow(try prepare([episode("01화.md")]).get())
        let file = episode("01화.md")
        try "손본 요약".write(to: store.summaryURL(for: file, isSetting: false), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.state(of: file, isSetting: false), .manuallyEdited(sourceChanged: false))
        XCTAssertNoThrow(try regenerate(file).get())
        XCTAssertEqual(store.state(of: file, isSetting: false), .ready)
        XCTAssertEqual(store.summaryText(for: file, isSetting: false), "다시 만든 요약")
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testRegenerateRefusesDirtyOpenSummary() throws {
        fake.responses = [.success("AI 요약"), .success("덮어쓸 요약")]
        XCTAssertNoThrow(try prepare([episode("01화.md")]).get())
        let file = episode("01화.md")
        let url = store.summaryURL(for: file, isSetting: false)
        let doc = MarkdownDocument()
        doc.fileURL = url
        doc.updateChangeCount(.changeDone)
        XCTAssertTrue(doc.isDocumentEdited)
        AIWorkContextResolver.openDocuments = { [doc] }
        let result = regenerate(file)
        XCTAssertEqual(errorMessage(result), L10n.tr("ai.work.summaryOpenDirty"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "AI 요약")
        XCTAssertEqual(fake.calls.count, 1)
        doc.updateChangeCount(.changeCleared)
    }

    func testSettingsSummaryUsesSettingsSubfolder() throws {
        let file = setting("설정/세계관.md")
        fake.responses = [.success("세계관 요약")]
        XCTAssertNoThrow(try prepare([], settings: [file]).get())
        let url = store.summaryURL(for: file, isSetting: true)
        XCTAssertEqual(url.path, root.appendingPathComponent(".jenanote/summaries/settings/설정/세계관.md.txt").path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "세계관 요약")
        let index = try readIndex()
        XCTAssertNotNil(index.settings["설정/세계관.md"])
        XCTAssertNil(index.entries["설정/세계관.md"])
        XCTAssertEqual(store.state(of: file, isSetting: true), .ready)
        XCTAssertEqual(store.state(of: file, isSetting: false), .missing)
    }

    func testSecondPrepareQueuesBehindAndSameEpisodeSummarizedOnce() throws {
        fake.responses = [.success("1 요약"), .success("2 요약"), .success("3 요약")]
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        var firstResult: Result<Int, Error>?
        var secondResult: Result<Int, Error>?
        var secondProgress: [Int] = []
        store.prepare(episodes: [episode("01화.md"), episode("02화.md")], settings: [], provider: .claude, model: nil,
                      progress: { _, _ in }, completion: { result in
            firstResult = result
            first.fulfill()
        })
        store.prepare(episodes: [episode("02화.md"), episode("03화.md")], settings: [], provider: .claude, model: nil,
                      progress: { done, _ in secondProgress.append(done) }, completion: { result in
            secondResult = result
            second.fulfill()
        })
        XCTAssertTrue(store.isGenerating)
        wait(for: [first, second], timeout: 5, enforceOrder: true)
        XCTAssertNoThrow(try XCTUnwrap(firstResult).get())
        XCTAssertNoThrow(try XCTUnwrap(secondResult).get())
        XCTAssertEqual(fake.calls, [
            try AIPrompt.makeSummary(episodeName: "01화.md", text: "첫 화 본문"),
            try AIPrompt.makeSummary(episodeName: "02화.md", text: "둘째 화 본문"),
            try AIPrompt.makeSummary(episodeName: "03화.md", text: "셋째 화 본문"),
        ])
        XCTAssertEqual(secondProgress, [1]) // 02화 was already done when the second caller started
        XCTAssertFalse(store.isGenerating)
        for name in ["01화.md", "02화.md", "03화.md"] {
            XCTAssertEqual(store.state(of: episode(name), isSetting: false), .ready)
        }
    }

    func testCancellingOneCallerDoesNotCancelOther() throws {
        fake.deferCompletion = true
        var results: [String: Result<Int, Error>] = [:]
        func track(_ name: String) -> (Result<Int, Error>) -> Void { { results[name] = $0 } }
        let a = store.prepare(episodes: [episode("01화.md")], settings: [], provider: .claude, model: nil,
                              progress: { _, _ in }, completion: track("A"))
        _ = store.prepare(episodes: [episode("02화.md")], settings: [], provider: .claude, model: nil,
                          progress: { _, _ in }, completion: track("B"))
        let c = store.prepare(episodes: [episode("03화.md")], settings: [], provider: .claude, model: nil,
                              progress: { _, _ in }, completion: track("C"))
        XCTAssertEqual(fake.calls.count, 1)

        // Cancelling a queued caller drops only that caller.
        c.cancel()
        XCTAssertEqual(errorMessage(try XCTUnwrap(results["C"])), L10n.tr("ai.cancelled"))
        XCTAssertNil(results["A"])
        XCTAssertEqual(fake.cancelCount, 0)

        // Cancelling the active caller stops its generator and lets B start.
        a.cancel()
        XCTAssertEqual(errorMessage(try XCTUnwrap(results["A"])), L10n.tr("ai.cancelled"))
        XCTAssertEqual(fake.cancelCount, 1)
        XCTAssertNil(results["B"])
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(fake.calls.last, try AIPrompt.makeSummary(episodeName: "02화.md", text: "둘째 화 본문"))
        XCTAssertTrue(store.isGenerating)

        // A's late response is ignored; B's response completes B.
        fake.pending[0](.success("늦은 1 요약"))
        XCTAssertNil(results["B"])
        fake.pending[1](.success("2 요약"))
        XCTAssertNoThrow(try XCTUnwrap(results["B"]).get())
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.state(of: episode("01화.md"), isSetting: false), .missing)
        XCTAssertEqual(store.state(of: episode("02화.md"), isSetting: false), .ready)
        XCTAssertEqual(store.state(of: episode("03화.md"), isSetting: false), .missing)
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testInterruptedRewriteReadsAsMissingNotManual() throws {
        fake.responses = [.success("AI 요약")]
        XCTAssertNoThrow(try prepare([episode("01화.md")]).get())
        let file = episode("01화.md")
        // Regeneration fails at the .txt write (target replaced by a directory) after the old record was dropped.
        let url = store.summaryURL(for: file, isSetting: false)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("block"), withIntermediateDirectories: true)
        fake.responses = [.success("새 요약")]
        let result = regenerate(file)
        XCTAssertEqual(failedFile(result), "01화.md")
        XCTAssertNil(try readIndex().entries["01화.md"])
        XCTAssertEqual(store.state(of: file, isSetting: false), .missing)
    }

    func testTokensUsedAccumulatesOnHandleEvenAfterFailure() throws {
        fake.tokenUsage = 10
        fake.responses = [.success("첫 화 요약"), .failure(AIError(message: "boom"))]
        let exp = expectation(description: "prepare")
        var outcome: Result<Int, Error>!
        let handle = store.prepare(episodes: episodes, settings: [], provider: .claude, model: nil,
                                   progress: { _, _ in }, completion: { result in
            outcome = result
            exp.fulfill()
        })
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(failedFile(outcome), "02화.md")
        XCTAssertEqual(handle.tokensUsed, 10)
    }

    // MARK: - Containment (F1) and one index load per sweep (F3)

    func testSymlinkedSummaryIsNotRead() throws {
        let fm = FileManager.default
        let secret = tmp.appendingPathComponent("credentials")
        try "SECRET".write(to: secret, atomically: true, encoding: .utf8)
        let file = episode("01화.md")
        // Planted work folder: the summary is a link to an outside file and its record's summaryHash
        // mismatches (it would read as "manuallyEdited" and be sent as a summary forever).
        let summary = store.summaryURL(for: file, isSetting: false)
        try fm.createDirectory(at: summary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: summary, withDestinationURL: secret)
        var index = AISummaryIndex()
        index.entries["01화.md"] = AISummaryRecord(sourceHash: AIEpisodeSummaryStore.hash("첫 화 본문"),
                                                    summaryHash: "sha256:planted", generatedAt: Date(), provider: "claude")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: store.indexURL)

        XCTAssertNil(store.summaryText(for: file, isSetting: false))
        XCTAssertEqual(store.state(of: file, isSetting: false), .missing)
        XCTAssertEqual(store.pending([file], isSetting: false), [file])
        // Regenerating refuses to write through the link; the outside file is untouched.
        fake.responses = [.success("요약")]
        XCTAssertEqual(failedFile(prepare([file])), "01화.md")
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "SECRET")
    }

    func testSymlinkedJenanoteFolderBlocksSummaryReadAndWrite() throws {
        let fm = FileManager.default
        let outside = tmp.appendingPathComponent("outside")
        let outsideSummary = outside.appendingPathComponent("summaries/01화.md.txt")
        try fm.createDirectory(at: outside.appendingPathComponent("summaries"), withIntermediateDirectories: true)
        try "밖의 요약".write(to: outsideSummary, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent(".jenanote"), withDestinationURL: outside)
        let file = episode("01화.md")
        XCTAssertNil(store.summaryText(for: file, isSetting: false))
        fake.responses = [.success("요약")]
        XCTAssertEqual(failedFile(prepare([file])), "01화.md")
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("summaries/index.json").path))
        XCTAssertEqual(try String(contentsOf: outsideSummary, encoding: .utf8), "밖의 요약")
    }

    func testStateSweepLoadsIndexOnce() throws {
        fake.responses = [.success("1 요약"), .success("2 요약")]
        XCTAssertNoThrow(try prepare([episode("01화.md"), episode("02화.md")]).get())
        try write("집필/02화.md", "고친 둘째 화")
        let files = episodes
        let before = store.indexLoadCount
        let index = store.snapshotIndex()
        let swept = files.map { store.state(of: $0, isSetting: false, index: index) }
        let pending = store.pending(files, isSetting: false, index: index)
        XCTAssertEqual(store.indexLoadCount - before, 1)
        XCTAssertEqual(swept, [.ready, .stale, .missing])
        // Same answers as the one-shot overloads (which load per call).
        XCTAssertEqual(swept, files.map { store.state(of: $0, isSetting: false) })
        XCTAssertEqual(pending, store.pending(files, isSetting: false))
        XCTAssertEqual(pending.map(\.relativePath), ["02화.md", "03화.md"])
    }
}
