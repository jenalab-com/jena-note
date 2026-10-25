import XCTest
@testable import JenaNoteKit

final class SidebarItemOperationsTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testRenamePreservesContentAndMarkdownExtension() throws {
        let original = try SidebarItemCreation.create(named: "old", in: directory, isDirectory: false)
        try Data("본문".utf8).write(to: original)
        let renamed = try SidebarItemOperations.rename(original, to: "new")
        XCTAssertEqual(renamed.lastPathComponent, "new.md")
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "본문")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testDuplicateRenamePreservesBothFiles() throws {
        let first = try SidebarItemCreation.create(named: "first", in: directory, isDirectory: false)
        let second = try SidebarItemCreation.create(named: "second", in: directory, isDirectory: false)
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        XCTAssertThrowsError(try SidebarItemOperations.rename(first, to: "second"))
        XCTAssertEqual(try String(contentsOf: first), "first")
        XCTAssertEqual(try String(contentsOf: second), "second")
    }

    func testFolderRenamePreservesDescendants() throws {
        let folder = try SidebarItemCreation.create(named: "old", in: directory, isDirectory: true)
        let file = try SidebarItemCreation.create(named: "note", in: folder, isDirectory: false)
        let renamed = try SidebarItemOperations.rename(folder, to: "new")
        let relocated = try XCTUnwrap(SidebarItemOperations.relocatedURL(file, from: folder, to: renamed))
        XCTAssertEqual(relocated, renamed.appendingPathComponent("note.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: relocated.path))
        XCTAssertNil(SidebarItemOperations.relocatedURL(directory.appendingPathComponent("old-other/note.md"), from: folder, to: renamed))
    }

    func testInvalidRenameLeavesSourceIntact() throws {
        let file = try SidebarItemCreation.create(named: "note", in: directory, isDirectory: false)
        for name in ["", "..", "../escape", "a/b", "a:b", "a\0b"] {
            XCTAssertThrowsError(try SidebarItemOperations.rename(file, to: name))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertEqual(try SidebarItemOperations.rename(file, to: "note.md"), file)
    }
}
