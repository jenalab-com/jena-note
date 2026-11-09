import XCTest
@testable import JenaNoteCore

final class AIWorkIndexCoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("work-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("설정"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("원고"), withIntermediateDirectories: true)
        try write("설정/인물.md", "리에느는 빵을 좋아한다.\n")
        try write("원고/1화.md", "첫째 화. 리에느가 도착했다.\n")
        try write("원고/2화.md", "둘째 화.\n")
        try write("원고/10화.md", "미래비밀 열째 화.\n")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        AIWorkContextResolver.openDocumentText = { _ in nil }
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func context() -> AIWorkContext {
        AIWorkContext(rootURL: root, config: AIWorkContextConfig(title: "작품", settingsSources: ["설정"], writingFolder: "원고"), invalidPaths: [])
    }

    func testEpisodesSortNaturallyAndOnlyEarlierOnesCount() {
        let resolved = AIWorkContextResolver.resolve(context(), currentFile: root.appendingPathComponent("원고/2화.md"))
        XCTAssertEqual(resolved.episodes.map(\.relativePath), ["1화.md", "2화.md", "10화.md"])
        XCTAssertEqual(resolved.previousEpisodes.map(\.relativePath), ["1화.md"])
        XCTAssertEqual(resolved.settings.map(\.relativePath), ["설정/인물.md"])
    }

    func testFutureEpisodesAreNeverEligible() throws {
        let index = try AIWorkIndex.scan(context: context())
        let resolved = AIWorkContextResolver.resolve(context(), currentFile: root.appendingPathComponent("원고/2화.md"))
        let eligible = try index.eligible(for: resolved)
        XCTAssertFalse(eligible.contains { $0.text.contains("미래비밀") })
        XCTAssertTrue(AIWorkIndex.search(["미래비밀"], in: eligible).isEmpty)
        XCTAssertFalse(AIWorkIndex.search(["미래비밀"], in: index.passages).isEmpty)
    }

    func testOpenDocumentWinsOverItsFile() throws {
        let target = root.appendingPathComponent("설정/인물.md").standardizedFileURL.path
        AIWorkContextResolver.openDocumentText = { $0.standardizedFileURL.path == target ? "열린 글\r\n" : nil }
        let resolved = AIWorkContextResolver.resolve(context(), currentFile: root.appendingPathComponent("원고/2화.md"))
        let eligible = try AIWorkIndex.scan(context: context()).eligible(for: resolved)
        XCTAssertEqual(eligible.first { $0.isSetting }?.text, "열린 글\n")
    }

    func testSplitKeepsEveryCharacterAndBounds() {
        let text = String(repeating: "가나다라마바사 ", count: 3000) + "\n끝\n"
        let chunks = AIWorkIndex.split(text: text, path: "a.md", isSetting: false)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.text.utf8.count <= AIWorkIndex.chunkBytes })
    }

    /// The passages are stored in a file a Mac shares, so their ids must not change with the method.
    func testSplitMatchesTheOriginalMethod() {
        func original(_ text: String) -> [(String, Int, Int)] {
            var result: [(String, Int, Int)] = []
            var buffer = "", first = 1, line = 1
            func flush() {
                guard !buffer.isEmpty else { return }
                result.append((buffer, first, line))
                buffer = ""
                first = line
            }
            var bytes = 0
            for scalar in text.unicodeScalars {
                let part = String(scalar)
                if bytes + part.utf8.count > AIWorkIndex.chunkBytes { flush(); bytes = 0 }
                buffer += part
                bytes += part.utf8.count
                if scalar == "\n" {
                    if bytes >= AIWorkIndex.chunkBytes / 2 { flush(); bytes = 0; first = line + 1 }
                    line += 1
                }
            }
            flush()
            return result
        }
        let samples = [
            "", "한 줄", "끝에 줄바꿈\n", "\n\n\n",
            String(repeating: "가나다 abc 😀\n", count: 900),
            String(repeating: "x", count: 10_000),
            String(repeating: "😀", count: 2_000) + "\n" + String(repeating: "é", count: 3_000),
            String(repeating: "짧은 줄\n", count: 50) + String(repeating: "긴", count: 1_000) + "\n마지막",
        ]
        for sample in samples {
            let chunks = AIWorkIndex.split(text: sample, path: "a.md", isSetting: false)
            let expected = original(sample)
            XCTAssertEqual(chunks.map(\.text), expected.map(\.0))
            XCTAssertEqual(chunks.map(\.firstLine), expected.map(\.1))
            XCTAssertEqual(chunks.map(\.lastLine), expected.map(\.2))
        }
        let known = AIWorkIndex.split(text: "가\n", path: "a.md", isSetting: true)[0]
        XCTAssertEqual(known.contentHash, AIWorkIndex.digest("가\n"))
        XCTAssertEqual(known.id, String(AIWorkIndex.digest("a.md:0:가\n").prefix(24)))
    }

    func testPathChecksGiveTheSameAnswersWhenRemembered() throws {
        let inside = root.appendingPathComponent("원고/1화.md")
        let missing = root.appendingPathComponent("없는 폴더/더 없는/파일.md")
        let outside = root.deletingLastPathComponent().appendingPathComponent("밖.md")
        let plain = [inside, missing, outside, root].map { AIWorkContext.relativePath(of: $0, to: root) }
        let remembered = AIWorkContext.withPathCache {
            [inside, missing, outside, root, inside].map { AIWorkContext.relativePath(of: $0, to: root) }
        }
        XCTAssertEqual(Array(remembered.prefix(4)), plain)
        XCTAssertEqual(remembered[4], plain[0])
        XCTAssertEqual(plain[0], "원고/1화.md")
        XCTAssertEqual(plain[1], "없는 폴더/더 없는/파일.md")
        XCTAssertNil(plain[2])
        XCTAssertEqual(plain[3], "")
    }

    func testRememberedPathChecksStayOnTheirThread() throws {
        let top: URL = root
        let file = top.appendingPathComponent("원고/1화.md")
        let expected = AIWorkContext.relativePath(of: file, to: top)
        let done = expectation(description: "other thread")
        var other: String?
        AIWorkContext.withPathCache {
            _ = AIWorkContextResolver.files(under: top.appendingPathComponent("원고"), recursive: true)
            let thread = Thread {
                other = AIWorkContext.relativePath(of: file, to: top)
                done.fulfill()
            }
            thread.start()
            wait(for: [done], timeout: 10)
        }
        XCTAssertEqual(other, expected)
    }

    func testScanCanReuseSplitPassages() throws {
        var asked: [String] = []
        let reused = try AIWorkIndex.scan(context: context()) { file, path, setting in
            asked.append(path)
            return AIWorkIndex.split(text: try AIWorkContextResolver.readText(file), path: path, isSetting: setting)
        }
        XCTAssertEqual(reused.passages, try AIWorkIndex.scan(context: context()).passages)
        XCTAssertEqual(asked.first, "설정/인물.md")
    }

    func testListingSkipsHiddenAndOtherFiles() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("원고/.숨김"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("원고/하위"), withIntermediateDirectories: true)
        try write("원고/.숨김/비밀.md", "x")
        try write("원고/.숨은.md", "x")
        try write("원고/그림.png", "x")
        try write("원고/하위/3화.markdown", "세 바이트")
        try write("원고/메모.txt", "x")
        let deep = AIWorkContextResolver.files(under: root.appendingPathComponent("원고"), recursive: true)
        XCTAssertEqual(Set(deep.map(\.relativePath)), ["1화.md", "2화.md", "10화.md", "메모.txt", "하위/3화.markdown"])
        XCTAssertEqual(deep.first { $0.relativePath == "메모.txt" }?.byteCount, 1)
        let shallow = AIWorkContextResolver.files(under: root.appendingPathComponent("원고"), recursive: false)
        XCTAssertFalse(shallow.contains { $0.relativePath.contains("하위") })
        XCTAssertTrue(AIWorkContextResolver.files(under: root.appendingPathComponent("없는 폴더"), recursive: true).isEmpty)
    }

    /// A link inside a work could lead anywhere, so listing never goes through one.
    func testListingDoesNotFollowLinks() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("밖".utf8).write(to: outside.appendingPathComponent("밖.md"))
        do {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("원고/링크"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("원고/링크.md"), withDestinationURL: outside.appendingPathComponent("밖.md"))
        } catch {
            throw XCTSkip("Creating links needs a permission this account does not have.")
        }
        let listed = AIWorkContextResolver.files(under: root.appendingPathComponent("원고"), recursive: true).map(\.relativePath)
        XCTAssertFalse(listed.contains { $0.contains("링크") }, "\(listed)")
    }

    #if os(Windows)
    func testListingSaysWhenAFileChanged() throws {
        let folder = root.appendingPathComponent("원고")
        func stamp() -> String? {
            AIWorkContextResolver.files(under: folder, recursive: false).first { $0.relativePath == "1화.md" }?.stamp
        }
        let first = try XCTUnwrap(stamp())
        XCTAssertEqual(stamp(), first)
        let file = try XCTUnwrap(AIWorkContextResolver.files(under: folder, recursive: false).first { $0.relativePath == "1화.md" })
        XCTAssertEqual(file.byteCount, try Data(contentsOf: file.url).count)
        XCTAssertEqual(try AIWorkContextResolver.readText(file), "첫째 화. 리에느가 도착했다.\n")
        try write("원고/1화.md", "바뀐 내용\n")
        let changed = try XCTUnwrap(AIWorkContextResolver.files(under: folder, recursive: false).first { $0.relativePath == "1화.md" })
        XCTAssertNotEqual(changed.stamp, first)
        XCTAssertEqual(try AIWorkContextResolver.readText(changed), "바뀐 내용\n")
    }

    func testAPlainFileUsesTheListingForSafetyChecks() throws {
        let file = root.appendingPathComponent("원고/1화.md")
        XCTAssertTrue(AIWorkContext.isSafeInsideRoot(file, root: root))
        let inCache = AIWorkContext.withPathCache { () -> Bool in
            _ = AIWorkContextResolver.files(under: root.appendingPathComponent("원고"), recursive: true)
            return AIWorkContext.isSafeInsideRoot(file, root: root) && AIWorkContext.relativePath(of: file, to: root) == "원고/1화.md"
        }
        XCTAssertTrue(inCache)
        XCTAssertFalse(AIWorkContext.withPathCache { AIWorkContext.isSafeInsideRoot(root.deletingLastPathComponent().appendingPathComponent("밖.md"), root: root) })
    }
    #endif

    func testAChangedSettingsFileIsReadAgain() throws {
        var index = try AIWorkIndex.scan(context: context())
        let resolved = AIWorkContextResolver.resolve(context(), currentFile: root.appendingPathComponent("원고/2화.md"))
        XCTAssertEqual(try index.eligible(for: resolved).first { $0.isSetting }?.text, "리에느는 빵을 좋아한다.\n")
        try write("설정/인물.md", "리에느는 비를 싫어한다.\n")
        index = try AIWorkIndex.scan(context: context())
        XCTAssertEqual(try index.eligible(for: resolved).first { $0.isSetting }?.text, "리에느는 비를 싫어한다.\n")
    }

    func testNaturalOrder() {
        func sorted(_ names: [String]) -> [String] {
            let files = names.map { AIWorkFile(relativePath: $0, url: URL(fileURLWithPath: "/" + $0), byteCount: 0) }
            return AIWorkContextResolver.naturalSort(files).map(\.relativePath)
        }
        XCTAssertEqual(sorted(["10화.md", "2화.md", "1화.md"]), ["1화.md", "2화.md", "10화.md"])
        XCTAssertEqual(sorted(["002화_가.md", "001화_나.md", "010화_다.md"]), ["001화_나.md", "002화_가.md", "010화_다.md"])
        XCTAssertEqual(sorted(["원고/2화.md", "원고/10화.md", "설정/인물.md"]), ["설정/인물.md", "원고/2화.md", "원고/10화.md"])
        XCTAssertEqual(sorted(["b.md", "A.md", "c.md"]), ["A.md", "b.md", "c.md"])
        XCTAssertEqual(sorted(["가.md", "b.md", "1.md"]), ["1.md", "b.md", "가.md"])
        XCTAssertEqual(sorted(["1화 끝.md", "1화.md"]), ["1화 끝.md", "1화.md"])
        XCTAssertEqual(sorted(["99999999999999999999.md", "100000000000000000000.md"]), ["99999999999999999999.md", "100000000000000000000.md"])
    }

    func testNormalizingCarriageReturns() {
        XCTAssertEqual(AIWorkContextResolver.normalize("a\r\nb\rc\n"), "a\nb\nc\n")
        XCTAssertEqual(AIWorkContextResolver.normalize("그대로\n"), "그대로\n")
    }

    func testSearchScoresAndFolds() {
        let make = { (path: String, text: String, summary: String) in
            AIIndexedPassage(id: path, path: path, isSetting: false, firstLine: 1, lastLine: 1, text: text, contentHash: path, summary: summary)
        }
        let passages = [make("a.md", "Rina LOVES bread", ""), make("rina.md", "다른 글", ""), make("c.md", "없음", "rina in summary"), make("d.md", "관계없는 글", "")]
        XCTAssertEqual(AIWorkIndex.search(["rina"], in: passages).map(\.path), ["rina.md", "c.md", "a.md"], "Path, then summary, then text")
        XCTAssertEqual(AIWorkIndex.search(["BREAD"], in: passages).map(\.path), ["a.md"])
        XCTAssertEqual(AIWorkIndex.search(["  bread  "], in: passages).map(\.path), ["a.md"])
        XCTAssertTrue(AIWorkIndex.search(["", "   "], in: passages).isEmpty)
        XCTAssertEqual(AIWorkIndex.search(["글"], in: passages, limit: 1).count, 1)
        // A file saved on a Mac can hold Korean in decomposed form.
        let decomposed = make("n.md", "빵".decomposedStringWithCanonicalMapping, "")
        XCTAssertEqual(AIWorkIndex.search(["빵"], in: [decomposed]).map(\.path), ["n.md"])
        XCTAssertEqual(AIWorkIndex.search(["빵".decomposedStringWithCanonicalMapping], in: [make("m.md", "빵", "")]).map(\.path), ["m.md"])
    }

    func testSummariesCarryOverAndExcerptsCanBeRedone() throws {
        var saved = try AIWorkIndex.scan(context: context())
        for i in saved.passages.indices {
            saved.passages[i].summary = "요약 \(i)"
            saved.passages[i].summaryOrigin = i == 0 ? .excerpt : .apple
        }
        var fresh = try AIWorkIndex.scan(context: context())
        fresh.restoreSummaries(from: saved)
        XCTAssertTrue(fresh.passages.allSatisfy { !$0.summary.isEmpty })
        var redone = try AIWorkIndex.scan(context: context())
        redone.restoreSummaries(from: saved, retryExcerpts: true)
        XCTAssertTrue(redone.passages[0].summary.isEmpty)
        XCTAssertFalse(redone.passages[1].summary.isEmpty)
    }

    func testIndexFileRoundTrips() throws {
        var index = try AIWorkIndex.scan(context: context())
        index.summaryAvailability = "excerpt-v1:x"
        let decoded = try JSONDecoder().decode(AIWorkIndex.self, from: JSONEncoder().encode(index))
        XCTAssertEqual(decoded.passages, index.passages)
        XCTAssertEqual(decoded.version, AIWorkIndex.version)
    }

    // MARK: - Evidence search

    private func passages(_ count: Int) -> [AIIndexedPassage] {
        (0..<count).flatMap { AIWorkIndex.split(text: "조각 \($0) " + String(repeating: "내용 ", count: 400), path: "원고/\($0).md", isSetting: false) }
    }

    func testSmallWorkIsReadWhole() throws {
        let session = AIWorkRetrievalSession(passages: passages(3), title: "t", currentEpisode: "c", document: "d", question: "q")
        guard case .finished(let payload) = try session.start() else { return XCTFail("should not ask") }
        XCTAssertEqual(payload.retrievedPassages.count, passages(3).count)
        XCTAssertEqual(session.consulted.count, passages(3).count)
        XCTAssertTrue(payload.retrievalNote?.contains("do not claim an exhaustive review") == true)
    }

    func testLargeWorkAsksAndReadsOnlyWhatExists() throws {
        let all = passages(60)
        let session = AIWorkRetrievalSession(passages: all, title: "t", currentEpisode: "c", document: "d", question: "q")
        guard case .ask(let first) = try session.start() else { return XCTFail("should ask") }
        XCTAssertTrue(first.hasPrefix("Select source evidence"))
        XCTAssertTrue(first.contains("\"roundsLeft\":4"))
        let answer = "{\"reads\":[\"\(all[10].id)\",\"없는 조각\"],\"done\":true}"
        guard case .finished(let payload) = try session.receive(answer: answer) else { return XCTFail("should finish") }
        XCTAssertTrue(payload.retrievedPassages.contains { $0.name == all[10].citation })
        XCTAssertTrue(payload.retrievalNote?.contains("Search budget reached") == true)
    }

    func testRoundsAreLimited() throws {
        let session = AIWorkRetrievalSession(passages: passages(60), title: "t", currentEpisode: "c", document: "d", question: "q")
        var step = try session.start()
        var asked = 0
        while case .ask = step {
            asked += 1
            step = try session.receive(answer: "{\"queries\":[\"내용\"]}")
        }
        XCTAssertEqual(asked, AIWorkRetrievalSession.maximumRounds)
    }

    func testBadCommandsAreRefused() {
        XCTAssertThrowsError(try AIWorkRetrievalSession.decode("{}"))
        XCTAssertThrowsError(try AIWorkRetrievalSession.decode("rm -rf /"))
        XCTAssertNoThrow(try AIWorkRetrievalSession.decode("```json\n{\"done\":true}\n```"))
        XCTAssertTrue(AIWorkRetrievalSession.page(-1, passages: passages(2)).isEmpty)
        XCTAssertTrue(AIWorkRetrievalSession.page(Int.max, passages: passages(2)).isEmpty)
    }

    func testPromptTrimsEvidenceToFit() throws {
        var work = AIWorkPayload(title: "t", currentEpisode: "c", settings: [], previousSummaries: [])
        work.retrievalNote = "note"
        work.retrievedPassages = (0..<400).map { AIWorkEpisodeText(name: "\($0)", text: String(repeating: "x", count: 2400)) }
        let prompt = try AIWorkPrompt.make(document: "본문", selectedText: "", messages: [], request: "질문", mode: .guide, work: work)
        XCTAssertLessThanOrEqual(prompt.utf8.count, AIWorkPrompt.maximumBytes)
        XCTAssertTrue(prompt.contains("Evidence was reduced"))
        XCTAssertTrue(prompt.contains("work.settings is the canonical"))
    }

    // MARK: - Editing

    func testEditingSources() throws {
        var config = AIWorkContextConfig(title: "t", settingsSources: [], writingFolder: "", enabled: false)
        try AIWorkContextEdits.addingSource(root.appendingPathComponent("설정"), to: &config, root: root)
        XCTAssertEqual(config.settingsSources, ["설정"])
        XCTAssertTrue(config.enabled, "The first source turns a work on")
        AIWorkContextEdits.removingSource("설정", from: &config)
        XCTAssertFalse(config.enabled)
        config.disabledByUser = true
        try AIWorkContextEdits.addingSource(root.appendingPathComponent("설정"), to: &config, root: root)
        XCTAssertFalse(config.enabled, "A work switched off by hand stays off")
        XCTAssertThrowsError(try AIWorkContextEdits.addingSource(root, to: &config, root: root))
        AIWorkContextEdits.toggleIncluded(&config, path: "a")
        XCTAssertEqual(config.excludedSettings, ["a"])
        AIWorkContextEdits.toggleIncluded(&config, path: "a")
        XCTAssertEqual(config.excludedSettings, [])
    }

    func testRebasingMovesPathsToTheNewRoot() {
        let inner = root.appendingPathComponent("원고")
        XCTAssertEqual(AIWorkContextEdits.rebase("원고/a", from: root, to: inner), "a")
        XCTAssertEqual(AIWorkContextEdits.rebase("../x", from: root, to: inner), "../x")
    }

    #if os(Windows)
    func testDrivePathsAreNotRelative() {
        XCTAssertEqual(AIWorkContextEdits.rebase("C:/x/y", from: root, to: root.appendingPathComponent("원고")), "C:/x/y")
        var config = AIWorkContextConfig(title: "t", settingsSources: ["C:/x", "설정"], writingFolder: "D:/y")
        let context = AIWorkContextEdits.withInvalidPaths(AIWorkContext(rootURL: root, config: config, invalidPaths: []))
        XCTAssertEqual(context.settingsSourceURLs.count, 1)
        XCTAssertNil(context.writingFolderURL)
        XCTAssertTrue(context.invalidPaths.contains("C:/x"))
        config.writingFolder = ""
        XCTAssertEqual(AIWorkContext(rootURL: root, config: config, invalidPaths: []).writingFolderURL, root)
    }
    #endif
}
