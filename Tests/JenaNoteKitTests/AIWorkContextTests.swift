import XCTest
@testable import JenaNoteKit

final class AIWorkContextTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    private func norm(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    /// 달빛도시/설정/인물.md, 달빛도시/집필/01화.md
    @discardableResult
    private func makeWork(at base: URL, settingsName: String = "설정") throws -> URL {
        let fm = FileManager.default
        let root = base.appendingPathComponent("달빛도시")
        try fm.createDirectory(at: root.appendingPathComponent(settingsName), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("집필"), withIntermediateDirectories: true)
        try "인물".write(to: root.appendingPathComponent(settingsName).appendingPathComponent("인물.md"), atomically: true, encoding: .utf8)
        try "본문".write(to: root.appendingPathComponent("집필").appendingPathComponent("01화.md"), atomically: true, encoding: .utf8)
        return root
    }

    private func config(sources: [String] = ["설정"]) -> AIWorkContextConfig {
        AIWorkContextConfig(title: "달빛도시", settingsSources: sources, writingFolder: "집필")
    }

    func testLocateFindsNearestContextWithinSixLevels() throws {
        let root = try makeWork(at: tmp)
        try AIWorkContext(rootURL: root, config: config(), invalidPaths: []).save()
        let fm = FileManager.default
        let deep = root.appendingPathComponent("집필/a/b/c/d/e")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        let found = AIWorkContext.locate(from: deep.appendingPathComponent("07화.md"))
        XCTAssertEqual(found.map { norm($0.rootURL) }, norm(root))

        let tooDeep = deep.appendingPathComponent("f")
        try fm.createDirectory(at: tooDeep, withIntermediateDirectories: true)
        XCTAssertNil(AIWorkContext.locate(from: tooDeep.appendingPathComponent("08화.md")))
    }

    func testLocateSkipsFilesInsideJenanoteFolder() throws {
        let root = try makeWork(at: tmp)
        try AIWorkContext(rootURL: root, config: config(), invalidPaths: []).save()
        let summaries = root.appendingPathComponent(".jenanote/summaries")
        try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)
        XCTAssertNil(AIWorkContext.locate(from: summaries.appendingPathComponent("01화.md.txt")))
    }

    func testLoadAndSaveRoundTrip() throws {
        let root = try makeWork(at: tmp)
        var cfg = config(sources: ["설정", "세계관.md"])
        cfg.excludedSettings = ["설정/초안.md"]
        cfg.summarizedSettings = ["설정/긴자료.md"]
        cfg.includePreviousEpisode = false
        cfg.enabled = false
        try AIWorkContext(rootURL: root, config: cfg, invalidPaths: []).save()
        let loaded = try AIWorkContext.load(rootURL: root)
        XCTAssertEqual(loaded.config, cfg)
        XCTAssertEqual(loaded.configURL.lastPathComponent, "context.json")
        XCTAssertTrue(loaded.invalidPaths.isEmpty)
    }

    func testRejectsEscapingPaths() throws {
        let root = try makeWork(at: tmp)
        try AIWorkContext(rootURL: root, config: config(sources: ["../other", "/etc", "설정"]), invalidPaths: []).save()
        let loaded = try AIWorkContext.load(rootURL: root)
        XCTAssertEqual(loaded.settingsSourceURLs.map(norm), [norm(root.appendingPathComponent("설정"))])
        XCTAssertEqual(loaded.invalidPaths, ["../other", "/etc"])
    }

    func testCorruptFileThrowsCorrupt() throws {
        let root = try makeWork(at: tmp)
        let dir = root.appendingPathComponent(".jenanote")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{not json".write(to: dir.appendingPathComponent("context.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AIWorkContext.load(rootURL: root)) { error in
            XCTAssertEqual(error as? AIWorkContextError, .corrupt)
        }
    }

    func testSuggestionFindsSettingsSiblingCaseInsensitive() throws {
        let root = try makeWork(at: tmp, settingsName: "Settings")
        let file = root.appendingPathComponent("집필/01화.md")
        let s = AIWorkContextSuggestion.make(for: file)
        XCTAssertEqual(norm(s.rootURL), norm(root))
        XCTAssertEqual(s.settingsSourceURL.map(norm), norm(root.appendingPathComponent("Settings")))
        XCTAssertEqual(norm(s.writingFolderURL), norm(root.appendingPathComponent("집필")))
        XCTAssertEqual(s.title, "달빛도시")
    }

    func testSuggestionWithoutSettingsFolderUsesParent() throws {
        let folder = tmp.appendingPathComponent("혼자쓰기")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let s = AIWorkContextSuggestion.make(for: folder.appendingPathComponent("a.md"))
        XCTAssertNil(s.settingsSourceURL)
        XCTAssertEqual(norm(s.rootURL), norm(folder))
        XCTAssertEqual(norm(s.writingFolderURL), norm(folder))
    }

    func testValidateRequiresSourcesInsideRoot() throws {
        let root = try makeWork(at: tmp)
        let inside = root.appendingPathComponent("설정")
        let outside = tmp.appendingPathComponent("other")
        let writing = root.appendingPathComponent("집필")
        XCTAssertEqual(AIWorkContext.validate(rootURL: root, settingsSources: [], writingFolder: writing), [.noSettingsSources])
        XCTAssertEqual(AIWorkContext.validate(rootURL: root, settingsSources: [inside], writingFolder: writing), [])
        let errors = AIWorkContext.validate(rootURL: root, settingsSources: [outside], writingFolder: outside)
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.contains(.settingsOutsideRoot(outside.path)))
        XCTAssertTrue(errors.contains(.writingFolderOutsideRoot))
    }

    func testContainsRejectsDotDotThroughSymlink() throws {
        let root = try makeWork(at: tmp)
        let outsideSub = tmp.appendingPathComponent("outside/sub")
        try FileManager.default.createDirectory(at: outsideSub, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("링크")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideSub)
        let ctx = AIWorkContext(rootURL: root, config: config(), invalidPaths: [])
        // root/링크/../설정 is /outside/설정 for the OS, not root/설정.
        let sneaky = URL(fileURLWithPath: root.path + "/링크/../설정")
        XCTAssertFalse(ctx.contains(sneaky))
        XCTAssertNil(AIWorkContext.relativePath(of: sneaky, to: root))
    }

    func testSuggestionResolvesSymlinkedParentForNewFile() throws {
        let real = tmp.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("설정"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("집필"), withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let s = AIWorkContextSuggestion.make(for: link.appendingPathComponent("집필/새글.md"))
        let ctx = AIWorkContext(rootURL: s.rootURL, config: config(), invalidPaths: [])
        XCTAssertEqual(s.rootURL.pathComponents.last, "real")
        XCTAssertTrue(ctx.contains(link.appendingPathComponent("집필/새글.md")))
    }

    func testContainsRejectsSymlinkEscape() throws {
        let root = try makeWork(at: tmp)
        let outside = tmp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("링크")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let ctx = AIWorkContext(rootURL: root, config: config(), invalidPaths: [])
        XCTAssertFalse(ctx.contains(link))
        XCTAssertFalse(ctx.contains(link.appendingPathComponent("x.md")))
        XCTAssertTrue(ctx.contains(root.appendingPathComponent("설정")))
    }
}
