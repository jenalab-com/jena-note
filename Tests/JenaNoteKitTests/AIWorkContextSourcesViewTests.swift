import AppKit
import XCTest
@testable import JenaNoteKit

final class AIWorkContextSourcesViewTests: XCTestCase {
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

    /// 작품/설정/{가.md 100B, 나.md 3000B, 다.md 1000B}, 작품/집필/01화.md, context.json (sources: 설정).
    private func makeWork(sources: [String] = ["설정"]) throws -> URL {
        let fm = FileManager.default
        let root = tmp.appendingPathComponent("작품")
        try fm.createDirectory(at: root.appendingPathComponent("설정"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("집필"), withIntermediateDirectories: true)
        for (name, size) in [("가.md", 100), ("나.md", 3000), ("다.md", 1000)] {
            try String(repeating: "a", count: size)
                .write(to: root.appendingPathComponent("설정/\(name)"), atomically: true, encoding: .utf8)
        }
        try "본문".write(to: root.appendingPathComponent("집필/01화.md"), atomically: true, encoding: .utf8)
        let config = AIWorkContextConfig(title: "작품", settingsSources: sources, writingFolder: "집필")
        try AIWorkContext(rootURL: root, config: config, invalidPaths: []).save()
        return root
    }

    private func open(_ root: URL) -> (AIWorkContextWindowController, AIWorkContextSourcesView) {
        let controller = AIWorkContextWindowController.shared(for: root, store: AIEpisodeSummaryStore(rootURL: root))
        guard let view = controller.sourcesView as? AIWorkContextSourcesView else {
            XCTFail("sources tab is not AIWorkContextSourcesView")
            return (controller, AIWorkContextSourcesView(controller: controller))
        }
        return (controller, view)
    }

    private func diskConfig(_ root: URL) throws -> AIWorkContextConfig {
        try AIWorkContext.load(rootURL: root).config
    }

    func testRenderListsSourcesAndFilesSortedBySize() throws {
        let root = try makeWork()
        let (_, view) = open(root)
        XCTAssertEqual(view.sourceRowViews.count, 1)
        XCTAssertTrue(view.emptyLabel.isHidden)
        XCTAssertEqual(view.sort, .sizeDescending)
        XCTAssertEqual(view.shownRows.map(\.file.relativePath), ["설정/나.md", "설정/다.md", "설정/가.md"])
        XCTAssertEqual(view.fileRowViews.count, 3)
        XCTAssertEqual(view.tableView.numberOfRows, 3)
        XCTAssertEqual(view.filesHeaderLabel.stringValue, String(format: L10n.tr("ai.work.sources.filesHeader"), 3))

        view.setSort(.name)
        XCTAssertEqual(view.shownRows.map(\.file.relativePath), ["설정/가.md", "설정/나.md", "설정/다.md"])
        XCTAssertEqual(view.sortControl.selectedSegment, 1)
    }

    func testToggleIncludeUpdatesBarAndFactImmediately() throws {
        let root = try makeWork()
        let (controller, view) = open(root)
        let factBefore = view.factLabel.stringValue
        let settingsFractionBefore = view.budgetBar.fractions[0]
        XCTAssertGreaterThan(settingsFractionBefore, 0)

        view.toggleInclude(row: 0)   // 나.md, the largest

        XCTAssertEqual(try diskConfig(root).excludedSettings, ["설정/나.md"])
        XCTAssertEqual(controller.context.config.excludedSettings, ["설정/나.md"])
        XCTAssertNotEqual(view.factLabel.stringValue, factBefore)
        XCTAssertLessThan(view.budgetBar.fractions[0], settingsFractionBefore)
        XCTAssertEqual(view.shownRows.first?.included, false)
        XCTAssertEqual(view.filesHeaderLabel.stringValue, String(format: L10n.tr("ai.work.sources.filesHeader"), 2))

        view.toggleInclude(row: 0)
        XCTAssertEqual(try diskConfig(root).excludedSettings, [])
        XCTAssertEqual(view.factLabel.stringValue, factBefore)
    }

    func testSummarySegmentUpdatesSummarizedSettings() throws {
        let root = try makeWork()
        let (_, view) = open(root)
        view.setSummarized(row: 1, true)   // 다.md
        XCTAssertEqual(try diskConfig(root).summarizedSettings, ["설정/다.md"])
        XCTAssertEqual(view.shownRows[1].summarized, true)

        view.setSummarized(row: 1, false)
        XCTAssertEqual(try diskConfig(root).summarizedSettings, [])
        XCTAssertEqual(view.shownRows[1].summarized, false)
    }

    func testAddFolderOutsideRootShowsErrorAndDoesNotSave() throws {
        let root = try makeWork()
        let outside = tmp.appendingPathComponent("밖")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let (controller, view) = open(root)
        var changes = 0
        controller.onChange = { changes += 1 }
        XCTAssertTrue(view.errorLabel.isHidden)

        view.addSource(url: outside)
        XCTAssertFalse(view.errorLabel.isHidden)
        XCTAssertFalse(view.errorLabel.stringValue.isEmpty)
        XCTAssertEqual(try diskConfig(root).settingsSources, ["설정"])
        XCTAssertEqual(changes, 0)

        view.addSource(url: controller.context.rootURL)
        XCTAssertEqual(view.errorLabel.stringValue, L10n.tr("ai.work.errorSourceIsRoot"))
        XCTAssertEqual(try diskConfig(root).settingsSources, ["설정"])
        XCTAssertEqual(changes, 0)

        // An accepted pick clears the error and is saved.
        let world = controller.context.rootURL.appendingPathComponent("세계관.md")
        try "세계".write(to: world, atomically: true, encoding: .utf8)
        view.addSource(url: world)
        XCTAssertTrue(view.errorLabel.isHidden)
        XCTAssertEqual(try diskConfig(root).settingsSources, ["설정", "세계관.md"])
        XCTAssertEqual(view.sourceRowViews.count, 2)
        XCTAssertEqual(changes, 1)
    }

    func testEmptySourcesShowsPlaceholderAndDisablesList() throws {
        let root = try makeWork()
        let (_, view) = open(root)
        XCTAssertTrue(view.tableView.isEnabled)

        view.removeSource("설정")

        XCTAssertEqual(try diskConfig(root).settingsSources, [])
        XCTAssertFalse(try diskConfig(root).enabled)
        XCTAssertFalse(view.emptyLabel.isHidden)
        XCTAssertEqual(view.emptyLabel.stringValue, L10n.tr("ai.work.sources.empty"))
        XCTAssertTrue(view.sourcesStack.isHidden)
        XCTAssertTrue(view.sourceRowViews.isEmpty)
        XCTAssertFalse(view.tableView.isEnabled)
        XCTAssertEqual(view.tableView.numberOfRows, 0)
    }
}
