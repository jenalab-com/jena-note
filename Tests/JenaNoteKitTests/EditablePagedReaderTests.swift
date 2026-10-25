import AppKit
import XCTest
@testable import JenaNoteKit

final class EditablePagedReaderTests: XCTestCase {
    private var savedSettings: [String: Any] = [:]
    private let settingKeys = ["jn_readingPageMode", "jn_readingFontScale", "jn_readingFont",
                               "jn_readingWeight", "jn_readingLineSpacing"]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        for key in settingKeys { savedSettings[key] = UserDefaults.standard.object(forKey: key) }
        SettingsManager.shared.readingPageMode = .paged
        SettingsManager.shared.readingFontScale = 1
        SettingsManager.shared.readingFont = .sans
        SettingsManager.shared.readingWeight = .regular
        SettingsManager.shared.readingLineSpacing = 1.2
    }

    override func tearDown() {
        for key in settingKeys {
            if let value = savedSettings[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func makeReader(_ content: NSAttributedString) -> (ReaderViewController, NSWindow) {
        let reader = ReaderViewController(content: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = reader
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        reader.view.layoutSubtreeIfNeeded()
        reader.viewDidAppear()
        reader.view.layoutSubtreeIfNeeded()
        pump()
        XCTAssertGreaterThan(reader.view.bounds.height, 500, "실제 펼침면 크기로 조판해야 하는 테스트")
        return (reader, window)
    }

    private func pump(_ seconds: TimeInterval = 0.02) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func body(_ paragraphs: Int) -> NSAttributedString {
        NSAttributedString(string: (0..<paragraphs).map {
            "\($0) 한글 문장과 English, 👩🏽‍💻를 함께 읽고 고칩니다. 여러 줄로 이어지는 본문입니다.\n\n"
        }.joined(), attributes: [.font: MemoFont.body, .mdBlockType: "body",
                                .paragraphStyle: FormatCommands.bodyParagraphStyle()])
    }

    func testTypingKeepsPageAndTextSystemAndPublishesCleanContent() throws {
        let original = MarkdownSerializer.parse("# 제목\n\n**굵게** 그리고 본문")
        let (reader, window) = makeReader(original)
        defer { window.close() }
        let canonical = NSMutableAttributedString(attributedString: original)
        reader.onContentEdit = { range, replacement in
            canonical.replaceCharacters(in: range, with: replacement)
        }
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        let storage = tv.textStorage
        let lm = tv.layoutManager
        tv.setSelectedRange(NSRange(location: original.length, length: 0))
        window.makeFirstResponder(tv)
        tv.insertText(" 수정", replacementRange: tv.selectedRange())
        pump()
        XCTAssertEqual(reader.contentString, original.string + " 수정")
        XCTAssertEqual(canonical.string, reader.contentString)
        XCTAssertTrue(reader.visiblePageTextViews.first === tv, "입력 중인 뷰를 교체하면 커서/IME가 끊긴다")
        XCTAssertTrue(tv.textStorage === storage)
        XCTAssertTrue(tv.layoutManager === lm)
        XCTAssertEqual(SettingsManager.shared.readingPageMode, .paged)
        XCTAssertTrue(MarkdownSerializer.serialize(canonical).contains("**굵게**"))
        XCTAssertNil(canonical.attribute(.mdBaseFont, at: canonical.length - 1, effectiveRange: nil))
    }

    func testReaderBoldDoesNotTurnNewBodyTextIntoMarkdownBold() throws {
        SettingsManager.shared.readingWeight = .bold
        let original = MarkdownSerializer.parse("본문")
        let (reader, window) = makeReader(original)
        defer { window.close() }
        let canonical = NSMutableAttributedString(attributedString: original)
        reader.onContentEdit = { canonical.replaceCharacters(in: $0, with: $1) }
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        tv.setSelectedRange(NSRange(location: original.length, length: 0))
        tv.insertText(" 추가", replacementRange: tv.selectedRange())
        XCTAssertFalse(MarkdownSerializer.serialize(canonical).contains("**"))
    }

    func testMarkedTextSurvivesLayoutAndCommitsWithoutModeSwitch() throws {
        let (reader, window) = makeReader(body(40))
        defer { window.close() }
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        reader.view.layoutSubtreeIfNeeded()
        reader.goToNextPage()
        pump()
        XCTAssertTrue(tv.hasMarkedText())
        XCTAssertTrue(reader.visiblePageTextViews.contains { $0 === tv })
        XCTAssertTrue(window.firstResponder === tv)
        tv.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
        pump()
        XCTAssertFalse(tv.hasMarkedText())
        XCTAssertTrue(reader.contentString.hasPrefix("0한 "))
        XCTAssertEqual(SettingsManager.shared.readingPageMode, .paged)
    }

    func testLongDocumentDoesNotRepaginateToEndOnTyping() throws {
        let content = body(3000)
        let (reader, window) = makeReader(content)
        defer { window.close() }
        XCTAssertFalse(reader.isPaginationComplete)
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        let before = reader.paginationCalculationCount
        let start = CFAbsoluteTimeGetCurrent()
        tv.insertText("수정", replacementRange: NSRange(location: 1, length: 0))
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        pump()
        let visibleElapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertFalse(reader.isPaginationComplete)
        XCTAssertLessThan(reader.paginationCalculationCount - before, 8,
                          "화면 밖 페이지 전체를 입력마다 계산하지 않아야 한다")
        print("Paged reader typing: \(content.length) UTF16, \(elapsed) ms synchronous, \(visibleElapsed) ms including visible layout and 20ms run loop")
    }

    func testEmptyDocumentAndDeleteAllRemainEditable() throws {
        let (reader, window) = makeReader(NSAttributedString(string: ""))
        defer { window.close() }
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        tv.insertText("새 문서", replacementRange: NSRange(location: 0, length: 0))
        pump()
        XCTAssertEqual(reader.contentString, "새 문서")
        tv.setSelectedRange(NSRange(location: 0, length: tv.string.utf16.count))
        tv.deleteBackward(nil)
        pump()
        XCTAssertEqual(reader.contentString, "")
        XCTAssertEqual(reader.pageInfo.total, 1)
        tv.insertText("다시", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(reader.contentString, "다시")
    }

    func testPasteAcrossPageBoundaryKeepsCaretInVisiblePage() throws {
        let (reader, window) = makeReader(body(60))
        defer { window.close() }
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        window.makeFirstResponder(tv)
        let range = try XCTUnwrap(tv.layoutManager).glyphRange(for: try XCTUnwrap(tv.textContainer))
        let chars = try XCTUnwrap(tv.layoutManager).characterRange(forGlyphRange: range, actualGlyphRange: nil)
        let location = NSMaxRange(chars) - 1
        tv.insertText(String(repeating: "새 문단입니다.\n", count: 12),
                      replacementRange: NSRange(location: location, length: 0))
        pump()
        let focused = try XCTUnwrap(window.firstResponder as? PageTextView)
        XCTAssertTrue(reader.visiblePageTextViews.contains { $0 === focused })
        let caret = focused.selectedRange().location
        XCTAssertGreaterThanOrEqual(caret, reader.visibleCharacterRange.location)
        XCTAssertLessThanOrEqual(caret, NSMaxRange(reader.visibleCharacterRange))
        let lm = try XCTUnwrap(focused.layoutManager)
        let focusedRange = lm.characterRange(forGlyphRange: lm.glyphRange(for: try XCTUnwrap(focused.textContainer)),
                                             actualGlyphRange: nil)
        XCTAssertGreaterThanOrEqual(caret, focusedRange.location)
        XCTAssertLessThanOrEqual(caret, NSMaxRange(focusedRange))
    }

    func testDocumentOwnedUndoSurvivesReaderRemovalAndRedo() throws {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("원본"))
        let original = doc.content.string
        let (reader, window) = makeReader(doc.content)
        defer { window.close() }
        reader.onContentEdit = { [weak doc, weak reader] in
            doc?.replaceReaderContent(in: $0, with: $1, origin: reader)
        }
        let undo = try XCTUnwrap(doc.undoManager)
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        tv.insertText("추가", replacementRange: NSRange(location: 0, length: 0))
        pump()
        XCTAssertEqual(doc.content.string, "추가" + original)
        XCTAssertTrue(doc.isDocumentEdited)
        reader.setPageMode(.scroll)
        undo.undo()
        XCTAssertEqual(doc.content.string, original)
        undo.redo()
        XCTAssertEqual(doc.content.string, "추가" + original)
        let saved = try XCTUnwrap(String(data: doc.data(ofType: "net.daringfireball.markdown"), encoding: .utf8))
        XCTAssertTrue(saved.contains("추가원본"))
        doc.updateChangeCount(.changeCleared)
    }

    func testDocumentReplacementCancelsOldPaginationAndOldText() throws {
        let (reader, window) = makeReader(body(3000))
        defer { window.close() }
        reader.updateContent(MarkdownSerializer.parse("새 문서"))
        pump(0.1)
        XCTAssertTrue(reader.contentString.contains("새 문서"))
        XCTAssertFalse(reader.contentString.contains("English"))
        XCTAssertTrue(reader.isPaginationComplete)
        XCTAssertEqual(reader.pageInfo.total, 1)
    }

    func testRealDocumentWindowSavesAndUndoesAcrossReadingModes() throws {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("원본 본문"))
        let original = doc.content.string
        let controller = EditorWindowController()
        doc.addWindowController(controller)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.makeKeyAndOrderFront(nil)
        controller.editorVC.loadContent(of: doc)
        controller.applyReadingPageMode(.paged)
        window.layoutIfNeeded()
        pump()
        defer {
            doc.updateChangeCount(.changeCleared)
            window.close()
        }
        let reader = try XCTUnwrap(Mirror(reflecting: controller).descendant("readerVC") as? ReaderViewController)
        window.contentView?.layoutSubtreeIfNeeded()
        reader.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(reader.view.bounds.height, 100)
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        XCTAssertFalse(doc.isDocumentEdited, "페이지 표시와 유휴 조판은 문서를 수정하지 않는다")
        window.makeFirstResponder(tv)
        let undo = try XCTUnwrap(doc.undoManager)
        tv.insertText("추가 ", replacementRange: NSRange(location: 0, length: 0))
        pump()
        XCTAssertEqual(doc.content.string, "추가 " + original)
        XCTAssertTrue(doc.isDocumentEdited)
        let saved = try XCTUnwrap(String(data: doc.data(ofType: "net.daringfireball.markdown"), encoding: .utf8))
        XCTAssertTrue(saved.contains("추가 원본 본문"), "쪽수 계산 완료 전에 저장할 수 있어야 한다")

        XCTAssertTrue(tv.tryToPerform(#selector(UndoManager.undo), with: nil), "메뉴 Undo가 리더에 연결되어야 한다")
        XCTAssertEqual(doc.content.string, original)
        XCTAssertEqual(reader.contentString, original)
        XCTAssertFalse(doc.isDocumentEdited, "전체 수정 취소 후 저장 전 상태로 돌아와야 한다")
        undo.redo()
        XCTAssertEqual(reader.contentString, "추가 " + original)
        controller.applyReadingPageMode(.scroll)
        XCTAssertEqual(controller.editorVC.textView.string, "추가 " + original)
        undo.undo()
        XCTAssertEqual(controller.editorVC.textView.string, original)
        undo.redo()
        controller.applyReadingPageMode(.paged)
        pump()
        let reopened = try XCTUnwrap(Mirror(reflecting: controller).descendant("readerVC") as? ReaderViewController)
        XCTAssertEqual(reopened.contentString, "추가 " + original)
    }

    func testRepeatedLocalEditsMatchFreshPagination() throws {
        let (reader, window) = makeReader(body(80))
        defer { window.close() }
        for i in 0..<6 {
            let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
            window.makeFirstResponder(tv)
            tv.insertText("\(i) 추가 문장\n", replacementRange: NSRange(location: 2, length: i % 2))
            pump()
        }
        let live = try XCTUnwrap(Mirror(reflecting: reader).descendant("paginator") as? IncrementalPaginator)
        while !live.isComplete && !live.isBlocked { live.advance(maxPages: 2) }
        let size = try XCTUnwrap(live.containers.first).size
        let fresh = IncrementalPaginator(storage: NSTextStorage(attributedString: live.storage), pageSize: size)
        while !fresh.isComplete && !fresh.isBlocked { fresh.advance(maxPages: 2) }
        XCTAssertEqual(live.ranges, fresh.ranges, "실제 텍스트 뷰에 연결된 조판도 처음부터 나눈 결과와 같아야 한다")
    }

    func testBookmarkOffsetsFollowInsertionsAndDeletions() throws {
        let suite = "EditablePagedReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookmarkStore(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/reader-bookmark-test.md")
        store.add(ReadingAnchor.make(offset: 3, in: "앞부분 책갈피 본문"), for: url)
        store.adjustForEdit(in: NSRange(location: 0, length: 0), replacementLength: 4,
                            text: "추가문장앞부분 책갈피 본문", for: url)
        XCTAssertEqual(store.bookmarks(for: url).first?.characterOffset, 7)
        store.adjustForEdit(in: NSRange(location: 0, length: 4), replacementLength: 0,
                            text: "앞부분 책갈피 본문", for: url)
        XCTAssertEqual(store.bookmarks(for: url).first?.characterOffset, 3)
    }

    func testUndoDuringCompositionDoesNotOverwriteFollowingText() throws {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("abc"))
        let (reader, window) = makeReader(doc.content)
        defer {
            doc.updateChangeCount(.changeCleared)
            window.close()
        }
        reader.onContentEdit = { [weak doc, weak reader] in
            doc?.replaceReaderContent(in: $0, with: $1, origin: reader)
        }
        reader.documentUndoManager = { [weak doc] in doc?.undoManager }
        let token = NotificationCenter.default.addObserver(forName: .documentReaderContentChanged,
                                                           object: doc, queue: nil) { note in
            guard (note.userInfo?["origin"] as AnyObject?) !== reader,
                  let range = (note.userInfo?["range"] as? NSValue)?.rangeValue,
                  let replacement = note.userInfo?["replacement"] as? NSAttributedString else { return }
            reader.applyDocumentEdit(in: range, replacement: replacement)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let undo = try XCTUnwrap(doc.undoManager)
        undo.groupsByEvent = false
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        window.makeFirstResponder(tv)
        undo.beginUndoGrouping()
        tv.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                         replacementRange: NSRange(location: 1, length: 0))
        undo.endUndoGrouping()
        XCTAssertTrue(tv.hasMarkedText())
        reader.undo()
        XCTAssertFalse(tv.hasMarkedText(), "이전 조합 범위가 다음 확정 입력에 재사용되면 안 된다")
        XCTAssertEqual(doc.content.string, "abc\n")
        undo.beginUndoGrouping()
        tv.insertText("새", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        XCTAssertEqual(doc.content.string, "a새bc\n")
    }

    func testFontResizeKeepsEditingCaretOnItsNewPage() throws {
        let (reader, window) = makeReader(body(80))
        defer { window.close() }
        let tv = try XCTUnwrap(reader.visiblePageTextViews.first)
        let paginator = try XCTUnwrap(Mirror(reflecting: reader).descendant("paginator") as? IncrementalPaginator)
        let offset = NSMaxRange(try XCTUnwrap(paginator.ranges.first)) - 5
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: offset, length: 0))
        reader.setFontScale(2)
        let focused = try XCTUnwrap(window.firstResponder as? PageTextView)
        XCTAssertEqual(focused.selectedRange().location, offset)
        XCTAssertTrue(NSLocationInRange(offset, reader.visibleCharacterRange),
                      "글자 크기로 캐럿이 다음 페이지에 밀려도 편집 자리를 보여줘야 한다")
    }
}
