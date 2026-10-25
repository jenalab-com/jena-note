import XCTest
@testable import JenaNoteKit

final class SidebarItemCreationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testNewDocumentIsEmptyMarkdownInSelectedDirectory() throws {
        let url = try SidebarItemCreation.create(named: "회의록", in: directory, isDirectory: false)
        XCTAssertEqual(url, directory.appendingPathComponent("회의록.md"))
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testMarkdownExtensionIsNotDuplicated() throws {
        let url = try SidebarItemCreation.create(named: "메모.MD", in: directory, isDirectory: false)
        XCTAssertEqual(url.lastPathComponent, "메모.MD")
    }

    func testExistingContentIsNeverOverwritten() throws {
        let url = directory.appendingPathComponent("메모.md")
        let original = Data("기존 내용".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try SidebarItemCreation.create(named: "메모", in: directory, isDirectory: false))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try SidebarItemCreation.create(named: "메모.md", in: directory, isDirectory: true))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFolderIsCreatedAndDuplicateIsRejected() throws {
        let url = try SidebarItemCreation.create(named: "자료", in: directory, isDirectory: true)
        XCTAssertTrue(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        XCTAssertThrowsError(try SidebarItemCreation.create(named: "자료", in: directory, isDirectory: true))
    }

    func testInvalidNamesCannotEscapeOrCreateHiddenItems() {
        for name in ["", "  ", ".", "..", "../outside", "child/file", "a:b", ".hidden", "a\0b"] {
            XCTAssertThrowsError(try SidebarItemCreation.create(named: name, in: directory, isDirectory: false), name)
        }
    }

    func testMissingParentIsNotSilentlyRecreated() {
        let missing = directory.appendingPathComponent("missing")
        XCTAssertThrowsError(try SidebarItemCreation.create(named: "note", in: missing, isDirectory: false))
        XCTAssertThrowsError(try SidebarItemCreation.create(named: "folder", in: missing, isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
