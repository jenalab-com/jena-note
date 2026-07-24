import XCTest
@testable import JenaNoteKit

final class BookmarkStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.jenalab.jenanote.tests.bookmarks.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func anchor(_ offset: Int, at date: Date = Date()) -> ReadingAnchor {
        ReadingAnchor(characterOffset: offset,
                      contextSnippet: "조각\(offset)",
                      contentLength: 10_000,
                      updatedAt: date)
    }

    private let fileA = URL(fileURLWithPath: "/tmp/jena-note-test/a.md")
    private let fileB = URL(fileURLWithPath: "/tmp/jena-note-test/b.md")

    // MARK: - 추가

    func testAddsAndReadsBack() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(100), for: fileA)
        XCTAssertEqual(store.bookmarks(for: fileA).map(\.characterOffset), [100])
    }

    func testKeepsDocumentOrderRegardlessOfInsertionOrder() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(300), for: fileA)
        store.add(anchor(100), for: fileA)
        store.add(anchor(200), for: fileA)
        XCTAssertEqual(store.bookmarks(for: fileA).map(\.characterOffset), [100, 200, 300])
    }

    func testIgnoresDuplicateOffset() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(100), for: fileA)
        store.add(anchor(100), for: fileA)
        XCTAssertEqual(store.bookmarks(for: fileA).count, 1)
    }

    func testBookmarksAreKeyedPerDocument() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(100), for: fileA)
        store.add(anchor(200), for: fileB)
        XCTAssertEqual(store.bookmarks(for: fileA).map(\.characterOffset), [100])
        XCTAssertEqual(store.bookmarks(for: fileB).map(\.characterOffset), [200])
    }

    func testUnknownDocumentIsEmpty() {
        let store = BookmarkStore(defaults: defaults)
        XCTAssertTrue(store.bookmarks(for: fileA).isEmpty)
    }

    // MARK: - 범위 삭제 (⌘D 토글)

    func testRemovesBookmarksInsideVisibleRange() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(100), for: fileA)
        store.add(anchor(500), for: fileA)

        let removed = store.removeBookmarks(in: NSRange(location: 50, length: 100), for: fileA)
        XCTAssertTrue(removed)
        XCTAssertEqual(store.bookmarks(for: fileA).map(\.characterOffset), [500])
    }

    func testRemoveInRangeReportsFalseWhenNothingHit() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(500), for: fileA)

        let removed = store.removeBookmarks(in: NSRange(location: 0, length: 100), for: fileA)
        XCTAssertFalse(removed, "지운 게 없으면 false — 호출자는 이걸 보고 추가로 전환한다")
        XCTAssertEqual(store.bookmarks(for: fileA).count, 1)
    }

    func testRemoveInRangeOnEmptyDocumentIsFalse() {
        let store = BookmarkStore(defaults: defaults)
        XCTAssertFalse(store.removeBookmarks(in: NSRange(location: 0, length: 100), for: fileA))
    }

    // MARK: - 개별 삭제

    func testRemovesSingleBookmarkByOffset() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(100), for: fileA)
        store.add(anchor(200), for: fileA)
        store.removeBookmark(atOffset: 100, for: fileA)
        XCTAssertEqual(store.bookmarks(for: fileA).map(\.characterOffset), [200])
    }

    func testRemoveAllClearsDocument() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(100), for: fileA)
        store.add(anchor(200), for: fileA)
        store.removeAll(for: fileA)
        XCTAssertTrue(store.bookmarks(for: fileA).isEmpty)
    }

    // MARK: - 영속·정리

    func testSurvivesNewStoreInstance() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(100), for: fileA)
        store.add(anchor(200), for: fileA)

        let reopened = BookmarkStore(defaults: defaults)
        XCTAssertEqual(reopened.bookmarks(for: fileA).map(\.characterOffset), [100, 200])
    }

    func testDropsOldestBeyondPerDocumentLimit() {
        let store = BookmarkStore(defaults: defaults)
        let limit = BookmarkStore.maxPerDocument
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<(limit + 5) {
            store.add(anchor(i * 10, at: base.addingTimeInterval(TimeInterval(i))), for: fileA)
        }

        let offsets = store.bookmarks(for: fileA).map(\.characterOffset)
        XCTAssertEqual(offsets.count, limit)
        XCTAssertEqual(offsets, offsets.sorted(), "정리 후에도 문서 순서를 유지해야 한다")
        XCTAssertFalse(offsets.contains(0), "가장 오래 전에 찍은 것이 밀려난다")
        XCTAssertTrue(offsets.contains((limit + 4) * 10))
    }

    func testPathIsStandardizedBeforeKeying() {
        let store = BookmarkStore(defaults: defaults)
        store.add(anchor(42), for: URL(fileURLWithPath: "/tmp/jena-note-test/sub/../a.md"))
        XCTAssertEqual(store.bookmarks(for: fileA).map(\.characterOffset), [42])
    }
}
