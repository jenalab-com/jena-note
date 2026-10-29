import AppKit
import XCTest
@testable import JenaNoteKit

// Fixture lifetime is shorter than NSDocument's autosave timer. Exercise safe saves explicitly.
private class WriterTestDocument: MarkdownDocument {
    override class var autosavesInPlace: Bool { false }
}

private final class BackupReportingDocument: WriterTestDocument {
    var reported: (() -> Void)?
    override func presentError(_ error: Error) -> Bool { reported?(); return false }
}

final class WriterUtilitiesTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAutosavePreferencesApplyToDocumentControllerAndPreserveIntervalWhenDisabled() {
        let defaults = UserDefaults.standard
        let keys = ["jn_autosaveEnabled", "jn_autosaveInterval"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let oldDelay = NSDocumentController.shared.autosavingDelay
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            NSDocumentController.shared.autosavingDelay = oldDelay
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let settings = SettingsManager.shared
        XCTAssertTrue(settings.autosaveEnabled)
        XCTAssertEqual(settings.autosaveInterval, 60)
        settings.autosaveInterval = 180
        XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 180)
        settings.autosaveEnabled = false
        XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)
        XCTAssertFalse(MarkdownDocument.autosavesInPlace)
        XCTAssertEqual(settings.autosaveInterval, 180)
        settings.autosaveEnabled = true
        XCTAssertTrue(MarkdownDocument.autosavesInPlace)
        XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 180)
        settings.autosaveInterval = -1
        XCTAssertEqual(settings.autosaveInterval, 60)
        XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 60)
    }

    func testBackupDeduplicatesThrottlesAutosavesAndPrunesOnlyOldSnapshots() throws {
        let store = DocumentBackupStore(directory: root.appendingPathComponent("backups"), limit: 3)
        let file = root.appendingPathComponent("draft.md"), start = Date(timeIntervalSince1970: 1_000)
        try store.record(Data("first".utf8), for: file, now: start)
        try store.record(Data("first".utf8), for: file, now: start.addingTimeInterval(1))
        try store.record(Data("typing".utf8), for: file, automatic: true, now: start.addingTimeInterval(20))
        XCTAssertEqual(try store.snapshots(for: file).count, 1)
        try store.record(Data("auto".utf8), for: file, automatic: true, now: start.addingTimeInterval(300))
        try store.record(Data("manual".utf8), for: file, now: start.addingTimeInterval(301))
        try store.record(Data("last".utf8), for: file, now: start.addingTimeInterval(302))
        XCTAssertEqual(try store.snapshots(for: file).map { String(data: $0.data, encoding: .utf8)! }, ["last", "manual", "auto"])
        XCTAssertTrue(try store.snapshots(for: root.appendingPathComponent("another.md")).isEmpty)
    }

    func testSafeSaveBacksUpOriginalAndNewVersionUnderRealPath() throws {
        let file = root.appendingPathComponent("draft.md")
        try "old text\n".write(to: file, atomically: true, encoding: .utf8)
        let doc = WriterTestDocument()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.fileURL = file; doc.fileType = "net.daringfireball.markdown"
        doc.backupStore = DocumentBackupStore(directory: root.appendingPathComponent("backups"))
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("new text"))
        try doc.writeSafely(to: file, ofType: "net.daringfireball.markdown", for: .saveOperation)
        XCTAssertEqual(try String(contentsOf: file), "new text\n")
        let snapshots = try doc.backupStore.snapshots(for: file)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots.contains { String(data: $0.data, encoding: .utf8) == "old text\n" })
        XCTAssertTrue(snapshots.allSatisfy { $0.source == file.path })
    }

    func testRestorePreservesUnsavedTextAndUndoWithoutOverwritingDisk() throws {
        let file = root.appendingPathComponent("draft.md")
        try "disk text\n".write(to: file, atomically: true, encoding: .utf8)
        let doc = WriterTestDocument()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.fileURL = file; doc.fileType = "net.daringfireball.markdown"
        doc.undoManager = UndoManager()
        doc.backupStore = DocumentBackupStore(directory: root.appendingPathComponent("backups"))
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("unsaved text"))
        let snapshot = DocumentBackupStore.Snapshot(id: UUID(), source: file.path, createdAt: Date(), data: Data("restored text\n".utf8))
        try doc.restoreBackup(snapshot)
        XCTAssertEqual(MarkdownSerializer.serialize(doc.content), "restored text\n")
        XCTAssertEqual(try String(contentsOf: file), "disk text\n")
        XCTAssertTrue(try doc.backupStore.snapshots(for: file).contains { String(data: $0.data, encoding: .utf8) == "unsaved text\n" })
        doc.undoManager?.undo()
        XCTAssertEqual(doc.content.string, "unsaved text\n")
    }

    func testInvalidBackupAndFailureToProtectCurrentTextNeverModifyDocument() throws {
        let file = root.appendingPathComponent("draft.md")
        let doc = WriterTestDocument()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.fileURL = file
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("keep me"))
        let invalid = DocumentBackupStore.Snapshot(id: UUID(), source: file.path, createdAt: Date(), data: Data([0xFF]))
        XCTAssertThrowsError(try doc.restoreBackup(invalid))
        let blocked = root.appendingPathComponent("blocked")
        try Data([1]).write(to: blocked)
        doc.backupStore = DocumentBackupStore(directory: blocked)
        let valid = DocumentBackupStore.Snapshot(id: UUID(), source: file.path, createdAt: Date(), data: Data("replace".utf8))
        XCTAssertThrowsError(try doc.restoreBackup(valid))
        XCTAssertEqual(doc.content.string, "keep me\n")
    }

    func testBackupFailureReportsErrorButStillSavesOriginalDocument() throws {
        let file = root.appendingPathComponent("draft.md")
        let blocked = root.appendingPathComponent("blocked")
        try Data([1]).write(to: blocked)
        let doc = BackupReportingDocument()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.fileURL = file; doc.fileType = "net.daringfireball.markdown"
        doc.backupStore = DocumentBackupStore(directory: blocked)
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("must save"))
        let reported = expectation(description: "backup error visible")
        doc.reported = { reported.fulfill() }
        try doc.writeSafely(to: file, ofType: "net.daringfireball.markdown", for: .saveOperation)
        wait(for: [reported], timeout: 2)
        XCTAssertEqual(try String(contentsOf: file), "must save\n")
    }

    func testEndnotesRoundTripEditDeleteAndKeepInlineCodeLiteral() {
        let original = MarkdownSerializer.parse("본문 😀\n`[^literal]`\n")
        let inserted = DocumentEndnotes.insert(into: original, at: 2, text: "설명 내용")
        XCTAssertEqual(inserted.id, "1")
        let saved = MarkdownSerializer.serialize(inserted.content)
        XCTAssertTrue(saved.contains("본문[^1]"))
        XCTAssertTrue(saved.contains("[^1]: 설명 내용"))
        XCTAssertTrue(saved.contains("`[^literal]`"))
        let reopened = MarkdownSerializer.parse(saved)
        XCTAssertEqual(DocumentEndnotes.notes(in: reopened).map(\.text), ["설명 내용"])
        XCTAssertEqual(DocumentEndnotes.referenceRanges("1", in: reopened).count, 1)
        let edited = DocumentEndnotes.update("1", text: "고친 설명", in: reopened)
        XCTAssertTrue(MarkdownSerializer.serialize(edited).contains("[^1]: 고친 설명"))
        let deleted = DocumentEndnotes.update("1", text: nil, in: edited)
        XCTAssertFalse(MarkdownSerializer.serialize(deleted).contains("[^1]"))
        XCTAssertTrue(MarkdownSerializer.serialize(deleted).contains("`[^literal]`"))
    }

    func testEndnoteIDsAvoidOrphanReferencesAndDeletionHandlesSelfReference() {
        let source = MarkdownSerializer.parse("본문[^1]\n[^2]: 내용[^2]\n")
        let inserted = DocumentEndnotes.insert(into: source, at: 0, text: "추가")
        XCTAssertEqual(inserted.id, "3")
        let deleted = DocumentEndnotes.update("2", text: nil, in: inserted.content)
        XCTAssertFalse(MarkdownSerializer.serialize(deleted).contains("[^2]"))
        XCTAssertTrue(MarkdownSerializer.serialize(deleted).contains("[^1]"))
    }

    func testEndnotesRemainInBothExportFormats() throws {
        let content = MarkdownSerializer.parse("본문[^1]\n\n[^1]: 출처 설명\n")
        let model = DocumentModelBuilder.build(content, baseURL: nil)
        for (name, data, entry) in [("docx", DocxWriter.write(model.blocks), "word/document.xml"),
                                    ("hwpx", HwpxWriter.write(model.blocks), "Contents/section0.xml")] {
            let file = root.appendingPathComponent("sample." + name)
            try data.write(to: file)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", file.path, entry]
            let pipe = Pipe(); process.standardOutput = pipe
            try process.run()
            let xml = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(xml.contains("[1]")); XCTAssertTrue(xml.contains("출처 설명"))
        }
    }

    func testNativeColorWellAppliesArbitraryColorAndResetRestoresDefault() throws {
        let defaults = UserDefaults.standard
        let keys = ["jn_paperBackground", "jn_paperBackgroundColor"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            NotificationCenter.default.post(name: PaperBackground.changed, object: nil)
        }
        let settings = PreferencesWindowController()
        let window = try XCTUnwrap(settings.window)
        defer { window.close() }
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        tabs.selectedTabViewItemIndex = 1
        let view = try XCTUnwrap(tabs.tabViewItems[1].viewController?.view)
        func descendants(_ node: NSView) -> [NSView] { node.subviews.flatMap { [$0] + descendants($0) } }
        let well = try XCTUnwrap(descendants(view).compactMap { $0 as? NSColorWell }.first)
        let editor = EditorViewController(); _ = editor.view
        well.color = NSColor(srgbRed: 0.31, green: 0.57, blue: 0.83, alpha: 1)
        XCTAssertTrue(well.sendAction(well.action, to: well.target))
        XCTAssertEqual(editor.textView.backgroundColor.usingColorSpace(.sRGB)!.redComponent, 0.31, accuracy: 0.001)
        XCTAssertEqual(PaperBackground.currentColor.usingColorSpace(.sRGB)!.blueComponent, 0.83, accuracy: 0.001)
        XCTAssertNotNil(defaults.array(forKey: "jn_paperBackgroundColor"))
        let reset = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == L10n.tr("paper.resetColor") })
        reset.performClick(nil)
        XCTAssertNil(defaults.object(forKey: "jn_paperBackgroundColor"))
        XCTAssertEqual(MarkdownColor.toHex(editor.textView.backgroundColor), MarkdownColor.toHex(NSColor.textBackgroundColor))
    }

    func testPaperPresetsApplyWithoutMutatingMarkdown() {
        let previous = PaperBackground.selected
        let previousCustom = UserDefaults.standard.object(forKey: "jn_paperBackgroundColor")
        defer {
            PaperBackground.selected = previous
            if let previousCustom { UserDefaults.standard.set(previousCustom, forKey: "jn_paperBackgroundColor") }
        }
        let doc = MarkdownSerializer.parse("# 제목\n**본문**\n")
        let before = MarkdownSerializer.serialize(doc)
        let editor = EditorViewController(); _ = editor.view
        for preset in PaperBackground.allCases {
            PaperBackground.selected = preset
            XCTAssertEqual(PaperBackground.selected, preset)
            XCTAssertEqual(MarkdownColor.toHex(editor.textView.backgroundColor), MarkdownColor.toHex(preset.color))
            XCTAssertEqual(MarkdownSerializer.serialize(doc), before)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    XCTAssertNotNil(preset.color.usingColorSpace(.sRGB))
                }
            }
        }
    }
}
