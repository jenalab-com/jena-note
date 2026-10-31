import AppKit
import XCTest
@testable import JenaNoteKit

final class PersonalDictionaryTests: XCTestCase {
    private func fixture() throws -> (PersonalDictionaryStore, URL, DictionaryWorkContext, DictionaryWorkContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jena-dictionary-tests-" + UUID().uuidString)
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("dictionary.json")
        return (PersonalDictionaryStore(fileURL: file), file, DictionaryWorkContext(root: a, title: "같은 제목"), DictionaryWorkContext(root: b, title: "같은 제목"))
    }

    func testBulkDeletionPersistsOnceAndPreservesUncheckedWords() throws {
        let (store, file, a, _) = try fixture()
        let first = try store.save(term: "단어 하나", selectedWorks: nil)
        let second = try store.save(term: "단어 둘", selectedWorks: [store.work(for: a)])
        let keep = try store.save(term: "남길 단어", selectedWorks: nil)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: PersonalDictionaryStore.changed, object: store, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        try store.remove(ids: [first.id, second.id])
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.entries.map(\.id), [keep.id])
        XCTAssertEqual(PersonalDictionaryStore(fileURL: file).entries.map(\.id), [keep.id])
        XCTAssertEqual(try store.terms(for: a), ["남길 단어"])
        try store.remove(ids: [])
        XCTAssertEqual(notifications, 1)
    }

    func testDeletionFailureKeepsWordsAndFileIntact() throws {
        let (store, file, _, _) = try fixture()
        let word = try store.save(term: "남길 단어", selectedWorks: nil)
        let before = try Data(contentsOf: file)
        // A non-directory at the backup path must prevent deletion before state changes.
        try Data("blocked".utf8).write(to: file.deletingLastPathComponent().appendingPathComponent("Backups"))
        XCTAssertThrowsError(try store.remove(ids: [word.id]))
        XCTAssertEqual(store.entries.map(\.id), [word.id])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testScopesIsolateSameNamedWorksAndSupportExplicitSharingAndPersistence() throws {
        let (store, file, a, b) = try fixture()
        let wa = store.work(for: a), wb = store.work(for: b)
        XCTAssertNotEqual(wa.id, wb.id)
        let entry = try store.save(term: "서쥰", selectedWorks: [wa])
        XCTAssertEqual(try store.terms(for: a), ["서쥰"])
        XCTAssertTrue(try store.terms(for: b).isEmpty)
        XCTAssertTrue(try store.terms(for: nil).isEmpty)
        let shared = try store.save(term: "서쥰", selectedWorks: [wb])
        XCTAssertEqual(entry.id, shared.id)
        XCTAssertEqual(Set(shared.workIDs ?? []), Set([wa.id, wb.id]))
        XCTAssertEqual(try store.terms(for: b), ["서쥰"])
        _ = try store.save(term: "고유 용어", selectedWorks: nil)
        let loaded = PersonalDictionaryStore(fileURL: file)
        XCTAssertEqual(Set(try loaded.terms(for: b)), Set(["서쥰", "고유 용어"]))
        XCTAssertEqual(try loaded.terms(for: nil), ["고유 용어"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent().appendingPathComponent("Backups"), includingPropertiesForKeys: nil).isEmpty)
        _ = try loaded.save(id: entry.id, term: entry.term, selectedWorks: [wa, wb], enabled: false)
        XCTAssertEqual(try loaded.terms(for: a), ["고유 용어"])
    }

    func testReaddingDisabledGlobalTermDoesNotSilentlyEnableItEverywhere() throws {
        let (store, _, a, b) = try fixture()
        _ = try store.save(term: "서쥰", selectedWorks: nil, enabled: false)
        _ = try store.save(term: "서쥰", selectedWorks: [store.work(for: a)])
        XCTAssertEqual(try store.terms(for: a), ["서쥰"])
        XCTAssertTrue(try store.terms(for: b).isEmpty)
    }

    func testCorruptDictionaryAndWriteFailurePreserveOriginalState() throws {
        let (_, file, _, _) = try fixture()
        let original = Data("broken dictionary".utf8)
        try original.write(to: file)
        let damaged = PersonalDictionaryStore(fileURL: file)
        XCTAssertThrowsError(try damaged.save(term: "원문", selectedWorks: nil))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let unwritable = PersonalDictionaryStore(fileURL: file.appendingPathComponent("child.json"))
        XCTAssertThrowsError(try unwritable.save(term: "원문", selectedWorks: nil))
        XCTAssertTrue(unwritable.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testMovingWorkFolderKeepsBookmarkIdentity() throws {
        let (store, _, a, _) = try fixture()
        let work = store.work(for: a)
        guard work.bookmark != nil else { throw XCTSkip("Filesystem cannot create bookmarks") }
        _ = try store.save(term: "서쥰", selectedWorks: [work])
        let moved = a.root.deletingLastPathComponent().appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at: a.root, to: moved)
        let context = DictionaryWorkContext(root: moved, title: "새 제목")
        XCTAssertEqual(try store.terms(for: context), ["서쥰"])
        XCTAssertEqual(store.work(for: context).id, work.id)
    }

    func testExceptionsOnlySuppressTheirEditsAndRespectWordBoundaries() {
        let source = "끝낫습니다 선섕님"
        let filtered = ProofreadingSuggestion.filteredText(source: source, corrected: "끝났습니다 선생님", terms: ["끝낫습니다"])
        XCTAssertEqual(filtered, "끝낫습니다 선생님")
        XCTAssertEqual(ProofreadingSuggestion.filteredText(source: source, corrected: "끝났습니다 선생님", terms: ["낫"]), "끝났습니다 선생님")
        XCTAssertEqual(PersonalDictionaryFilter.ranges(in: "서쥰은 서쥰대왕 서쥰.", terms: ["서쥰"]).count, 2)
        XCTAssertEqual(ProofreadingSuggestion.filteredText(source: "안녕 하세요", corrected: "안녕하세요", terms: ["안녕 하세요"]), "안녕 하세요")
    }

    func testSuggestionsApplyOneWordWithoutChangingOtherCorrectionsOrEmoji() {
        let source = "😀 오늘학교에갓다. 선섕님"
        let suggestions = ProofreadingSuggestion.suggestions(source: source, corrected: "😀 오늘 학교에 갔다. 선생님")
        XCTAssertEqual(suggestions.count, 2)
        let result = NSMutableString(string: source)
        result.replaceCharacters(in: suggestions[0].range, with: suggestions[0].replacement)
        XCTAssertEqual(result as String, "😀 오늘 학교에 갔다. 선섕님")
        for item in suggestions { XCTAssertEqual((source as NSString).substring(with: item.range), item.original) }
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) {
        let done = expectation(description: "UI result")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if predicate() { timer.invalidate(); done.fulfill() }
        }
        defer { timer.invalidate() }; wait(for: [done], timeout: 6)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testDictionaryChangeRefiltersCachedKiwiResultImmediately() throws {
        _ = NSApplication.shared
        let (store, _, _, _) = try fixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200)); view.string = "끝낫습니다 선섕님"
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        var calls = 0
        let live = LiveProofreadingController(textView: view, delay: 0.01, dictionary: store, check: { _ in calls += 1; return "끝났습니다 선생님" })
        defer { live.stop(); window.close() }
        waitUntil { live.candidates.count == 2 }
        let entry = try store.save(term: "끝낫습니다", selectedWorks: nil)
        waitUntil { live.candidates.count == 1 }
        XCTAssertEqual(live.candidates[0].original, "선섕님")
        XCTAssertEqual(calls, 1, "Dictionary filtering must not rerun the native model")
        _ = try store.save(id: entry.id, term: entry.term, selectedWorks: nil, enabled: false)
        waitUntil { live.candidates.count == 2 }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(view.string, "끝낫습니다 선섕님")
    }

    func testChangingDocumentWorkRefiltersWithoutNativeRerun() throws {
        _ = NSApplication.shared
        let (store, _, a, b) = try fixture()
        for context in [a, b] {
            try AIWorkContext(rootURL: context.root, config: AIWorkContextConfig(title: context.title, settingsSources: [], writingFolder: "."), invalidPaths: []).save()
        }
        _ = try store.save(term: "끝낫습니다", selectedWorks: [store.work(for: a)])
        let doc = MarkdownDocument(); doc.fileURL = a.root.appendingPathComponent("draft.md")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let windowController = NSWindowController(window: window); doc.addWindowController(windowController)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200)); view.string = "끝낫습니다 선섕님"
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        var calls = 0
        let live = LiveProofreadingController(textView: view, delay: 0.01, dictionary: store, check: { _ in calls += 1; return "끝났습니다 선생님" })
        defer { live.stop(); window.close(); doc.removeWindowController(windowController) }
        waitUntil { live.candidates.count == 1 }
        doc.fileURL = b.root.appendingPathComponent("draft.md")
        waitUntil { live.candidates.count == 2 }
        XCTAssertEqual(calls, 1)
    }

    func testSelectionSheetUsesSameDictionaryAndUpdatesAfterRegistration() throws {
        _ = NSApplication.shared
        let (store, _, _, _) = try fixture()
        let doc = MarkdownDocument(); doc.content = NSMutableAttributedString(string: "끝낫습니다")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        let sheet = AIProofreadingController(snapshot: AIEditSnapshot(document: doc, selection: NSRange(location: 0, length: doc.content.length)),
            service: AISelectionProofreader(infer: { _ in "끝났습니다" }), dictionaryTerms: { try store.terms(for: nil) }, apply: { _ in XCTFail("Review must not automatically apply") }, onClose: {})
        defer { sheet.cancel(); window.close() }
        sheet.show(in: window)
        waitUntil { sheet.suggestion == "끝났습니다" }
        _ = try store.save(term: "끝낫습니다", selectedWorks: nil)
        XCTAssertEqual(sheet.suggestion, "끝낫습니다")
        XCTAssertFalse(sheet.alert.buttons[0].isEnabled)
        XCTAssertEqual(doc.content.string, "끝낫습니다")
    }

    func testPopoverShowsFromFocusAndAppliesOnlyItsCandidateWithUndo() throws {
        try verifyPopover(mode: .scroll)
    }

    func testPagedPopoverAppliesOnlyItsCandidateWithUndo() throws {
        try verifyPopover(mode: .paged)
    }

    private func verifyPopover(mode: SettingsManager.ReadingPageMode) throws {
        _ = NSApplication.shared
        let (store, _, _, _) = try fixture()
        let oldMode = SettingsManager.shared.readingPageMode; SettingsManager.shared.readingPageMode = mode
        defer { SettingsManager.shared.readingPageMode = oldMode }
        let doc = MarkdownDocument(); doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("**끝낫습니다** 선섕님"))
        doc.undoManager?.groupsByEvent = false
        let original = NSAttributedString(attributedString: doc.content)
        let editor = EditorWindowController(); doc.addWindowController(editor)
        editor.window?.isReleasedWhenClosed = false; editor.window?.makeKeyAndOrderFront(nil)
        let view: NSTextView = try mode == .scroll ? XCTUnwrap(editor.editorVC.textView) : XCTUnwrap(editor.readerVC?.visiblePageTextViews.first)
        (view as? EditorTextView)?.liveProofreading?.stop()
        (view as? PageTextView)?.liveProofreading?.stop()
        let live = LiveProofreadingController(textView: view, delay: 0.01, dictionary: store, check: { text in text.replacingOccurrences(of: "낫", with: "났").replacingOccurrences(of: "섕", with: "생") })
        defer { live.stop(); doc.updateChangeCount(.changeCleared); editor.window?.close(); doc.removeWindowController(editor) }
        waitUntil { live.candidates.count == 2 }
        editor.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 2, length: 0)); live.selectionChanged()
        waitUntil { live.popover?.isShown == true }
        XCTAssertTrue(editor.window?.firstResponder === view, "Showing a correction must not steal typing focus")
        live.dismissPopover()
        let mark = live.candidates[0].marks[0]
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let box = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: mark, actualCharacterRange: nil), in: container)
        live.hover(at: NSPoint(x: box.midX + view.textContainerOrigin.x, y: box.midY + view.textContainerOrigin.y))
        waitUntil { live.popover?.isShown == true }
        let content = try XCTUnwrap(live.popover?.contentViewController?.view)
        let button = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L10n.tr("proof.apply") })
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/jena-proofreading-popover.png"))
        }
        button.performClick(nil)
        XCTAssertEqual(doc.content.string, original.string.replacingOccurrences(of: "낫", with: "났"))
        doc.undoManager?.undo()
        XCTAssertTrue(doc.content.isEqual(to: original))
    }

    func testDictionaryFormDefaultsToCurrentWorkAndPersistsOnlyAfterSave() throws {
        _ = NSApplication.shared
        let (store, _, a, b) = try fixture()
        let controller = PersonalDictionaryWindowController(context: a, term: "서쥰", store: store)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        defer { controller.close() }
        XCTAssertTrue(store.entries.isEmpty)
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        let scope = try XCTUnwrap(descendants(content).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "dictionary.scope" })
        XCTAssertTrue(scope.titleOfSelectedItem?.contains(L10n.tr("dictionary.currentWork")) == true)
        XCTAssertFalse(buttons.contains { $0.title == L10n.tr("dictionary.enabled") })
        let save = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "dictionary.save" })
        save.performClick(nil)
        XCTAssertEqual(try store.terms(for: a), ["서쥰"])
        XCTAssertTrue(try store.terms(for: b).isEmpty)
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(save.title, L10n.tr("dictionary.registerAction"))
        let field = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "dictionary.term" })
        field.stringValue = "새로운 용어"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(store.entries.count, 1, "Typing a draft must not register it")
        scope.selectItem(at: 0)
        save.performClick(nil)
        XCTAssertEqual(try store.terms(for: b), ["새로운 용어"])
        XCTAssertTrue(store.entries.allSatisfy(\.enabled))
        XCTAssertEqual(scope.indexOfSelectedItem, 0, "Keep the scope for consecutive registrations")
        XCTAssertEqual(field.stringValue, "")
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let delete = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "dictionary.delete" })
        XCTAssertFalse(delete.isEnabled)
        for row in 0..<2 {
            let checkbox = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSButton)
            checkbox.performClick(nil)
        }
        XCTAssertTrue(delete.isEnabled)
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/jena-personal-dictionary.png"))
        }
        delete.performClick(nil)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(try store.terms(for: a).isEmpty)
        XCTAssertFalse(delete.isEnabled)
    }
}
