import XCTest
import AppKit
@testable import JenaNoteKit

final class IncrementalPaginatorTests: XCTestCase {
    private let pageSize = NSSize(width: 240, height: 180)

    private func makePaginator(_ text: String) -> IncrementalPaginator {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        return IncrementalPaginator(storage: storage, pageSize: pageSize)
    }

    private func finish(_ paginator: IncrementalPaginator, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10000 {
            if paginator.isComplete { return }
            paginator.advance(maxPages: 4)
        }
        XCTFail("Pagination failed to reach EOF", file: file, line: line)
    }

    private func assertMatchesFresh(_ paginator: IncrementalPaginator, file: StaticString = #filePath, line: UInt = #line) {
        finish(paginator, file: file, line: line)
        let fresh = IncrementalPaginator(storage: NSTextStorage(attributedString: paginator.storage), pageSize: pageSize)
        finish(fresh, file: file, line: line)
        XCTAssertEqual(paginator.ranges, fresh.ranges, "Incremental boundaries must match a fresh layout", file: file, line: line)
        for (index, cached) in paginator.ranges.enumerated() {
            let glyphs = paginator.layoutManager.glyphRange(for: paginator.containers[index])
            let live = paginator.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            XCTAssertEqual(cached, live, "Adding later containers must not change an earlier cached boundary", file: file, line: line)
        }
    }

    private var body: String {
        (0..<150).map { "\($0): 한글과 English, 👨‍👩‍👧‍👦 그리고 e\u{301}가 있는 문단입니다. 줄바꿈과 페이지 경계를 확인합니다.\n" }.joined()
    }

    func testVisiblePagesDoNotComputeTheEntireDocument() {
        let paginator = makePaginator(body)
        paginator.ensurePage(1)
        XCTAssertEqual(paginator.ranges.count, 2)
        XCTAssertEqual(paginator.computedPageCount, 2)
        XCTAssertFalse(paginator.isComplete)
        paginator.advance(maxPages: 2)
        XCTAssertEqual(paginator.computedPageCount, 4)
        XCTAssertFalse(paginator.isComplete)
    }

    func testInsertionReusesNetworkAndMatchesFreshLayout() {
        let paginator = makePaginator(body)
        finish(paginator)
        let layoutManager = paginator.layoutManager
        let firstContainer = paginator.containers[0]
        let oldCount = paginator.computedPageCount
        let offset = paginator.ranges[6].location + 10
        let insertion = "추가된 👩🏽‍💻 문장입니다.\n"
        paginator.storage.replaceCharacters(in: NSRange(location: offset, length: 0), with: insertion)
        paginator.invalidate(editedRange: NSRange(location: offset, length: (insertion as NSString).length))
        XCTAssertEqual(paginator.computedPageCount, oldCount, "Invalidation during storage editing must not lay out")
        XCTAssertGreaterThan(paginator.ranges.count, 0)
        XCTAssertLessThan(paginator.ranges.count, 7)
        paginator.advance(maxPages: 2)
        XCTAssertEqual(paginator.computedPageCount, oldCount + 2)
        XCTAssertTrue(paginator.layoutManager === layoutManager)
        XCTAssertTrue(paginator.containers[0] === firstContainer)
        assertMatchesFresh(paginator)
    }

    func testDeletionAcrossPageBoundaryMatchesFreshLayout() {
        let paginator = makePaginator(body)
        finish(paginator)
        let start = paginator.ranges[4].location - 3
        let end = NSMaxRange(paginator.ranges[8])
        paginator.storage.replaceCharacters(in: NSRange(location: start, length: end - start), with: "")
        paginator.invalidate(editedRange: NSRange(location: start, length: 0))
        assertMatchesFresh(paginator)
    }

    func testParagraphStyleEditReflowsFromParagraphStart() {
        let paginator = makePaginator(String(repeating: "long paragraph 한글 ", count: 400))
        finish(paginator)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        paginator.storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paginator.storage.length))
        paginator.invalidate(editedRange: NSRange(location: 1000, length: 1))
        XCTAssertTrue(paginator.ranges.isEmpty, "Paragraph-wide changes cannot preserve old page boundaries in that paragraph")
        assertMatchesFresh(paginator)
    }

    func testEmptyDocumentCanGrowAndShrinkWithoutDiscardingContainers() {
        let paginator = makePaginator("")
        finish(paginator)
        XCTAssertEqual(paginator.ranges, [NSRange(location: 0, length: 0)])
        paginator.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: body)
        paginator.invalidate(editedRange: NSRange(location: 0, length: paginator.storage.length))
        finish(paginator)
        XCTAssertGreaterThan(paginator.ranges.count, 2)
        let containerCount = paginator.containers.count
        paginator.storage.replaceCharacters(in: NSRange(location: 0, length: paginator.storage.length), with: "")
        paginator.invalidate(editedRange: NSRange(location: 0, length: 0))
        finish(paginator)
        XCTAssertEqual(paginator.ranges, [NSRange(location: 0, length: 0)])
        XCTAssertEqual(paginator.containers.count, containerCount, "Text views may still refer to surplus containers")
    }

    func testCharacterSeekOnlyCalculatesThroughTarget() {
        let paginator = makePaginator(body)
        paginator.ensurePage(2)
        let offset = paginator.ranges[1].location
        let count = paginator.computedPageCount
        paginator.ensureCharacter(offset)
        XCTAssertEqual(paginator.computedPageCount, count)
        XCTAssertEqual(paginator.pageIndex(containing: offset), 1)
        paginator.ensureCharacter(paginator.storage.length)
        XCTAssertTrue(paginator.isComplete)
        XCTAssertEqual(paginator.pageIndex(containing: paginator.storage.length), paginator.ranges.count - 1)
    }

    func testTrailingNewlineHasAnInsertionPointContainer() {
        let paginator = makePaginator(String(repeating: "line\n", count: 40))
        finish(paginator)
        XCTAssertNotNil(paginator.layoutManager.extraLineFragmentTextContainer)
        XCTAssertEqual(NSMaxRange(paginator.ranges.last!), paginator.storage.length)
        assertMatchesFresh(paginator)
    }
    func testOversizedLineMakesProgress() {
        let storage = NSTextStorage(string: "Huge\nnext", attributes: [.font: NSFont.systemFont(ofSize: 500)])
        let paginator = IncrementalPaginator(storage: storage, pageSize: pageSize)
        paginator.advance(maxPages: 2)
        XCTAssertGreaterThan(NSMaxRange(paginator.ranges.last!), 0, "A line taller than a page must not produce endless empty pages")
    }

    func testOversizedAttachmentMakesProgress() {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 240, height: 1000))
        attachment.bounds = NSRect(x: 0, y: 0, width: 240, height: 1000)
        let storage = NSTextStorage(attributedString: NSAttributedString(attachment: attachment))
        let paginator = IncrementalPaginator(storage: storage, pageSize: pageSize)
        paginator.advance(maxPages: 2)
        XCTAssertGreaterThan(NSMaxRange(paginator.ranges.last!), 0, "A tall attachment must not produce endless empty pages")
    }

    func testRepeatedEditsBeforeIdlePassUseTheEarliestInvalidatedPage() {
        let paginator = makePaginator(body)
        finish(paginator)
        let later = paginator.ranges[10].location + 5
        paginator.storage.replaceCharacters(in: NSRange(location: later, length: 2), with: "change")
        paginator.invalidate(editedRange: NSRange(location: later, length: 6))
        let earlier = paginator.ranges[3].location + 5
        paginator.storage.replaceCharacters(in: NSRange(location: earlier, length: 2), with: "먼저")
        paginator.invalidate(editedRange: NSRange(location: earlier, length: 2))
        assertMatchesFresh(paginator)
    }

    func testInvalidationInsideStorageEditingDoesNotRequestLayout() {
        final class Observer: NSObject, NSTextStorageDelegate {
            var paginator: IncrementalPaginator!
            var editNotifications = 0
            func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                             range editedRange: NSRange, changeInLength delta: Int) {
                let before = paginator.computedPageCount
                paginator.invalidate(editedRange: editedRange)
                XCTAssertEqual(paginator.computedPageCount, before)
                editNotifications += 1
            }
        }
        let paginator = makePaginator(body)
        paginator.ensurePage(2)
        let observer = Observer()
        observer.paginator = paginator
        paginator.storage.delegate = observer
        paginator.storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "한글 입력")
        XCTAssertGreaterThan(observer.editNotifications, 0)
        assertMatchesFresh(paginator)
    }

}
