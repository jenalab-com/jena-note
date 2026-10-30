import AppKit
import XCTest
@testable import JenaNoteKit

/// 치수자와 페이지 여백 — 순수 계산, 끌기, 페이지/스크롤 배치.
final class PageRulerTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private let keys = ["jn_readingPageMode", "jn_readingFontScale", "jn_readingFont",
                        "jn_readingWeight", "jn_readingLineSpacing", "jn_readingLineLength",
                        "jn_readingPageMarginLeft", "jn_readingPageMarginRight", "jn_readingPageWidth", "jn_documentPaperSize"]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        let s = SettingsManager.shared
        s.readingPageMode = .paged
        s.readingFontScale = 1
        s.readingFont = .sans
        s.readingWeight = .regular
        s.readingLineSpacing = 1.2
        s.readingLineLength = 35
        s.readingPageMarginLeft = 0
        s.readingPageMarginRight = 0
        s.readingPageWidth = 0
        UserDefaults.standard.removeObject(forKey: "jn_documentPaperSize")
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval = 0.02) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func body(_ paragraphs: Int) -> NSAttributedString {
        NSAttributedString(string: (0..<paragraphs).map {
            "\($0) 치수자로 여백을 잡고 페이지 안에서 글을 고칩니다. 여러 줄로 이어지는 본문입니다.\n\n"
        }.joined(), attributes: [.font: MemoFont.body, .mdBlockType: "body",
                                .paragraphStyle: FormatCommands.bodyParagraphStyle()])
    }

    private func makeReader(_ content: NSAttributedString, width: CGFloat) -> (ReaderViewController, NSWindow) {
        let reader = ReaderViewController(content: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = reader
        window.setContentSize(NSSize(width: width, height: 760))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        reader.view.layoutSubtreeIfNeeded()
        reader.viewDidAppear()
        reader.view.layoutSubtreeIfNeeded()
        pump()
        return (reader, window)
    }

    func testPaperDimensionsAndFixedMarginsDoNotResizePaper() {
        DocumentPaperSize.selected = .a4
        XCTAssertEqual(ReaderMetrics.columnWidth(mode: .book), 210 * 72 / 25.4, accuracy: 0.01)
        let ruler = PageRulerView(frame: NSRect(x: 0, y: 0, width: ReaderMetrics.columnWidth(mode: .book), height: 18))
        ruler.canGrowPage = false
        ruler.setMargins(left: 30, right: 40)
        let width = ruler.pageWidth
        ruler.simulateDrag(handleAtLeft: true, dx: -100)
        XCTAssertEqual(ruler.pageWidth, width)
        XCTAssertEqual(ruler.leftMargin, 0)
        ruler.simulateDrag(handleAtLeft: false, dx: -50)
        XCTAssertEqual(ruler.pageWidth, width)
        XCTAssertGreaterThan(ruler.rightMargin, 40)
        XCTAssertEqual(DocumentPaperSize.b5.millimeters?.width, 176)
        XCTAssertEqual(DocumentPaperSize.jisB5.millimeters?.width, 182)
    }

    func testFixedPaperScrollLayoutKeepsWidthAndAsymmetricMargins() {
        DocumentPaperSize.selected = .b3
        let editor = EditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 600, height: 700))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        pump()
        defer { window.close() }
        editor.setReadingLayout(true)
        editor.setPageMargins(left: 40, right: 80)
        editor.view.layoutSubtreeIfNeeded()
        let width = DocumentPaperSize.b3.points!.width
        XCTAssertEqual(editor.ruler.pageWidth, width, accuracy: 0.01)
        XCTAssertFalse(editor.ruler.canGrowPage)
        XCTAssertTrue(editor.ruler.usesPaperOrigin)
        XCTAssertEqual(editor.textView.textContainer!.containerSize.width, width - 120, accuracy: 0.01)
        XCTAssertEqual(editor.textView.textContainerOrigin.x - editor.ruler.frame.minX, 40, accuracy: 0.01)
        editor.resetPageLayout()
        XCTAssertEqual(editor.ruler.pageWidth, width, accuracy: 0.01)
        XCTAssertEqual(DocumentPaperSize.selected, .b3)
        DocumentPaperSize.selected = .automatic
        XCTAssertTrue(editor.textView.textContainer!.widthTracksTextView)
    }

    func testPagedPaperRetainsPhysicalSizeInSmallWindow() {
        DocumentPaperSize.selected = .b3
        let (reader, window) = makeReader(body(5), width: 600)
        defer { window.close() }
        XCTAssertEqual(reader.currentPageWidth, DocumentPaperSize.b3.points!.width, accuracy: 0.01)
        XCTAssertFalse(reader.visiblePageRulers.isEmpty)
        XCTAssertTrue(reader.visiblePageRulers.allSatisfy { !$0.canGrowPage && $0.usesPaperOrigin })
        reader.setPageMargins(left: 50, right: 80)
        XCTAssertEqual(reader.currentPageWidth, DocumentPaperSize.b3.points!.width, accuracy: 0.01)
        reader.resetPageLayout()
        XCTAssertEqual(DocumentPaperSize.selected, .b3)
        XCTAssertEqual(reader.currentPageMargins.left, 0)
    }

    // MARK: - 순수 계산

    func testSnapRoundsToQuarterCentimeterAndNeverNegative() {
        let cm = ReaderMetrics.pointsPerCentimeter
        XCTAssertEqual(ReaderMetrics.snappedMargin(cm * 1.1), cm * 1.0, accuracy: 0.001)
        XCTAssertEqual(ReaderMetrics.snappedMargin(cm * 1.2), cm * 1.25, accuracy: 0.001)
        XCTAssertEqual(ReaderMetrics.snappedMargin(-30), 0)
    }

    func testClampKeepsMinimumTextWidthAndYieldsRightFirst() {
        let m = ReaderMetrics.clampedMargins(left: 300, right: 300, pageWidth: 500)
        XCTAssertEqual(m.left, 300)
        XCTAssertEqual(m.right, 80, "왼쪽을 지키고 오른쪽이 양보해 최소 글 폭 120 을 남긴다")
        XCTAssertEqual(ReaderMetrics.textWidth(pageWidth: 500, left: 300, right: 300), 120)
        let tiny = ReaderMetrics.clampedMargins(left: 50, right: 50, pageWidth: 100)
        XCTAssertEqual(tiny.left, 0); XCTAssertEqual(tiny.right, 0)
        XCTAssertEqual(ReaderMetrics.textWidth(pageWidth: 100, left: 50, right: 50), 100,
                       "최소 폭보다 좁은 페이지는 페이지 폭 전체가 글 영역")
        XCTAssertEqual(ReaderMetrics.textWidth(pageWidth: 500, left: 0, right: 0), 500)
    }

    // MARK: - 치수자 뷰

    func testDragSnapsCommitsOnceAndStopsAtOppositeMargin() {
        let ruler = PageRulerView(frame: NSRect(x: 0, y: 0, width: 400, height: PageRulerView.height))
        var changing: [(CGFloat, CGFloat)] = []
        var committed: [(CGFloat, CGFloat)] = []
        ruler.onMarginsChanging = { changing.append(($0, $1)) }
        ruler.onCommitted = { committed.append(($1, $2)) }
        ruler.canGrowPage = false
        let cm = ReaderMetrics.pointsPerCentimeter

        ruler.simulateDrag(handleAtLeft: true, dx: cm * 1.1)
        XCTAssertEqual(ruler.leftMargin, cm * 1.0, accuracy: 0.001)
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(changing.count, 1)

        ruler.simulateDrag(handleAtLeft: false, dx: -cm * 2)
        XCTAssertEqual(ruler.rightMargin, cm * 2, accuracy: 0.001)
        XCTAssertEqual(committed.count, 2)

        // 글 최소 폭 너머로 밀면 반대쪽을 건드리지 않고 한계에서 멈춘다.
        ruler.simulateDrag(handleAtLeft: false, dx: -1000)
        XCTAssertEqual(ruler.leftMargin, cm * 1.0, accuracy: 0.001, "반대쪽 여백은 밀리지 않는다")
        XCTAssertEqual(ruler.rightMargin, 400 - ReaderMetrics.minimumTextWidth - cm * 1.0, accuracy: 0.001)
        XCTAssertEqual(committed.count, 3)
        ruler.simulateDrag(handleAtLeft: true, dx: 1000)
        XCTAssertEqual(ruler.leftMargin, cm * 1.0, accuracy: 0.001, "왼쪽도 한계에서 멈춘다")
        XCTAssertEqual(committed.count, 3, "값이 그대로면 알리지 않는다")

        ruler.simulateDrag(handleAtLeft: true, dx: 0)
        XCTAssertEqual(committed.count, 3)
    }

    func testDraggingOutwardGrowsThePageUpToTheLimit() {
        let ruler = PageRulerView(frame: NSRect(x: 100, y: 0, width: 400, height: PageRulerView.height))
        ruler.maxPageWidth = 500
        var committed: [(CGFloat, CGFloat, CGFloat)] = []
        ruler.onCommitted = { committed.append(($0, $1, $2)) }
        let cm = ReaderMetrics.pointsPerCentimeter

        // 왼쪽 핸들을 바깥으로 1cm: 여백은 0 그대로, 페이지가 왼쪽으로 1cm 넓어진다.
        ruler.simulateDrag(handleAtLeft: true, dx: -cm)
        XCTAssertEqual(ruler.frame.width, 400 + cm, accuracy: 0.01)
        XCTAssertEqual(ruler.frame.minX, 100 - cm, accuracy: 0.01)
        XCTAssertEqual(ruler.leftMargin, 0)
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed[0].0, 400 + cm, accuracy: 0.01)

        // 오른쪽 핸들을 한도 너머로: 500 에서 멈춘다.
        ruler.simulateDrag(handleAtLeft: false, dx: 1000)
        XCTAssertEqual(ruler.frame.width, 500, accuracy: 0.01)
        XCTAssertEqual(ruler.frame.minX, 100 - cm, accuracy: 0.01, "오른쪽으로 넓히면 왼쪽 끝은 그대로")
        XCTAssertEqual(committed.count, 2)

        // 여백이 있으면 먼저 여백을 0 까지 줄이고 그 다음부터 넓힌다.
        ruler.setMargins(left: cm, right: 0)
        ruler.maxPageWidth = 600
        ruler.simulateDrag(handleAtLeft: true, dx: -2 * cm)
        XCTAssertEqual(ruler.leftMargin, 0)
        XCTAssertEqual(ruler.frame.width, 500 + cm, accuracy: 0.01)

        // 고정 프리셋(모바일)에서는 넓어지지 않는다.
        ruler.canGrowPage = false
        ruler.simulateDrag(handleAtLeft: false, dx: 100)
        XCTAssertEqual(ruler.frame.width, 500 + cm, accuracy: 0.01)
        XCTAssertEqual(committed.count, 3)
    }

    func testNarrowerPageTrimsStoredMarginsOnTheRuler() {
        let ruler = PageRulerView(frame: NSRect(x: 0, y: 0, width: 400, height: PageRulerView.height))
        ruler.setMargins(left: 100, right: 100)
        ruler.setFrameSize(NSSize(width: 250, height: PageRulerView.height))
        XCTAssertEqual(ruler.leftMargin, 100)
        XCTAssertEqual(ruler.rightMargin, 30)
    }

    // MARK: - 페이지 보기

    func testSinglePageHasOneRulerAndTextSitsInsideMargins() throws {
        let (reader, window) = makeReader(body(30), width: 700)
        defer { window.close() }
        XCTAssertEqual(reader.visiblePageTextViews.count, 1)
        XCTAssertEqual(reader.visiblePageRulers.count, 1)
        let ruler = try XCTUnwrap(reader.visiblePageRulers.first)
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        XCTAssertEqual(tv.frame.minX, ruler.frame.minX, accuracy: 0.5, "여백 0 이면 글과 페이지가 같은 자리에서 시작")
        XCTAssertEqual(tv.frame.width, ruler.frame.width, accuracy: 0.5)
        XCTAssertLessThan(ruler.frame.maxY, tv.frame.minY, "치수자는 글 위에 있다")

        let before = tv.textContainer?.size.width ?? 0
        ruler.simulateDrag(handleAtLeft: true, dx: 40)
        ruler.simulateDrag(handleAtLeft: false, dx: -20)
        reader.view.layoutSubtreeIfNeeded()
        pump()
        let margins = reader.currentPageMargins
        XCTAssertEqual(margins.left, ReaderMetrics.snappedMargin(40), accuracy: 0.001)
        XCTAssertEqual(margins.right, ReaderMetrics.snappedMargin(20), accuracy: 0.001)
        XCTAssertEqual(SettingsManager.shared.readingPageMarginLeft, margins.left, accuracy: 0.001, "여백은 저장된다")
        XCTAssertEqual(SettingsManager.shared.readingPageMarginRight, margins.right, accuracy: 0.001)

        let tv2 = try XCTUnwrap(reader.visiblePageTextViews.first)
        let ruler2 = try XCTUnwrap(reader.visiblePageRulers.first)
        XCTAssertEqual(tv2.frame.minX, ruler2.frame.minX + margins.left, accuracy: 0.5)
        XCTAssertEqual(tv2.frame.width, ruler2.frame.width - margins.left - margins.right, accuracy: 1)
        XCTAssertEqual(tv2.textContainer?.size.width ?? 0, before - margins.left - margins.right, accuracy: 1,
                       "글 영역이 줄어든 만큼 재조판된다")
        XCTAssertEqual(ruler2.leftMargin, margins.left, accuracy: 0.001)
    }

    func testSpreadHasRulerPerPageAndTheyMoveTogether() throws {
        let (reader, window) = makeReader(body(60), width: 1400)
        defer { window.close() }
        XCTAssertEqual(reader.visiblePageTextViews.count, 2, "넓은 창은 펼침면")
        XCTAssertEqual(reader.visiblePageRulers.count, 2)
        let rulers = reader.visiblePageRulers
        let pages = reader.visiblePageTextViews
        for (ruler, tv) in zip(rulers, pages) {
            XCTAssertEqual(ruler.frame.minX, tv.frame.minX, accuracy: 0.5)
        }
        XCTAssertGreaterThan(rulers[1].frame.minX, rulers[0].frame.maxX, "오른쪽 면의 치수자는 오른쪽 페이지 위")

        rulers[0].simulateDrag(handleAtLeft: true, dx: 30)
        reader.view.layoutSubtreeIfNeeded()
        pump()
        let expected = ReaderMetrics.snappedMargin(30)
        XCTAssertEqual(reader.visiblePageRulers.count, 2)
        for ruler in reader.visiblePageRulers {
            XCTAssertEqual(ruler.leftMargin, expected, accuracy: 0.001, "두 치수자는 같은 여백을 보여준다")
        }
        for (ruler, tv) in zip(reader.visiblePageRulers, reader.visiblePageTextViews) {
            XCTAssertEqual(tv.frame.minX, ruler.frame.minX + expected, accuracy: 0.5)
        }

        // 창이 좁아져 낱쪽이 되면 치수자도 하나만 남는다.
        window.setContentSize(NSSize(width: 700, height: 760))
        window.layoutIfNeeded()
        reader.view.layoutSubtreeIfNeeded()
        pump()
        XCTAssertEqual(reader.visiblePageTextViews.count, 1)
        XCTAssertEqual(reader.visiblePageRulers.count, 1)
    }

    func testGrowingPageInReaderRepaginatesWiderAndDoubleClickResets() throws {
        let (reader, window) = makeReader(body(30), width: 900)
        defer { window.close() }
        XCTAssertEqual(reader.visiblePageTextViews.count, 1)
        let autoWidth = reader.currentPageWidth
        let ruler = try XCTUnwrap(reader.visiblePageRulers.first)
        XCTAssertTrue(ruler.canGrowPage)
        XCTAssertEqual(ruler.maxPageWidth, 900 - 2 * ReaderMetrics.spreadSideMargin, accuracy: 0.5)

        ruler.simulateDrag(handleAtLeft: false, dx: 100)
        reader.view.layoutSubtreeIfNeeded()
        pump()
        let grown = ReaderMetrics.snappedMargin(100)
        XCTAssertEqual(reader.currentPageWidth, autoWidth + grown, accuracy: 0.5)
        XCTAssertEqual(SettingsManager.shared.readingPageWidth, autoWidth + grown, accuracy: 0.5, "넓힌 폭은 저장된다")
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        XCTAssertEqual(tv.frame.width, autoWidth + grown, accuracy: 1, "글 영역도 그만큼 넓어진다")
        let r2 = try XCTUnwrap(reader.visiblePageRulers.first)
        XCTAssertEqual(r2.frame.width, autoWidth + grown, accuracy: 0.5)
        XCTAssertEqual(r2.frame.midX, 900 / 2, accuracy: 1, "넓어진 페이지도 가운데")

        // 모바일로 바꾸면 고정 360 이고 넓히기는 막힌다.
        reader.setWidthMode(.mobile)
        reader.view.layoutSubtreeIfNeeded()
        pump()
        XCTAssertEqual(reader.currentPageWidth, ReaderMetrics.mobileColumnWidth)
        XCTAssertFalse(try XCTUnwrap(reader.visiblePageRulers.first).canGrowPage)
        reader.setWidthMode(.book)
        reader.view.layoutSubtreeIfNeeded()
        pump()
        XCTAssertEqual(reader.currentPageWidth, autoWidth + grown, accuracy: 0.5, "책으로 돌아오면 넓힌 폭이 유지된다")

        reader.resetPageLayout()
        reader.view.layoutSubtreeIfNeeded()
        pump()
        XCTAssertEqual(reader.currentPageWidth, autoWidth, accuracy: 0.5)
        XCTAssertEqual(SettingsManager.shared.readingPageWidth, 0)
    }

    func testStoredMarginsApplyToFreshReaderAndSurviveMobileWidth() throws {
        SettingsManager.shared.readingPageMarginLeft = 200
        SettingsManager.shared.readingPageMarginRight = 200
        let (reader, window) = makeReader(body(10), width: 700)
        defer { window.close() }
        XCTAssertEqual(reader.currentPageMargins.left, 200)
        reader.setWidthMode(.mobile)
        reader.view.layoutSubtreeIfNeeded()
        pump()
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        XCTAssertGreaterThanOrEqual(tv.frame.width, ReaderMetrics.minimumTextWidth - 0.5,
                                    "모바일 폭(360)에 큰 여백이 저장돼 있어도 글은 사라지지 않는다")
        XCTAssertEqual(reader.currentPageMargins.left, 200)
        XCTAssertEqual(reader.currentPageMargins.right, 360 - 200 - ReaderMetrics.minimumTextWidth)
    }

    // MARK: - 스크롤 보기

    func testScrollEditorShowsFixedRulerAndMarginsNarrowTheColumn() throws {
        let editor = EditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 900, height: 600))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        editor.setReadingLayout(true)
        editor.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.view.bounds.width, 800)
        XCTAssertFalse(editor.ruler.isHidden)
        XCTAssertTrue(editor.ruler.superview === editor.view, "치수자는 스크롤 뷰에 고정돼 본문과 같이 흐르지 않는다")
        let page = ReaderMetrics.columnWidth(mode: .book)
        XCTAssertEqual(editor.ruler.frame.width, page, accuracy: 0.5)
        let insetBefore = editor.textView.textContainerInset.width
        XCTAssertEqual(editor.ruler.frame.minX, insetBefore, accuracy: 0.5)

        editor.ruler.simulateDrag(handleAtLeft: true, dx: 60)
        editor.view.layoutSubtreeIfNeeded()
        let left = ReaderMetrics.snappedMargin(60)
        XCTAssertEqual(SettingsManager.shared.readingPageMarginLeft, left, accuracy: 0.001)
        let inset = editor.textView.textContainerInset.width
        XCTAssertEqual(inset, insetBefore + left / 2, accuracy: 0.5, "글 영역이 좁아진 만큼 가운데로 모인다")
        XCTAssertEqual(editor.ruler.frame.minX, inset - left, accuracy: 0.5, "치수자의 글 시작점이 본문 시작점과 맞는다")

        editor.setReadingLayout(false)
        editor.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.ruler.isHidden)
    }
}
