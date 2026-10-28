import XCTest
@testable import JenaNoteKit

final class AIWorkIndexTests: XCTestCase {
    private var root: URL!
    private var context: AIWorkContext!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("settings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        context = AIWorkContext(rootURL: root, config: AIWorkContextConfig(title: "Test", settingsSources: ["settings"], writingFolder: "chapters"), invalidPaths: [])
        try context.save()
        try write("settings/rules.md", "# 규칙\n부활은 불가능하다.\n인물: 하연")
        try write("chapters/01.md", "하연이 서약했다.")
        try write("chapters/02.md", "열린 글")
        try write("chapters/03.md", "미래비밀: 서약이 깨졌다.")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func ensure(_ store: AIWorkIndexStore) throws -> AIWorkIndex {
        let done = expectation(description: "prepared")
        var result: Result<AIWorkIndex, Error>?
        store.ensure(context: context) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result).get()
    }
    private func fake(_ count: @escaping () -> Void) -> AIWorkIndexStore.Generate {
        { _, completion in count(); completion(.success(AIIndexSummary(text: "규칙과 인물 검색 요약", origin: .apple))); return {} }
    }

    func testLargeKoreanFileIsLosslesslyChunkedWithBoundedUnicodeAndLines() {
        let text = String(repeating: "가나다😀", count: 60_000) + "\n둘째 줄\n"
        let chunks = AIWorkIndex.split(text: text, path: "settings/large.md", isSetting: true)
        XCTAssertGreaterThan(chunks.count, 10)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.text.utf8.count <= AIWorkIndex.chunkBytes })
        XCTAssertEqual(Set(chunks.map(\.id)).count, chunks.count)
        XCTAssertEqual(chunks.first?.firstLine, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.lastLine >= $0.firstLine })
    }

    func testPersistentCacheReusesUnchangedContentAndRefreshesOnlyChangedFile() throws {
        var calls = 0
        let store = AIWorkIndexStore(root: root, generate: fake { calls += 1 })
        let first = try ensure(store)
        XCTAssertEqual(calls, 4)
        XCTAssertTrue(first.passages.allSatisfy { $0.summaryOrigin == .apple })
        let reopened = AIWorkIndexStore(root: root, generate: fake { calls += 1 })
        _ = try ensure(reopened)
        XCTAssertEqual(calls, 4, "New sessions must not regenerate unchanged work")
        try write("chapters/01.md", "하연이 새로운 서약을 했다.")
        _ = try ensure(reopened)
        XCTAssertEqual(calls, 5)
        try FileManager.default.removeItem(at: root.appendingPathComponent("chapters/03.md"))
        let removed = try ensure(reopened)
        XCTAssertEqual(calls, 5)
        XCTAssertFalse(removed.passages.contains { $0.path == "chapters/03.md" })
    }

    func testUnavailableModelUsesPersistedExcerptsAndUpgradesWhenReady() throws {
        var state = AIWorkLocalSummarizer.Availability.unavailable("ai.index.modelNotReady")
        var calls = 0
        let store = AIWorkIndexStore(root: root, generate: fake { calls += 1 }, availability: { state })
        let initial = try ensure(store)
        XCTAssertEqual(calls, 0, "Unavailable models must not invoke inference or a CLI fallback")
        XCTAssertEqual(store.excerptCount, 4)
        XCTAssertTrue(initial.passages.allSatisfy { $0.summaryOrigin == .excerpt })
        XCTAssertFalse(AIWorkIndex.search(["부활"], in: initial.passages).isEmpty)
        let reopened = AIWorkIndexStore(root: root, generate: fake { calls += 1 }, availability: { state })
        XCTAssertEqual(reopened.excerptCount, 4)
        _ = try ensure(reopened)
        XCTAssertEqual(calls, 0)
        state = .available
        _ = try ensure(reopened)
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(reopened.excerptCount, 0)
        XCTAssertEqual(reopened.summaryCount, 4)
        state = .unavailable("ai.index.intelligenceDisabled")
        _ = try ensure(reopened)
        XCTAssertEqual(calls, 4, "Existing AI summaries remain useful when the device model becomes unavailable")
        XCTAssertEqual(reopened.summaryCount, 4)
    }

    func testFailedPassageIsCachedUntilExplicitRetryAndSuccessfulPassagesAreKept() throws {
        var calls = 0
        let store = AIWorkIndexStore(root: root, generate: { passage, completion in
            calls += 1
            completion(.success(calls == 2 ? .excerpt(passage, reason: "ai.index.localFailed")
                : AIIndexSummary(text: "summary", origin: .apple)))
            return {}
        })
        _ = try ensure(store)
        XCTAssertEqual(store.excerptCount, 1)
        _ = try ensure(store)
        XCTAssertEqual(calls, 4, "Opening another chapter must not endlessly retry a failed passage")
        let done = expectation(description: "retry excerpt only")
        store.ensure(context: context, retryExcerpts: true) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(store.excerptCount, 0)
    }

    func testLegacyIndexIsRebuiltWithoutTouchingManualSummaries() throws {
        var old = try AIWorkIndex.scan(context: context)
        old.version = 1
        for i in old.passages.indices { old.passages[i].summary = "old CLI summary" }
        let folder = root.appendingPathComponent(".jenanote")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("summaries"), withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: folder.appendingPathComponent("work-index.json"))
        let manual = folder.appendingPathComponent("summaries/manual.txt")
        try "작가의 요약".write(to: manual, atomically: true, encoding: .utf8)
        var calls = 0
        let store = AIWorkIndexStore(root: root, generate: fake { calls += 1 })
        let fresh = try ensure(store)
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(fresh.version, 2)
        XCTAssertFalse(fresh.passages.contains { $0.summary == "old CLI summary" })
        XCTAssertEqual(try String(contentsOf: manual), "작가의 요약")
    }

    func testWhitespacePassageNeverBlocksPreparationOrCallsTheModel() throws {
        try write("settings/blank.md", String(repeating: " ", count: 3000))
        var calls = 0
        let store = AIWorkIndexStore(root: root, generate: fake { calls += 1 })
        let index = try ensure(store)
        XCTAssertEqual(calls, 4)
        let blanks = index.passages.filter { $0.path == "settings/blank.md" }
        XCTAssertEqual(blanks.map(\.text).joined(), String(repeating: " ", count: 3000))
        XCTAssertTrue(blanks.allSatisfy { $0.summaryOrigin == .excerpt && !$0.summary.isEmpty })
    }

    func testFutureFilesAreIndexedButNeverEnterCatalogSearchOrEvidence() throws {
        let index = try AIWorkIndex.scan(context: context)
        XCTAssertTrue(index.passages.contains { $0.path == "chapters/03.md" })
        let resolved = AIWorkContextResolver.resolve(context, currentFile: root.appendingPathComponent("chapters/02.md"))
        let eligible = try index.eligible(for: resolved, includeOpenSettings: false)
        XCTAssertEqual(Set(eligible.map(\.path)), ["settings/rules.md", "chapters/01.md"])
        XCTAssertTrue(AIWorkIndex.search(["미래비밀"], in: eligible).isEmpty)
        XCTAssertTrue(AIWorkRetrieval.page(-1, passages: eligible).isEmpty)
        XCTAssertTrue(AIWorkRetrieval.page(Int.max, passages: eligible).isEmpty)
    }

    func testSymlinkAndExcludedSourcesNeverIndexed() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("settings/escape.md"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        context.config.excludedSettings = ["settings/rules.md"]
        let index = try AIWorkIndex.scan(context: context)
        XCTAssertFalse(index.passages.contains { $0.isSetting })
    }

    func testFailurePreservesCompletedChunksAndRetryResumes() throws {
        var calls = 0
        let store = AIWorkIndexStore(root: root, generate: { _, completion in
            calls += 1
            completion(calls == 2 ? .failure(AIError(message: "offline")) : .success(AIIndexSummary(text: "summary", origin: .apple)))
            return {}
        })
        XCTAssertThrowsError(try ensure(store))
        XCTAssertEqual(store.done, 1)
        XCTAssertNotNil(store.error)
        let reopened = AIWorkIndexStore(root: root, generate: fake { calls += 1 })
        _ = try ensure(reopened)
        XCTAssertEqual(calls, 5, "Only three unfinished passages should be generated")
    }

    func testConcurrentPrepareDoesNotDuplicateModelCalls() throws {
        var calls = 0
        let store = AIWorkIndexStore(root: root, generate: fake { calls += 1 })
        let a = expectation(description: "first"), b = expectation(description: "second")
        store.ensure(context: context) { result in if case .failure(let error) = result { XCTFail("\(error)") }; a.fulfill() }
        store.ensure(context: context) { result in if case .failure(let error) = result { XCTFail("\(error)") }; b.fulfill() }
        wait(for: [a, b], timeout: 10)
        XCTAssertEqual(calls, 4)
    }

    func testCancellationRejectsLateResultAndPreservesQuestionIndependentIndex() throws {
        var pending: ((Result<AIIndexSummary, Error>) -> Void)?
        let called = expectation(description: "called"), finished = expectation(description: "cancelled")
        let store = AIWorkIndexStore(root: root, generate: { _, completion in
            pending = completion; called.fulfill(); return {}
        })
        store.ensure(context: context) { result in
            if case .success = result { XCTFail("Cancellation must fail") }; finished.fulfill()
        }
        wait(for: [called], timeout: 5)
        store.cancel()
        pending?(.success(AIIndexSummary(text: "late", origin: .apple)))
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(store.isRunning)
        XCTAssertTrue(store.index.passages.allSatisfy { $0.summary.isEmpty })
    }

    func testSearchThenReadReturnsOriginalEvidenceAndCannotReadUnknownIDs() throws {
        let index = try AIWorkIndex.scan(context: context)
        let resolved = AIWorkContextResolver.resolve(context, currentFile: root.appendingPathComponent("chapters/02.md"))
        var passages = try index.eligible(for: resolved, includeOpenSettings: false)
        for i in 0..<25 {
            passages += AIWorkIndex.split(text: "unrelated \(i)", path: "settings/extra\(i).md", isSetting: true)
        }
        let rule = try XCTUnwrap(passages.first { $0.isSetting })
        var calls = 0
        let retrieval = AIWorkRetrieval(generate: { prompt, _, _, completion in
            calls += 1
            XCTAssertFalse(prompt.contains("미래비밀"))
            XCTAssertLessThanOrEqual(prompt.utf8.count, 500_000)
            let reply = calls == 1 ? "{\"queries\":[\"부활\"]}" : "{\"reads\":[\"\(rule.id)\",\"../escape\"],\"done\":true}"
            completion(.success(reply), 5)
            return {}
        })
        let done = expectation(description: "retrieved")
        retrieval.prepare(passages: passages, title: "t", currentEpisode: "02", document: "열린 글", question: "부활 가능한가", provider: .claude, model: nil) { result in
            do {
                let payload = try result.get()
                XCTAssertEqual(payload.settings.first?.text, rule.text)
                XCTAssertFalse(payload.settings.first?.summarized ?? true)
                XCTAssertTrue(payload.retrievalNote?.contains("budget") == true)
                XCTAssertEqual(retrieval.tokensUsed, 10)
            } catch { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testAutomaticEvidenceFitsWithoutRequiringAuthorToExcludeFiles() throws {
        let document = MarkdownDocument()
        document.content = NSMutableAttributedString(string: String(repeating: "a", count: 350_000))
        let snapshot = AIEditSnapshot(document: document, selection: NSRange(location: 0, length: 0))
        var payload = AIWorkPayload(title: "t", currentEpisode: "02", settings: (0..<30).map {
            AIWorkSetting(name: "\($0)", text: String(repeating: "b", count: 12_000), summarized: false)
        }, previousSummaries: [])
        payload.retrievalNote = "Selected evidence"
        let prompt = try AIPrompt.make(snapshot: snapshot, messages: [], request: "check", mode: .guide, hasSelection: false, work: payload)
        XCTAssertLessThanOrEqual(prompt.utf8.count, 500_000)
        XCTAssertTrue(prompt.contains("Evidence was reduced"))
    }

    func testMalformedRetrievalCommandDoesNotExecuteAnything() {
        XCTAssertThrowsError(try AIWorkRetrieval.decode("rm -rf /"))
        XCTAssertThrowsError(try AIWorkRetrieval.decode("{}"))
        XCTAssertNoThrow(try AIWorkRetrieval.decode("```json\n{\"done\":true}\n```"))
    }

    func testSearchSnapshotDoesNotWaitForOrCancelBackgroundInference() throws {
        let started = expectation(description: "inference held")
        var cancellations = 0
        let store = AIWorkIndexStore(root: root, generate: { _, _ in
            started.fulfill()
            return { cancellations += 1 }
        })
        store.ensure(context: context) { _ in }
        wait(for: [started], timeout: 5)
        defer { store.cancel() }
        try write("settings/rules.md", "새 규칙: 부활 가능")
        let ready = expectation(description: "search ready while inference is held")
        store.prepareForSearch(context: context) { result in
            do {
                let snapshot = try result.get()
                XCTAssertTrue(snapshot.passages.contains { $0.text.contains("새 규칙") })
                XCTAssertTrue(snapshot.passages.allSatisfy { $0.summary.isEmpty })
                XCTAssertEqual(store.done, 0)
                XCTAssertTrue(store.isRunning)
                XCTAssertEqual(cancellations, 0)
            } catch { XCTFail("\(error)") }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
    }

    func testSearchSnapshotReusesOnlyUnchangedCacheAndHonorsCurrentExclusions() throws {
        var calls = 0
        let store = AIWorkIndexStore(root: root, generate: fake { calls += 1 })
        _ = try ensure(store)
        try write("chapters/01.md", "수정된 원문")
        context.config.excludedSettings = ["settings/rules.md"]
        let ready = expectation(description: "fresh eligible sources")
        store.prepareForSearch(context: context) { result in
            do {
                let snapshot = try result.get()
                XCTAssertFalse(snapshot.passages.contains { $0.isSetting })
                XCTAssertEqual(snapshot.passages.first { $0.path == "chapters/01.md" }?.summary, "")
                XCTAssertFalse(snapshot.passages.first { $0.path == "chapters/02.md" }?.summary.isEmpty ?? true)
                XCTAssertEqual(calls, 4, "Search preparation must not invoke inference")
            } catch { XCTFail("\(error)") }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
    }

    func testQuestionPriorityAppliesAfterCurrentInferenceWithoutCancellingIt() throws {
        let first = expectation(description: "first"), second = expectation(description: "priority next")
        var pending: ((Result<AIIndexSummary, Error>) -> Void)?
        var calls: [String] = []
        var cancellations = 0
        let store = AIWorkIndexStore(root: root, generate: { passage, completion in
            calls.append(passage.id)
            pending = completion
            (calls.count == 1 ? first : second).fulfill()
            return { cancellations += 1 }
        })
        store.ensure(context: context) { _ in }
        wait(for: [first], timeout: 5)
        let priority = try XCTUnwrap(store.index.passages.last)
        store.prioritize([priority])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(cancellations, 0)
        pending?(.success(AIIndexSummary(text: "first complete", origin: .apple)))
        wait(for: [second], timeout: 5)
        XCTAssertEqual(calls.last, priority.id)
        XCTAssertEqual(cancellations, 0)
        store.cancel()
        let reopened = AIWorkIndexStore(root: root)
        XCTAssertEqual(reopened.index.passages.filter { !$0.summary.isEmpty }.count, 1, "Stopping flushes completed work")
    }

    func testOpenDocumentAndPreviousChapterAreSummarizedBeforeOtherFiles() throws {
        var paths: [String] = []
        let store = AIWorkIndexStore(root: root, generate: { passage, completion in
            paths.append(passage.path)
            completion(.success(AIIndexSummary(text: "summary", origin: .apple)))
            return {}
        })
        store.prioritizeDocument(root.appendingPathComponent("chapters/02.md"))
        _ = try ensure(store)
        XCTAssertEqual(Array(paths.prefix(2)), ["chapters/02.md", "chapters/01.md"])
    }

    func testFastSummariesBatchWholeIndexWritesAndFlushAtCompletion() throws {
        for i in 0..<20 { try write("settings/extra\(i).md", "unique setting \(i)") }
        let store = AIWorkIndexStore(root: root, generate: fake {})
        let result = try ensure(store)
        XCTAssertLessThan(store.persistenceCount, result.passages.count / 2)
        let reopened = AIWorkIndexStore(root: root)
        XCTAssertEqual(reopened.index.passages, result.passages)
    }

    func testUnfinishedCatalogUsesOriginalPreviewWithoutPretendingSummaryIsComplete() throws {
        let passage = try XCTUnwrap(AIWorkIndex.scan(context: context).passages.first)
        XCTAssertEqual(passage.catalogEntry["summaryKind"] as? String, "excerpt")
        XCTAssertEqual(passage.catalogEntry["summary"] as? String, passage.text)
        XCTAssertTrue(passage.summary.isEmpty)
    }

    func testSmallCorpusUsesOriginalsWithoutAnyRetrievalModelCalls() throws {
        let index = try AIWorkIndex.scan(context: context)
        let resolved = AIWorkContextResolver.resolve(context, currentFile: root.appendingPathComponent("chapters/02.md"))
        let passages = try index.eligible(for: resolved, includeOpenSettings: false)
        let retrieval = AIWorkRetrieval(generate: { _, _, _, _ in
            XCTFail("Small complete corpus needs no evidence-selection round trip")
            return {}
        })
        let ready = expectation(description: "direct evidence")
        retrieval.prepare(passages: passages, title: "t", currentEpisode: "02", document: "현재 화", question: "부활?", provider: .claude, model: nil) { result in
            do {
                let payload = try result.get()
                XCTAssertTrue(payload.settings.contains { $0.text.contains("부활은 불가능") })
                XCTAssertFalse(payload.retrievedPassages.contains { $0.text.contains("미래비밀") })
                XCTAssertEqual(retrieval.tokensUsed, 0)
            } catch { XCTFail("\(error)") }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
    }

    func testLargeCorpusPrimesFirstRetrievalWithRelevantOriginalBeyondFirstCatalogPage() throws {
        var passages = (0..<50).flatMap { AIWorkIndex.split(text: "무관한 자료 \($0)", path: "settings/\($0).md", isSetting: true) }
        let relevant = AIWorkIndex.split(text: "흑룡의 봉인은 달빛으로만 풀린다.", path: "settings/seal.md", isSetting: true)
        passages += relevant
        var calls = 0
        let retrieval = AIWorkRetrieval(generate: { prompt, _, _, completion in
            calls += 1
            do {
                let json = try XCTUnwrap(prompt.components(separatedBy: "INPUT:").last?.data(using: .utf8))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
                let evidence = try XCTUnwrap(object["readEvidence"] as? [[String: String]])
                XCTAssertTrue(evidence.contains { $0["text"] == relevant.first?.text })
            } catch { XCTFail("\(error)") }
            completion(.success("{\"done\":true}"), 5)
            return {}
        })
        let ready = expectation(description: "one retrieval round")
        retrieval.prepare(passages: passages, title: "t", currentEpisode: "02", document: "", question: "흑룡의 봉인을 풀려면?", provider: .claude, model: nil) { result in
            do {
                let payload = try result.get()
                XCTAssertEqual(payload.settings.first?.text, relevant.first?.text)
            } catch { XCTFail("\(error)") }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(calls, 1)
    }

    func testCancellingDuringLocalSearchDoesNotStartAProviderOrDeliverLateEvidence() throws {
        let unexpected = expectation(description: "cancelled retrieval must stay silent")
        unexpected.isInverted = true
        let retrieval = AIWorkRetrieval(generate: { _, _, _, _ in unexpected.fulfill(); return {} })
        retrieval.prepare(passages: try AIWorkIndex.scan(context: context).passages, title: "t", currentEpisode: "02",
                          document: "", question: "부활", provider: .claude, model: nil) { _ in unexpected.fulfill() }
        retrieval.cancel()
        wait(for: [unexpected], timeout: 0.2)
    }

    func testLocalSearchFindsLateSourceIn4312UnsummarizedPassages() {
        let filler = String(repeating: "세계의 평범한 기록이다. ", count: 40)
        var passages = (0..<4311).map { i in
            AIIndexedPassage(id: "\(i)", path: "settings/\(i).md", isSetting: true, firstLine: 1, lastLine: 1,
                             text: filler, contentHash: "\(i)", summary: "")
        }
        let target = AIIndexedPassage(id: "target", path: "settings/seal.md", isSetting: true, firstLine: 1, lastLine: 1,
                                     text: "은빛열쇠로 봉인을 연다.", contentHash: "target", summary: "")
        passages.append(target)
        let started = Date()
        let found = AIWorkRetrieval.localCandidates(passages: passages, question: "은빛열쇠의 역할은?", document: "")
        print("Synthetic 4312-passage local search: \(Date().timeIntervalSince(started)) seconds")
        XCTAssertEqual(found.first?.id, target.id, "Relevant source outside the first catalog page must be discoverable without summaries")
    }
}
