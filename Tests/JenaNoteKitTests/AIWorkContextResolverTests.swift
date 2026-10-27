import XCTest
import AppKit
@testable import JenaNoteKit

final class AIWorkContextResolverTests: XCTestCase {
    private var tmp: URL!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = tmp.appendingPathComponent("작품")
        for (path, text) in [
            ("설정/세계관.md", "세계"), ("설정/인물/하연.md", "하연"), ("설정/인물/.숨김.md", "숨김"),
            ("설정/표지.png", "png"), ("집필/1부/01화.md", "1"), ("집필/1부/02화.md", "2"),
            ("집필/1부/10화.md", "10"), ("집필/2부/01화.md", "3"), ("집필/메모.txt", "메모"),
        ] { try write(path, text) }
    }

    override func tearDownWithError() throws {
        AIWorkContextResolver.openDocuments = {
            NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
        }
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func context(sources: [String] = ["설정"], excluded: [String] = [], includePrev: Bool = true) -> AIWorkContext {
        var cfg = AIWorkContextConfig(title: "작품", settingsSources: sources, writingFolder: "집필")
        cfg.excludedSettings = excluded
        cfg.includePreviousEpisode = includePrev
        return AIWorkContext(rootURL: root, config: cfg, invalidPaths: [])
    }

    private func paths(_ files: [AIWorkFile]) -> [String] { files.map(\.relativePath) }
    private func file(_ path: String) -> URL { root.appendingPathComponent(path) }

    func testEpisodesSortedByRelativePathNaturally() {
        let r = AIWorkContextResolver.resolve(context(), currentFile: file("집필/1부/01화.md"))
        XCTAssertEqual(paths(r.episodes), ["1부/01화.md", "1부/02화.md", "1부/10화.md", "2부/01화.md", "메모.txt"])
    }

    func testPreviousEpisodesStopBeforeCurrent() {
        let r = AIWorkContextResolver.resolve(context(), currentFile: file("집필/1부/10화.md"))
        XCTAssertEqual(paths(r.previousEpisodes), ["1부/01화.md", "1부/02화.md"])
        XCTAssertEqual(r.previousEpisode?.relativePath, "1부/02화.md")
    }

    func testFirstEpisodeHasNoPrevious() {
        let r = AIWorkContextResolver.resolve(context(), currentFile: file("집필/1부/01화.md"))
        XCTAssertEqual(r.previousEpisodes, [])
        XCTAssertNil(r.previousEpisode)
    }

    func testIncludePreviousEpisodeFalseDropsFullText() {
        let r = AIWorkContextResolver.resolve(context(includePrev: false), currentFile: file("집필/1부/10화.md"))
        XCTAssertNil(r.previousEpisode)
        XCTAssertEqual(r.previousEpisodes.count, 2)
    }

    func testSettingsRecursiveSkipHiddenAndNonText() {
        let r = AIWorkContextResolver.resolve(context(), currentFile: file("집필/1부/01화.md"))
        XCTAssertEqual(paths(r.settings), ["설정/세계관.md", "설정/인물/하연.md"])
    }

    func testExcludedSettingsSplitOut() {
        let r = AIWorkContextResolver.resolve(context(excluded: ["설정/인물/하연.md"]), currentFile: file("집필/1부/01화.md"))
        XCTAssertEqual(paths(r.settings), ["설정/세계관.md"])
        XCTAssertEqual(paths(r.excludedSettings), ["설정/인물/하연.md"])
    }

    func testSettingsFileSourceIsSingleFile() {
        let r = AIWorkContextResolver.resolve(context(sources: ["설정/세계관.md"]), currentFile: file("집필/1부/01화.md"))
        XCTAssertEqual(paths(r.settings), ["설정/세계관.md"])
    }

    func testCurrentFileOutsideWritingFolder() {
        let r = AIWorkContextResolver.resolve(context(), currentFile: file("설정/세계관.md"))
        XCTAssertNil(r.currentIndex)
        XCTAssertTrue(r.isOutsideWritingFolder)
        XCTAssertEqual(r.previousEpisodes, [])
    }

    func testUnreadableFileIsSkipped() throws {
        try Data([0xFF, 0xFE, 0x80]).write(to: file("설정/깨짐.md"))
        let r = AIWorkContextResolver.resolve(context(), currentFile: file("집필/1부/01화.md"))
        XCTAssertEqual(paths(r.unreadable), ["설정/깨짐.md"])
        XCTAssertFalse(paths(r.settings).contains("설정/깨짐.md"))
    }

    func testSymlinkInWritingFolderIgnored() throws {
        let outside = tmp.appendingPathComponent("밖.md")
        try "밖".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file("집필/링크.md"), withDestinationURL: outside)
        let r = AIWorkContextResolver.resolve(context(), currentFile: file("집필/1부/01화.md"))
        XCTAssertFalse(paths(r.episodes).contains("링크.md"))
    }

    func testReadTextNormalizesCRLF() throws {
        try write("집필/crlf.md", "a\r\nb")
        let f = AIWorkFile(relativePath: "crlf.md", url: file("집필/crlf.md"), byteCount: 4)
        XCTAssertEqual(try AIWorkContextResolver.readText(f), "a\nb")
    }

    func testReadSettingTextPrefersOpenDocument() throws {
        let doc = MarkdownDocument()
        doc.fileURL = file("설정/세계관.md")
        doc.content = NSMutableAttributedString(string: "메모리")
        AIWorkContextResolver.openDocuments = { [doc] }
        let f = AIWorkFile(relativePath: "설정/세계관.md", url: file("설정/세계관.md"), byteCount: 6)
        XCTAssertEqual(try AIWorkContextResolver.readSettingText(f), "메모리")
    }
}
