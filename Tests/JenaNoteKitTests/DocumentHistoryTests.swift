import Foundation
import AppKit
import CryptoKit
import XCTest
@testable import JenaNoteKit

final class DocumentHistoryTests: XCTestCase {
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
        let hash = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
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

    func testAlignedComparisonPreservesLineNumbersAndClassifiesChanges() throws {
        let rows = try XCTUnwrap(DocumentHistoryDiff.rows(previous: "start\nold\nend", current: "start\nnew\nextra\nend"))
        XCTAssertEqual(rows.map(\.kind), [.unchanged, .modified, .added, .unchanged])
        XCTAssertEqual(rows.map(\.previousLine), [1, 2, nil, 3])
        XCTAssertEqual(rows.map(\.currentLine), [1, 2, 3, 4])
        XCTAssertEqual(rows[1].previous, "old")
        XCTAssertEqual(rows[1].current, "new")
        XCTAssertNil(rows[2].previous)
        let deleted = try XCTUnwrap(DocumentHistoryDiff.rows(previous: "first\ndeleted\nlast", current: "first\nlast"))
        XCTAssertEqual(deleted[1].kind, .removed)
        XCTAssertNil(deleted[1].currentLine)
        XCTAssertEqual(deleted.last?.currentLine, 2)
    }

    func testComparisonReconstructsBothInputsWithRepeatedAndEmptyLines() throws {
        for (previous, current) in [("a\na\n\nb", "a\n\nb\na"), ("", "new"), ("old", ""), ("same", "same")] {
            let rows = try XCTUnwrap(DocumentHistoryDiff.rows(previous: previous, current: current))
            XCTAssertEqual(rows.compactMap(\.previous).joined(separator: "\n"), previous)
            XCTAssertEqual(rows.compactMap(\.current).joined(separator: "\n"), current)
        }
    }

    func testComparisonViewLaysOutBothColumnsAndHighlightsChanges() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = DocumentHistoryComparisonView()
        window.contentView = view
        let rows = try XCTUnwrap(DocumentHistoryDiff.rows(previous: "그는 문을 열었다.\n방은 어두웠다.\n낡은 의자가 있었다.\n그는 돌아섰다.", current: "그는 문을 열었다.\n방 안에는 아침 햇빛이 들었다.\n창가에서 고양이가 울었다.\n새로운 발자국이 보였다.\n그는 돌아섰다."))
        view.show(rows: rows, version: "1차 완성 · 2026. 10. 29.")
        view.layoutSubtreeIfNeeded()
        func descendants(_ node: NSView) -> [NSView] { node.subviews.flatMap { [$0] + descendants($0) } }
        let scrolls = descendants(view).compactMap { $0 as? NSScrollView }
        XCTAssertEqual(scrolls.count, 2)
        for scroll in scrolls {
            XCTAssertGreaterThan(scroll.frame.width, 300)
            XCTAssertGreaterThan(scroll.frame.height, 200)
            let text = try XCTUnwrap(scroll.documentView as? NSTextView)
            XCTAssertTrue(text.string.contains("~"))
            var highlights = 0
            text.textStorage?.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.string.utf16.count)) { value, _, _ in
                if value != nil { highlights += 1 }
            }
            XCTAssertGreaterThan(highlights, 0)
        }
        if let path = ProcessInfo.processInfo.environment["JENA_DIFF_SCREENSHOT"],
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func testChangeMapShowsWholeDocumentAndSelectsNearestChange() throws {
        _ = NSApplication.shared
        let rows = (0..<100).map { index in
            DocumentHistoryDiff.Row(previousLine: index + 1, currentLine: index + 1,
                                    previous: "before", current: "after",
                                    kind: index == 10 ? .modified : index == 80 ? .added : .unchanged)
        }
        let map = DocumentHistoryChangeMap(frame: NSRect(x: 0, y: 0, width: 20, height: 400))
        map.setRows(rows)
        XCTAssertEqual(map.markers.map(\.row), [10, 80])
        XCTAssertEqual(map.markerRect(at: 0).midY, 42, accuracy: 1)
        XCTAssertEqual(map.markerRect(at: 1).midY, 322, accuracy: 1)
        var selection: Int?
        map.onSelect = { selection = $0 }
        map.selectNearest(to: 320)
        XCTAssertEqual(selection, 1)
        map.selectNearest(to: 0)
        XCTAssertEqual(selection, 0)
        map.setRows([])
        selection = nil
        map.selectNearest(to: 100)
        XCTAssertNil(selection)
    }

    func testComparisonDirectionAndBounds() {
        XCTAssertEqual(DocumentHistoryDiff.compare(previous: "same\nold", current: "same\nnew"), "  same\n− old\n+ new")
        XCTAssertEqual(DocumentHistoryDiff.compare(previous: "", current: "text"), "− \n+ text")
        XCTAssertNil(DocumentHistoryDiff.compare(previous: String(repeating: "x\n", count: 1100), current: String(repeating: "y\n", count: 1100)))
    }
}
