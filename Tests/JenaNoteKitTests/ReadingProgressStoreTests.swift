import XCTest
@testable import JenaNoteKit

final class ReadingProgressStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.jenalab.jenanote.tests.progress.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func anchor(_ offset: Int) -> ReadingAnchor {
        ReadingAnchor(characterOffset: offset,
                      contextSnippet: "조각",
                      contentLength: 1000,
                      updatedAt: Date())
    }

    private let fileA = URL(fileURLWithPath: "/tmp/jena-note-test/a.md")
    private let fileB = URL(fileURLWithPath: "/tmp/jena-note-test/b.md")

    func testStoresAndReadsBackAnchor() {
        let store = ReadingProgressStore(defaults: defaults)
        store.setAnchor(anchor(42), for: fileA)
        XCTAssertEqual(store.anchor(for: fileA)?.characterOffset, 42)
    }

    func testAnchorsAreKeyedPerDocument() {
        let store = ReadingProgressStore(defaults: defaults)
        store.setAnchor(anchor(10), for: fileA)
        store.setAnchor(anchor(20), for: fileB)
        XCTAssertEqual(store.anchor(for: fileA)?.characterOffset, 10)
        XCTAssertEqual(store.anchor(for: fileB)?.characterOffset, 20)
    }

    func testUnknownDocumentHasNoAnchor() {
        let store = ReadingProgressStore(defaults: defaults)
        XCTAssertNil(store.anchor(for: fileA))
    }

    func testClearRemovesAnchor() {
        let store = ReadingProgressStore(defaults: defaults)
        store.setAnchor(anchor(42), for: fileA)
        store.clearAnchor(for: fileA)
        XCTAssertNil(store.anchor(for: fileA))
    }

    func testSetAnchorOrClearDropsTopOfDocument() {
        let store = ReadingProgressStore(defaults: defaults)
        store.setAnchor(anchor(42), for: fileA)
        store.setAnchorOrClear(anchor(0), for: fileA)
        XCTAssertNil(store.anchor(for: fileA), "맨 앞은 복원할 게 없으므로 앵커를 남기지 않는다")
    }

    func testPathIsStandardizedBeforeKeying() {
        let store = ReadingProgressStore(defaults: defaults)
        store.setAnchor(anchor(7), for: URL(fileURLWithPath: "/tmp/jena-note-test/sub/../a.md"))
        XCTAssertEqual(store.anchor(for: fileA)?.characterOffset, 7)
    }

    func testAnchorsSurviveNewStoreInstance() {
        let store = ReadingProgressStore(defaults: defaults)
        store.setAnchor(anchor(99), for: fileA)

        let reopened = ReadingProgressStore(defaults: defaults)
        XCTAssertEqual(reopened.anchor(for: fileA)?.characterOffset, 99)
    }

    func testPrunesOldestBeyondLimit() {
        let store = ReadingProgressStore(defaults: defaults)
        let limit = ReadingProgressStore.maxEntries
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // 오래된 것부터 차례로 넣어 상한을 넘긴다
        for i in 0..<(limit + 10) {
            let a = ReadingAnchor(characterOffset: i,
                                  contextSnippet: "조각",
                                  contentLength: 1000,
                                  updatedAt: base.addingTimeInterval(TimeInterval(i)))
            store.setAnchor(a, for: URL(fileURLWithPath: "/tmp/jena-note-test/f\(i).md"))
        }

        // 가장 오래된 항목은 밀려나고, 가장 최근 항목은 남아야 한다
        XCTAssertNil(store.anchor(for: URL(fileURLWithPath: "/tmp/jena-note-test/f0.md")))
        XCTAssertNotNil(store.anchor(for: URL(fileURLWithPath: "/tmp/jena-note-test/f\(limit + 9).md")))
    }
}
