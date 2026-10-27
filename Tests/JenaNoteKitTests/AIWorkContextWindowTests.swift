import AppKit
import XCTest
@testable import JenaNoteKit

final class AIWorkContextWindowTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        AIWorkContextWindowController.resetRegistryForTesting()
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    /// 달빛도시/설정/인물.md, 달빛도시/집필/01화.md
    private func makeWork(name: String = "달빛도시") throws -> URL {
        let fm = FileManager.default
        let root = tmp.appendingPathComponent(name)
        try fm.createDirectory(at: root.appendingPathComponent("설정"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("집필"), withIntermediateDirectories: true)
        try "인물".write(to: root.appendingPathComponent("설정/인물.md"), atomically: true, encoding: .utf8)
        try "본문".write(to: root.appendingPathComponent("집필/01화.md"), atomically: true, encoding: .utf8)
        return root
    }

    private func saveContext(at root: URL) throws {
        let config = AIWorkContextConfig(title: "달빛도시", settingsSources: ["설정"], writingFolder: "집필")
        try AIWorkContext(rootURL: root, config: config, invalidPaths: []).save()
    }

    private func diskConfig(_ root: URL) throws -> AIWorkContextConfig {
        try AIWorkContext.load(rootURL: root).config
    }

    func testSharedReturnsSameControllerPerRoot() throws {
        let root = try makeWork()
        let other = try makeWork(name: "다른작품")
        try saveContext(at: root)
        let store = AIEpisodeSummaryStore(rootURL: root)
        let a = AIWorkContextWindowController.shared(for: root, store: store)
        let b = AIWorkContextWindowController.shared(for: root, store: store)
        XCTAssertTrue(a === b)
        let c = AIWorkContextWindowController.shared(for: other, store: AIEpisodeSummaryStore(rootURL: other))
        XCTAssertFalse(a === c)
        a.close()
        XCTAssertTrue(AIWorkContextWindowController.shared(for: root, store: store) === a)
    }

    func testMutateSavesImmediatelyAndNotifies() throws {
        let root = try makeWork()
        try saveContext(at: root)
        let controller = AIWorkContextWindowController.shared(for: root, store: AIEpisodeSummaryStore(rootURL: root))
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.mutate { $0.title = "새 제목" }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(try diskConfig(root).title, "새 제목")
        XCTAssertEqual(controller.context.config.title, "새 제목")
        XCTAssertEqual(controller.window?.title, String(format: L10n.tr("ai.work.window.title"), "새 제목"))
    }

    func testWindowReloadsConfigBeforeMutating() throws {
        let root = try makeWork()
        try saveContext(at: root)
        let controller = AIWorkContextWindowController.shared(for: root, store: AIEpisodeSummaryStore(rootURL: root))
        // Edited elsewhere (another window / by hand) after the controller loaded it.
        var external = try AIWorkContext.load(rootURL: root)
        external.config.excludedSettings = ["설정/인물.md"]
        try external.save()

        controller.mutate { $0.title = "바뀐 제목" }
        let disk = try diskConfig(root)
        XCTAssertEqual(disk.title, "바뀐 제목")
        XCTAssertEqual(disk.excludedSettings, ["설정/인물.md"])
        XCTAssertEqual(controller.context.config.excludedSettings, ["설정/인물.md"])
    }

    func testFirstSetupDoesNotWriteUntilValidChange() throws {
        let root = try makeWork()
        let file = root.appendingPathComponent("집필/01화.md")
        let jenanote = root.appendingPathComponent(AIWorkContext.folderName)
        let controller = AIWorkContextWindowController.forFirstSetup(
            fileURL: file, store: AIEpisodeSummaryStore(rootURL: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jenanote.path))
        XCTAssertTrue(controller.isProvisional)
        XCTAssertEqual(controller.selectedTab, .folders)
        // The suggested 설정 folder is already listed (spec §5.1 step 4).
        XCTAssertEqual(controller.context.config.settingsSources, ["설정"])
        XCTAssertEqual(controller.context.config.writingFolder, "집필")
        XCTAssertTrue(AIWorkContextWindowController.forFirstSetup(
            fileURL: file, store: AIEpisodeSummaryStore(rootURL: root)) === controller)

        try "세계".write(to: root.appendingPathComponent("세계관.md"), atomically: true, encoding: .utf8)
        var changes = 0
        controller.onChange = { changes += 1 }
        let workRoot = controller.context.rootURL
        try controller.mutate {
            try AIWorkContextModel.addingSource(workRoot.appendingPathComponent("세계관.md"), to: &$0, root: workRoot)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: jenanote.appendingPathComponent(AIWorkContext.fileName).path))
        XCTAssertFalse(controller.isProvisional)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(try diskConfig(root).settingsSources, ["설정", "세계관.md"])
        XCTAssertTrue(try diskConfig(root).enabled)
    }

    func testFoldersTabRejectsWritingFolderOutsideRoot() throws {
        let root = try makeWork()
        try saveContext(at: root)
        let outside = tmp.appendingPathComponent("밖")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let controller = AIWorkContextWindowController.shared(for: root, store: AIEpisodeSummaryStore(rootURL: root))
        var changes = 0
        controller.onChange = { changes += 1 }

        controller.foldersView.chooseWritingFolder(outside)
        XCTAssertFalse(controller.foldersView.errorLabel.stringValue.isEmpty)
        XCTAssertFalse(controller.foldersView.errorLabel.isHidden)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(try diskConfig(root).writingFolder, "집필")
        XCTAssertEqual(controller.context.config.writingFolder, "집필")
    }
}
