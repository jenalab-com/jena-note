import XCTest
import AppKit
@testable import JenaNoteKit

/// 에디터가 윈도우에 붙어 있지 않아도 문서를 실을 수 있어야 한다.
///
/// 회귀 배경: `EditorViewController.document` 는 `view.window?.windowController?.document`
/// 를 타고 온다. 페이징 조판 동안 에디터는 split 에서 빠져 있어 window 가 nil 이고,
/// 그 사이 사이드바로 문서를 바꾸면 `loadDocumentContent()` 가 조용히 건너뛰어
/// **옛 문서가 에디터에 남는다**. 스크롤 조판으로 돌아오는 순간 그 옛 문서가 나타났다.
final class EditorDocumentLoadTests: XCTestCase {

    private func makeDocument(_ markdown: String) -> MarkdownDocument {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse(markdown))
        return doc
    }

    func testLoadContentWorksWithoutWindow() {
        let vc = EditorViewController()
        _ = vc.view     // loadView 트리거 — 윈도우에는 붙이지 않는다
        XCTAssertNil(vc.view.window, "이 테스트는 윈도우 없는 상태를 전제한다")

        vc.loadContent(of: makeDocument("# 새 문서\n\n본문이에요."))
        XCTAssertTrue(vc.textView.string.contains("새 문서"))
        XCTAssertTrue(vc.textView.string.contains("본문이에요"))
    }

    func testLoadContentReplacesPreviousDocument() {
        let vc = EditorViewController()
        _ = vc.view

        vc.loadContent(of: makeDocument("이전 문서"))
        XCTAssertTrue(vc.textView.string.contains("이전 문서"))

        vc.loadContent(of: makeDocument("새 문서"))
        XCTAssertFalse(vc.textView.string.contains("이전 문서"), "옛 문서가 남았다")
        XCTAssertTrue(vc.textView.string.contains("새 문서"))
    }

    /// 읽기 조판이 켜진 채 문서를 갈아도 조판이 유지돼야 한다.
    func testLoadContentKeepsReadingLayoutApplied() {
        let vc = EditorViewController()
        _ = vc.view
        vc.loadContent(of: makeDocument("첫 문서"))
        vc.setReadingLayout(true)

        vc.loadContent(of: makeDocument("**굵은** 새 문서"))

        guard vc.textView.textStorage?.length ?? 0 > 0 else { return XCTFail("내용이 비었다") }
        let font = vc.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        // 조판이 입혀졌다면 본문 기준 크기(15pt)가 아니라 배율이 곱해진 크기여야 한다.
        let expected = MemoFont.body.pointSize * SettingsManager.shared.readingFontScale
        XCTAssertEqual(font?.pointSize ?? 0, expected, accuracy: 0.5,
                       "문서를 갈아끼운 뒤 읽기 조판이 풀렸다")
    }

    /// 조판이 켜진 채 문서를 갈아도 저장 경로로는 원본 스타일이 나가야 한다.
    func testStyledEditorStillYieldsCleanMarkdown() {
        let vc = EditorViewController()
        _ = vc.view
        vc.loadContent(of: makeDocument("**굵게** 그리고 *italic*"))
        vc.setReadingLayout(true)

        guard let storage = vc.textView.textStorage else { return XCTFail("스토리지 없음") }
        let markdown = MarkdownSerializer.serialize(ReaderMetrics.unstyled(storage))
        XCTAssertTrue(markdown.contains("**굵게**"), "볼드가 유실됐다: \(markdown)")
        XCTAssertTrue(markdown.contains("*italic*"), "이탤릭이 유실됐다: \(markdown)")
    }

    /// 알려진 결함(읽기 조판 이전부터 존재) — 한글 이탤릭은 NSTextStorage 를 거치며 사라진다.
    ///
    /// 시스템 이탤릭 폰트(.SFNS-RegularItalic)에는 한글 글리프가 없어, NSTextStorage 의
    /// attribute fixing 이 한글을 그릴 수 있는 폰트(.AppleSDGothicNeoI-Regular)로 갈아끼운다.
    /// 그 대체 폰트는 italic trait 을 보고하지 않으므로, 볼드·이탤릭을 폰트 trait 으로
    /// 판정하는 직렬화가 이탤릭을 놓친다. 확인한 한글 서체 4종 모두 같다 —
    /// **폰트 trait 으로는 한글 이탤릭을 표현할 수 없다.**
    ///
    /// 제대로 고치려면 이탤릭(과 볼드)을 폰트가 아니라 커스텀 속성으로 판정해야 한다
    /// (parse·serialize·FormatCommands 세 곳). 읽기 조판과는 독립된 문제라 분리해 둔다.
    /// 이 테스트가 실패하기 시작하면 결함이 고쳐진 것이므로 본 테스트를 지우면 된다.
    func testKnownIssue_HangulItalicLostThroughTextStorage() {
        let vc = EditorViewController()
        _ = vc.view
        vc.loadContent(of: makeDocument("*기울임*"))

        guard let storage = vc.textView.textStorage else { return XCTFail("스토리지 없음") }
        let markdown = MarkdownSerializer.serialize(storage)
        XCTAssertFalse(markdown.contains("*기울임*"),
                       "한글 이탤릭이 살아남았다 — 결함이 고쳐졌으니 이 테스트를 지울 것: \(markdown)")
    }

    /// 한글 볼드는 대체 폰트가 trait 을 유지하므로 안전하다 — 위 결함의 경계를 못박는다.
    func testHangulBoldSurvivesTextStorage() {
        let vc = EditorViewController()
        _ = vc.view
        vc.loadContent(of: makeDocument("**굵게**"))

        guard let storage = vc.textView.textStorage else { return XCTFail("스토리지 없음") }
        XCTAssertTrue(MarkdownSerializer.serialize(storage).contains("**굵게**"))
    }
}
