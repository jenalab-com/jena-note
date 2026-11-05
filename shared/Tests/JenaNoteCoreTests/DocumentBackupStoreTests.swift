import XCTest
@testable import JenaNoteCore

final class DocumentBackupStoreTests: XCTestCase {
    func testNamedVersionsShareObjectsAndSurvivePruning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentBackupStore(directory: root, limit: 1)
        let source = root.appendingPathComponent("draft.md")
        try store.record(Data("one".utf8), for: source, now: Date(timeIntervalSince1970: 1))
        let first = try XCTUnwrap(store.snapshots(for: source).first)
        try store.record(Data("one".utf8), for: source, name: "First draft", now: Date(timeIntervalSince1970: 2))
        let named = try XCTUnwrap(store.snapshots(for: source).first)
        XCTAssertEqual(named.parentID, first.id)
        try store.record(Data("two".utf8), for: source, now: Date(timeIntervalSince1970: 3))
        let entries = try store.snapshots(for: source)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.parentID, named.id)
        XCTAssertEqual(entries.last?.name, "First draft")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("objects").path).count, 2)
        let reopened = DocumentBackupStore(directory: root, limit: 1)
        XCTAssertEqual(try reopened.snapshots(for: source).map(\.id), entries.map(\.id))
        try reopened.record(Data("two".utf8), for: source, force: true, now: Date(timeIntervalSince1970: 4))
        XCTAssertNotEqual(try reopened.snapshots(for: source).first?.id, entries.first?.id)
    }

    func testHistoryFollowsRenamedFile() throws {
        #if !canImport(Darwin)
        try XCTSkipIf(true, "Windows Foundation has no URL bookmarks")
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("draft.md")
        let moved = root.appendingPathComponent("renamed.md")
        try Data("body".utf8).write(to: source)
        let store = DocumentBackupStore(directory: root.appendingPathComponent("history"))
        try store.record(Data("body".utf8), for: source, name: "Saved")
        let original = try XCTUnwrap(store.snapshots(for: source).first)
        try FileManager.default.moveItem(at: source, to: moved)
        let entry = try XCTUnwrap(store.snapshots(for: moved).first)
        XCTAssertEqual(entry.id, original.id)
        XCTAssertEqual(entry.source, moved.standardizedFileURL.path)
    }

    func testLegacyBackupMigrationAndCorruptObjectDetection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("draft.md")
        let hash = ContentDigest.sha256(Data(source.standardizedFileURL.path.utf8))
        let legacy = root.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let snapshot = DocumentBackupStore.Snapshot(id: UUID(), source: source.standardizedFileURL.path, createdAt: .distantPast, data: Data("old".utf8))
        try JSONEncoder().encode(snapshot).write(to: legacy.appendingPathComponent(snapshot.id.uuidString + ".json"))
        let store = DocumentBackupStore(directory: root)
        XCTAssertEqual(try store.snapshots(for: source).first?.id, snapshot.id)
        try store.record(Data("new".utf8), for: source)
        let object = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("objects"), includingPropertiesForKeys: nil).first)
        try Data("damaged".utf8).write(to: object)
        XCTAssertThrowsError(try store.snapshots(for: source))
    }
}
