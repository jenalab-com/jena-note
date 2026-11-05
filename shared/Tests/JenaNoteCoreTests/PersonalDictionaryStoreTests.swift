import XCTest
@testable import JenaNoteCore

final class PersonalDictionaryStoreTests: XCTestCase {
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
        #if !canImport(Darwin)
        try XCTSkipIf(true, "Windows Foundation has no URL bookmarks")
        #endif
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
}
