import AppKit
import XCTest
@testable import JenaNoteKit

/// 페이지 조판에서도 문서 내 찾기가 macOS 찾기 바(NSTextFinder)로 동작해야 한다(ADR-0007).
///
/// 회귀 배경: 페이지 조판은 텍스트가 여러 페이지 뷰로 나뉘어 표준 찾기 바를 쓸 수 없어,
/// 돋보기가 알림창으로 검색어를 받아 다음 한 곳으로만 이동했다. 모든 일치 강조·개수·
/// 이전/다음 이동이 없었다.
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

    func testToolbarFindShowsNativeFindBarAboveThePages() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        let scrollView = try XCTUnwrap(reader.view as? NSScrollView)

        controller.editorVC.showFindBar(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(scrollView.isFindBarVisible, "페이지 조판의 돋보기가 찾기 바를 열어야 한다")
        let bar = try XCTUnwrap(scrollView.findBarView)
        let host = try XCTUnwrap(scrollView.subviews.first { $0 is PagedHostView })
        XCTAssertFalse(host.frame.intersects(bar.frame), "페이지가 찾기 바를 가리면 안 된다")
        XCTAssertGreaterThan(host.frame.height, 0)
    }

    func testFindClientExposesTheWholeDocumentAndRevealsMatchesOnLaterPages() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        let client = reader.findClient

        XCTAssertEqual(client.string, doc.content.string, "찾기는 보이는 페이지가 아니라 문서 전체를 대상으로 한다")
        let all = matches("등대", in: client.string)
        XCTAssertEqual(all.count, 120)

        let first = try XCTUnwrap(client.visibleCharacterRanges.first?.rangeValue)
        let target = try XCTUnwrap(all.last)
        XCTAssertGreaterThan(target.location, NSMaxRange(first), "전제: 마지막 일치는 첫 화면 밖에 있다")

        client.scrollRangeToVisible(target)
        let visible = try XCTUnwrap(client.visibleCharacterRanges.first?.rangeValue)
        XCTAssertTrue(NSLocationInRange(target.location, visible), "다음 일치가 있는 페이지로 넘어가야 한다")

        var effective = NSRange()
        let content = client.contentView(at: target.location, effectiveCharacterRange: &effective)
        XCTAssertTrue(content is PagedHostView, "쪽을 넘겨도 바뀌지 않는 오버레이를 내용 뷰로 내줘야 한다")
        XCTAssertTrue(NSLocationInRange(target.location, effective))
        let rects = try XCTUnwrap(client.rects(forCharacterRange: target))
        XCTAssertFalse(rects.isEmpty, "강조할 위치를 알려줘야 한다")
        for value in rects { XCTAssertTrue(content.bounds.intersects(value.rectValue)) }
    }

    /// 다음 쪽 첫 글자에서 시작하는 일치는 보이는 범위의 끝 위치와 같다. 커서 기준 판정으로는
    /// "보인다"가 되어 쪽을 넘기지 않았다.
    func testMatchStartingAtTheNextPageBoundaryTurnsThePage() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        let client = reader.findClient
        let visible = try XCTUnwrap(client.visibleCharacterRanges.first?.rangeValue)
        let boundary = NSRange(location: NSMaxRange(visible), length: 2)
        XCTAssertLessThanOrEqual(NSMaxRange(boundary), (client.string as NSString).length)

        client.scrollRangeToVisible(boundary)

        let after = try XCTUnwrap(client.visibleCharacterRanges.first?.rangeValue)
        XCTAssertGreaterThanOrEqual(NSMaxRange(after), NSMaxRange(boundary), "다음 쪽으로 넘어가야 한다")
        XCTAssertLessThanOrEqual(after.location, boundary.location)
    }

    func testFindSelectionMovesWithoutStealingFocusFromTheFindBar() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        let client = reader.findClient
        let target = try XCTUnwrap(matches("등대", in: client.string).dropFirst(60).first)
        let field = NSTextField()
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let responder = window.firstResponder

        client.selectedRanges = [NSValue(range: target)]
        client.scrollRangeToVisible(target)

        XCTAssertEqual(client.firstSelectedRange, target)
        XCTAssertTrue(window.firstResponder === responder, "검색창에서 계속 입력·Enter 할 수 있어야 한다")
        field.removeFromSuperview()
    }

    private func highlight(_ reader: ReaderViewController, at index: Int) -> NSColor? {
        guard let host = (reader.view as? NSScrollView)?.subviews.first(where: { $0 is PagedHostView }),
              let layout = host.subviews.compactMap({ $0 as? NSTextView }).first?.layoutManager else { return nil }
        return layout.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    /// 모든 일치를 강조하고 현재 일치는 더 진하게 칠한다. 쪽을 넘겨도 남고, 찾기 바를 닫으면 지운다.
    func testAllMatchesStayHighlightedAcrossPagesUntilTheFindBarCloses() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        let scrollView = try XCTUnwrap(reader.view as? NSScrollView)
        controller.editorVC.showFindBar(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let all = matches("등대", in: reader.findClient.string)

        reader.setFindMatches(all)
        reader.findClient.scrollRangeToVisible(all[1])

        XCTAssertEqual(highlight(reader, at: all[0].location), ReaderViewController.findMatchColor)
        XCTAssertEqual(highlight(reader, at: all[1].location), ReaderViewController.currentFindMatchColor)
        XCTAssertNil(highlight(reader, at: all[0].location + 3), "일치가 아닌 글자는 칠하지 않는다")

        let later = try XCTUnwrap(all.last)
        reader.findClient.scrollRangeToVisible(later)
        XCTAssertEqual(highlight(reader, at: later.location), ReaderViewController.currentFindMatchColor,
                       "넘어간 쪽에서도 강조가 보여야 한다")
        let otherOnLaterPage = try XCTUnwrap(all.dropLast().last)
        if NSLocationInRange(otherOnLaterPage.location, reader.visibleCharacterRange) {
            XCTAssertEqual(highlight(reader, at: otherOnLaterPage.location), ReaderViewController.findMatchColor)
        }

        reader.performFindAction(.hideFindInterface)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(scrollView.isFindBarVisible)
        XCTAssertNil(highlight(reader, at: later.location), "찾기를 닫으면 강조를 지운다")
    }

    /// 쪽을 넘기면 NSTextFinder 가 일치 목록을 한 번 비운다. 검색어가 그대로면 강조를 지키고,
    /// 검색어가 바뀌어 일치가 없으면 지운다.
    func testTransientEmptyMatchListKeepsHighlightsUntilTheQueryChanges() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        let reader = try XCTUnwrap(controller.readerVC)
        controller.editorVC.showFindBar(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let all = matches("등대", in: reader.findClient.string)

        reader.setFindMatches(all, query: "등대")
        reader.setFindMatches([], query: "등대")
        XCTAssertEqual(reader.findMatches, all, "같은 검색어의 일시적인 비움은 무시한다")
        XCTAssertEqual(highlight(reader, at: all[0].location), ReaderViewController.findMatchColor)

        reader.setFindMatches([], query: "등대지기")
        XCTAssertTrue(reader.findMatches.isEmpty, "검색어가 바뀌어 일치가 없으면 지운다")
        XCTAssertNil(highlight(reader, at: all[0].location))
    }

    /// 스크롤 조판의 가로 치수자는 본문 위에 떠 있다. 찾기 바가 열리면 그 아래로 내려가야
    /// 검색창을 가리지 않는다.
    func testScrollLayoutRulerMovesBelowTheFindBar() throws {
        let (doc, controller, window) = makeWindow()
        defer { close(doc, controller, window) }
        controller.applyReadingPageMode(.scroll)
        XCTAssertNil(controller.readerVC)
        let editor = try XCTUnwrap(controller.editorVC)
        let scrollView = try XCTUnwrap(editor.textView.enclosingScrollView)
        window.layoutIfNeeded()
        XCTAssertFalse(editor.ruler.isHidden, "전제: 읽기 조판의 치수자가 보인다")

        editor.showFindBar(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(scrollView.isFindBarVisible)
        let bar = try XCTUnwrap(scrollView.findBarView)
        XCTAssertFalse(editor.ruler.frame.intersects(bar.frame), "치수자가 찾기 바를 가리면 안 된다")
    }
}
