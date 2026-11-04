import AppKit
import XCTest
@testable import JenaNoteKit

/// 헤더 검색창은 어느 보기에서든 문서 전체를 바로 찾아야 한다(ADR-0007).
///
/// 회귀 배경: 페이지 조판은 텍스트가 여러 페이지 뷰로 나뉘어 있고, 찾기 바는 페이지 배경에
/// 덮여 입력해도 보이지 않았다. 지금은 헤더 검색창이 찾기를 맡는다.
final class PagedFindTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private let keys = ["jn_readingPageMode", "jn_readingFontScale", "jn_readingFont", "jn_readingWeight", "jn_readingLineSpacing"]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        SettingsManager.shared.readingPageMode = .paged
        SettingsManager.shared.readingFontScale = 1
        SettingsManager.shared.readingFont = .sans
        SettingsManager.shared.readingLineSpacing = 1.2
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    /// 여러 페이지에 걸쳐 "등대"가 반복되는 문서.
    private func makeWindow() -> (MarkdownDocument, EditorWindowController, NSWindow) {
        let paragraphs = (1...120).map { "문단 \($0). 바다 건너 등대가 깜빡였다. 바람이 불었다." }
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse(paragraphs.joined(separator: "\n\n")))
        let controller = EditorWindowController()
        doc.addWindowController(controller)
        let window = controller.window!
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        controller.readerVC?.view.layoutSubtreeIfNeeded()
        return (doc, controller, window)
    }

    private func close(_ doc: MarkdownDocument, _ controller: EditorWindowController, _ window: NSWindow) {
        doc.updateChangeCount(.changeCleared)
        window.close()
        doc.removeWindowController(controller)
    }

    private func matches(_ needle: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        var result: [NSRange] = [], start = 0
        while true {
            let r = ns.range(of: needle, range: NSRange(location: start, length: ns.length - start))
            guard r.location != NSNotFound else { return result }
            result.append(r); start = NSMaxRange(r)
        }
    }

    private func highlight(_ layout: NSLayoutManager?, at index: Int) -> NSColor? {
        layout?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    private func pageLayout(_ reader: ReaderViewController) -> NSLayoutManager? {
        reader.visiblePageTextViews.first?.layoutManager
    }

    private func findField(_ window: NSWindow) throws -> DocumentFindField {
        let toolbar = try XCTUnwrap(window.toolbar)
        return try XCTUnwrap(toolbar.items.compactMap { $0.view as? DocumentFindField }.first)
    }

    func testHeaderStartsWithTheFindFieldAndHasNoFindButton() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let toolbar = try XCTUnwrap(window.toolbar as? ReaderToolbar)
        let ids = toolbar.toolbarDefaultItemIdentifiers(toolbar).map(\.rawValue)

        XCTAssertEqual(ids.first, "documentFind", "검색창은 헤더 맨 왼쪽에 있다")
        XCTAssertFalse(ids.contains("find"), "돋보기 버튼은 없어졌다")
    }

    func testCommandFFocusesTheHeaderFieldAndFindingKeepsThatFocus() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        let field = try findField(window)

        controller.focusDocumentFind(nil)
        XCTAssertTrue(field.currentEditor() != nil, "⌘F 는 헤더 검색창으로 간다")
        let responder = window.firstResponder

        controller.documentFinder.search("등대")
        controller.documentFinder.move(forward: true)

        XCTAssertEqual(reader.findMatches.count, 120)
        XCTAssertTrue(window.firstResponder === responder, "검색창에서 계속 입력·Enter 할 수 있어야 한다")
    }

    func testFindingRevealsMatchesOnLaterPagesAndWraps() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        let finder = controller.documentFinder
        finder.search("등대")
        let all = matches("등대", in: reader.findableString)
        XCTAssertEqual(reader.findableString, doc.content.string, "찾기는 보이는 페이지가 아니라 문서 전체를 대상으로 한다")
        XCTAssertEqual(finder.current, all[0])

        finder.move(forward: false)

        let last = try XCTUnwrap(all.last)
        XCTAssertEqual(finder.current, last, "처음에서 이전은 마지막 일치로 돈다")
        XCTAssertTrue(NSLocationInRange(last.location, reader.visibleCharacterRange), "일치가 있는 쪽으로 넘어가야 한다")

        finder.move(forward: true)
        XCTAssertEqual(finder.current, all[0], "마지막에서 다음은 처음 일치로 돈다")
    }

    /// 다음 쪽 첫 글자에서 시작하는 일치는 보이는 범위의 끝 위치와 같다. 커서 기준 판정으로는
    /// "보인다"가 되어 쪽을 넘기지 않았다.
    func testMatchStartingAtTheNextPageBoundaryTurnsThePage() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        let visible = reader.visibleCharacterRange
        let boundary = NSRange(location: NSMaxRange(visible), length: 2)
        XCTAssertLessThanOrEqual(NSMaxRange(boundary), (reader.findableString as NSString).length)

        reader.revealFindMatch(boundary)

        let after = reader.visibleCharacterRange
        XCTAssertGreaterThanOrEqual(NSMaxRange(after), NSMaxRange(boundary), "다음 쪽으로 넘어가야 한다")
        XCTAssertLessThanOrEqual(after.location, boundary.location)
    }

    /// 모든 일치를 강조하고 현재 일치는 더 진하게 칠한다. 쪽을 넘겨도 남고, 검색을 끝내면 지운다.
    func testAllMatchesStayHighlightedAcrossPagesUntilTheSearchEnds() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        let finder = controller.documentFinder
        finder.search("등대")
        finder.move(forward: true)
        let all = finder.matches

        XCTAssertEqual(highlight(pageLayout(reader), at: all[0].location), DocumentFinder.matchColor)
        XCTAssertEqual(highlight(pageLayout(reader), at: all[1].location), DocumentFinder.currentMatchColor)
        XCTAssertNil(highlight(pageLayout(reader), at: all[0].location + 3), "일치가 아닌 글자는 칠하지 않는다")

        finder.move(forward: false)
        finder.move(forward: false)
        let later = try XCTUnwrap(all.last)
        XCTAssertEqual(highlight(pageLayout(reader), at: later.location), DocumentFinder.currentMatchColor,
                       "넘어간 쪽에서도 강조가 보여야 한다")
        XCTAssertNotEqual(reader.selectedTextRange, later, "찾는 동안 선택하면 회색이 강조를 덮는다")

        controller.cancelDocumentFind()

        XCTAssertNil(highlight(pageLayout(reader), at: later.location), "Esc 는 강조를 지운다")
        XCTAssertEqual(try findField(window).stringValue, "")
        XCTAssertTrue(window.firstResponder is PageTextView, "Esc 는 본문으로 돌아간다")
        XCTAssertEqual(reader.selectedTextRange, later, "Esc 는 현재 일치를 선택해 둔다")
    }

    func testSearchFollowsTheViewAndClearsTheOldHighlights() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let finder = controller.documentFinder
        finder.search("등대")
        let first = try XCTUnwrap(finder.current)

        controller.applyReadingPageMode(.scroll)

        let editorLayout = controller.editorVC.textView.layoutManager
        XCTAssertEqual(finder.matches.count, 120, "보기를 바꿔도 검색은 이어진다")
        XCTAssertEqual(highlight(editorLayout, at: first.location), DocumentFinder.currentMatchColor)

        controller.showMarkdownSource(nil)
        let source = try XCTUnwrap(controller.sourcePreview?.textView)
        XCTAssertEqual(finder.matches.count, 120)
        XCTAssertNil(highlight(editorLayout, at: first.location), "떠난 화면의 강조는 지운다")
        XCTAssertNotNil(highlight(source.layoutManager, at: try XCTUnwrap(finder.current).location))
        controller.showMarkdownSource(nil)
    }

    func testEditingRefreshesMatchesWithoutMovingTheView() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        controller.applyReadingPageMode(.scroll)
        let finder = controller.documentFinder
        let text = try XCTUnwrap(controller.editorVC.textView)
        finder.search("등대")
        let count = finder.matches.count

        text.insertText("등대 ", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertEqual(finder.matches.count, count + 1, "본문이 바뀌면 일치도 다시 센다")
    }

    func testFindingIsCaseInsensitiveAndFindsNothingForEmptyQuery() {
        XCTAssertEqual(DocumentFinder.ranges(of: "abc", in: "ABC abc"), [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
        XCTAssertTrue(DocumentFinder.ranges(of: "", in: "abc").isEmpty)
    }

    /// 스크롤 조판의 가로 치수자는 본문 위에 떠 있다. 바꾸기 찾기 바가 열리면 그 아래로 내려가야
    /// 검색창을 가리지 않는다.
    func testScrollLayoutRulerMovesBelowTheReplaceBar() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        controller.applyReadingPageMode(.scroll)
        XCTAssertNil(controller.readerVC)
        let editor = try XCTUnwrap(controller.editorVC)
        let scrollView = try XCTUnwrap(editor.textView.enclosingScrollView)
        window.layoutIfNeeded()
        XCTAssertFalse(editor.ruler.isHidden, "전제: 읽기 조판의 치수자가 보인다")

        let proxy = NSMenuItem()
        proxy.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        editor.textView.performTextFinderAction(proxy)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(scrollView.isFindBarVisible)
        let bar = try XCTUnwrap(scrollView.findBarView)
        XCTAssertFalse(editor.ruler.frame.intersects(bar.frame), "치수자가 찾기 바를 가리면 안 된다")
    }
}
