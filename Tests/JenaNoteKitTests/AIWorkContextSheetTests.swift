import XCTest
@testable import JenaNoteKit

final class AIWorkContextSheetTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    private func norm(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    private func makeWork(withSettings: Bool) throws -> (root: URL, file: URL) {
        let fm = FileManager.default
        let root = tmp.appendingPathComponent("달빛도시")
        if withSettings { try fm.createDirectory(at: root.appendingPathComponent("설정"), withIntermediateDirectories: true) }
        try fm.createDirectory(at: root.appendingPathComponent("집필"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("집필/01화.md")
        try "본문".write(to: file, atomically: true, encoding: .utf8)
        return (root, file)
    }

    func testDraftFromSuggestionPrefillsSettingsSibling() throws {
        let (root, file) = try makeWork(withSettings: true)
        let draft = AIWorkContextSheetController.draft(fileURL: file, existing: nil)
        XCTAssertEqual(norm(draft.rootURL), norm(root))
        XCTAssertEqual(draft.settingsSources.map { norm($0) }, [norm(root.appendingPathComponent("설정"))])
        XCTAssertEqual(norm(draft.writingFolder), norm(root.appendingPathComponent("집필")))
        XCTAssertTrue(draft.errors.isEmpty)
        XCTAssertTrue(draft.canSave)
    }

    func testDraftWithoutSettingsCannotSave() throws {
        let (_, file) = try makeWork(withSettings: false)
        let draft = AIWorkContextSheetController.draft(fileURL: file, existing: nil)
        XCTAssertEqual(draft.errors, [.noSettingsSources])
        XCTAssertFalse(draft.canSave)
    }

    func testDraftFromExistingContextUsesSavedValues() throws {
        let (root, file) = try makeWork(withSettings: true)
        let config = AIWorkContextConfig(title: "저장된 제목", settingsSources: ["설정"], writingFolder: "집필")
        let existing = AIWorkContext(rootURL: root, config: config, invalidPaths: [])
        let draft = AIWorkContextSheetController.draft(fileURL: file, existing: existing)
        XCTAssertEqual(draft.title, "저장된 제목")
        XCTAssertEqual(norm(draft.rootURL), norm(root))
        XCTAssertEqual(draft.settingsSources.map { norm($0) }, [norm(root.appendingPathComponent("설정"))])
        XCTAssertEqual(norm(draft.writingFolder), norm(root.appendingPathComponent("집필")))
        XCTAssertTrue(draft.canSave)
    }

    func testMakeConfigProducesRelativePaths() throws {
        let (root, file) = try makeWork(withSettings: true)
        var base = AIWorkContextConfig(title: "x", settingsSources: ["설정"], writingFolder: "집필")
        base.excludedSettings = ["설정/제외.md"]
        base.summarizedSettings = ["설정/요약.md"]
        base.includePreviousEpisode = false
        base.enabled = false
        let existing = AIWorkContext(rootURL: root, config: base, invalidPaths: [])
        var draft = AIWorkContextSheetController.draft(fileURL: file, existing: existing)
        draft.title = "새 제목"
        let config = draft.makeConfig()
        XCTAssertEqual(config.settingsSources, ["설정"])
        XCTAssertEqual(config.writingFolder, "집필")
        XCTAssertEqual(config.title, "새 제목")
        XCTAssertEqual(config.excludedSettings, ["설정/제외.md"])
        XCTAssertEqual(config.summarizedSettings, ["설정/요약.md"])
        XCTAssertFalse(config.includePreviousEpisode)
        XCTAssertFalse(config.enabled)
    }
}
