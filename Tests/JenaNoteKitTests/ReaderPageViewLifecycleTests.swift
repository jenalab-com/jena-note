import XCTest
import AppKit
@testable import JenaNoteKit

/// 페이징 리더의 페이지뷰 수명 — "버린 페이지뷰가 텍스트 시스템에 남지 않는가".
///
/// 배경(2026-08-08 크래시): 페이징 조판은 하나의 `NSLayoutManager` 에 쪽마다
/// `NSTextContainer` 를 두고, 화면에 보이는 1~2쪽에만 `PageTextView` 를 붙였다 뗀다.
/// 그런데 AppKit 은 레이아웃 매니저가 텍스트뷰를 **비소유(`assign`) 포인터**로 기억한다
/// (`textViewForBeginningOfSelection` 등). 그래서 페이지뷰를 그냥 버리면 해제된 뒤에도
/// 죽은 포인터가 남고, 다음에 포커스가 옮겨가는 순간 `-[NSTextView updateRuler]` 가
/// 그 포인터에 `enclosingScrollView` 를 보내며 앱이 통째로 죽었다.
///
/// 이 테스트들은 그 경로를 그대로 밟는다 — 회귀가 나면 단언이 아니라 **프로세스가** 죽는다.
final class ReaderPageViewLifecycleTests: XCTestCase {

    /// 여러 쪽으로 나뉘기만 하면 되는 최소 분량 — 쪽 수를 키워도 검증되는 것은 같고
    /// 조판 비용만 커진다(쪽마다 컨테이너를 만들어 레이아웃을 잡으므로).
    private func longContent() -> NSAttributedString {
        let body = (1...40).map { "\($0)번째 문단입니다. 한글 본문을 길게 넣어 여러 쪽으로 나뉘게 만들어요." }
            .joined(separator: "\n\n")
        return MarkdownSerializer.parse("# 제목\n\n" + body)
    }

    private func makeReader() -> (ReaderViewController, NSWindow) {
        let reader = ReaderViewController(content: longContent())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // 손으로 만든 창은 close() 가 스스로 release 한다 — ARC 참조와 겹쳐 이중 해제가 된다.
        window.isReleasedWhenClosed = false
        window.contentViewController = reader
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        reader.view.layoutSubtreeIfNeeded()
        reader.viewDidAppear()
        reader.view.layoutSubtreeIfNeeded()
        return (reader, window)
    }

    private func pageViews(_ reader: ReaderViewController) -> [NSTextView] {
        (Mirror(reflecting: reader).descendant("pageViews") as? [NSTextView]) ?? []
    }

    /// 레이아웃 매니저가 기억하는 텍스트뷰는 지금 화면에 살아 있는 페이지뷰여야 한다.
    /// (죽은 포인터가 남아 있으면 이 프로퍼티를 읽는 것만으로 프로세스가 죽는다.)
    private func assertLayoutManagerHasNoDeadTextView(_ reader: ReaderViewController,
                                                      _ message: String,
                                                      file: StaticString = #filePath,
                                                      line: UInt = #line) {
        let live = pageViews(reader)
        guard let lm = live.first?.layoutManager else { return }
        let remembered = lm.textViewForBeginningOfSelection
        XCTAssertTrue(remembered == nil || live.contains { $0 === remembered },
                      message, file: file, line: line)
    }

    /// 쪽을 넘긴 뒤 포커스를 옮겨도 살아 있어야 한다 — 크래시 리포트의 그 경로.
    func testPageTurnThenFocusChangeDoesNotTouchDeadPageView() {
        var reader: ReaderViewController!
        var window: NSWindow!
        autoreleasepool {
            let made = makeReader()
            reader = made.0
            window = made.1
            // 사용자가 글자를 고른 상황 — 레이아웃 매니저가 이 뷰를 기억하게 만든다.
            pageViews(reader).first?.setSelectedRange(NSRange(location: 3, length: 5))
            for _ in 0..<3 { reader.goToNextPage() }
        }   // 버려진 페이지뷰가 여기서 해제된다

        assertLayoutManagerHasNoDeadTextView(reader, "쪽을 넘긴 뒤 죽은 페이지뷰가 남았다")

        // mouseDown → makeFirstResponder → resignFirstResponder → updateRuler 경로.
        let field = NSTextField(string: "focus")
        reader.view.addSubview(field)
        window.makeFirstResponder(field)
        XCTAssertTrue(window.firstResponder === field || window.firstResponder is NSTextView,
                      "포커스가 옮겨가지 않았다 — 테스트 전제가 무너졌다")
        window.close()
    }

    /// 조판을 다시 짜면(서체·배율 변경) 텍스트 시스템이 통째로 갈린다.
    /// 옛 페이지뷰를 그 전에 떼지 않으면 죽은 컨테이너를 짚게 된다.
    func testRebuildingPagesDoesNotLeaveDeadPageView() {
        var reader: ReaderViewController!
        var window: NSWindow!
        autoreleasepool {
            let made = makeReader()
            reader = made.0
            window = made.1
            pageViews(reader).first?.setSelectedRange(NSRange(location: 0, length: 4))
            reader.setFontScale(1.8)          // rebuildPages
            reader.setLineSpacing(2.0)        // rebuildPages
            reader.view.layoutSubtreeIfNeeded()
        }

        assertLayoutManagerHasNoDeadTextView(reader, "조판을 다시 짠 뒤 죽은 페이지뷰가 남았다")

        let field = NSTextField(string: "focus")
        reader.view.addSubview(field)
        window.makeFirstResponder(field)
        window.close()
    }

    /// 페이징을 걷어내고 스크롤 조판으로 돌아간 뒤에도 포커스 이동이 안전해야 한다.
    func testLeavingPagedModeThenFocusChangeIsSafe() {
        var reader: ReaderViewController!
        var window: NSWindow!
        autoreleasepool {
            let made = makeReader()
            reader = made.0
            window = made.1
            pageViews(reader).first?.setSelectedRange(NSRange(location: 1, length: 3))
            for _ in 0..<2 { reader.goToNextPage() }
            reader.setPageMode(.scroll)       // removePagedOverlay — 텍스트 시스템 통째 해제
        }

        XCTAssertTrue(pageViews(reader).isEmpty, "페이징을 걷어냈는데 페이지뷰가 남아 있다")

        let field = NSTextField(string: "focus")
        reader.view.addSubview(field)
        window.makeFirstResponder(field)
        window.close()
    }

    /// 쪽을 넘겨도 리더가 쥐고 있던 키보드 포커스는 새 페이지뷰로 따라가야 한다
    /// (떼어내기를 넣으면서 포커스 인계를 깨뜨리지 않았는지 — ←/→ 페이지 넘김이 여기 달려 있다).
    func testFocusFollowsNewPageAfterRebuild() {
        let (reader, window) = makeReader()
        defer { window.close() }
        XCTAssertTrue(pageViews(reader).contains { $0 === window.firstResponder },
                      "페이징 진입 시 페이지뷰가 포커스를 못 받았다")

        reader.setFontScale(1.6)              // rebuildPages — 페이지뷰가 갈린다
        reader.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(pageViews(reader).contains { $0 === window.firstResponder },
                      "조판을 다시 짠 뒤 포커스가 페이지뷰로 돌아오지 않았다 — ←/→ 가 먹지 않는다")
    }
}
