import XCTest
import AppKit
@testable import JenaNoteKit

/// 읽기 조판이 켜진 채 Enter로 새 줄을 만들어도 새 글자가 조판(서체·배율·행간)을 입어야 한다.
///
/// 회귀 배경: `EditorTextView.insertNewline` 이 새 목록 기호(`•\t`)와 일반 줄의 타이핑 속성을
/// 원본 스타일(`MemoFont.body`)로 넣었다. 조판은 문서를 실을 때와 설정이 바뀔 때만 다시 입히므로,
/// 새 줄은 다음 재조판 전까지 시스템 서체·기본 행간으로 보였다. 저장 결과는 원본 스타일이라 정상이었다.
final class EditorNewlineReadingLayoutTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private let keys = ["jn_readingFontScale", "jn_readingFont", "jn_readingWeight", "jn_readingLineSpacing"]

    /// 조판이 원본과 확실히 다르도록 배율·서체·행간을 고정한다.
    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        SettingsManager.shared.readingFontScale = 1.4
        SettingsManager.shared.readingFont = .serif
        SettingsManager.shared.readingWeight = .regular
        SettingsManager.shared.readingLineSpacing = 1.6
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func makeEditor(_ markdown: String) -> EditorViewController {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse(markdown))
        let vc = EditorViewController()
        _ = vc.view
        vc.loadContent(of: doc)
        vc.setReadingLayout(true)
        return vc
    }

    /// 줄 끝(`after` 바로 뒤)을 클릭한 자리에서 Enter를 누르고 글자를 친다.
    /// 비교 문자열은 영문으로 둔다 — 한글은 테스트 환경 서체에 글리프가 없으면
    /// NSTextStorage 가 대체 서체로 갈아끼워 서체 비교가 무의미해진다.
    private func pressReturn(after: String, andType text: String, in vc: EditorViewController) {
        let tv = vc.textView!
        let line = ((tv.textStorage?.string ?? "") as NSString).range(of: after)
        XCTAssertNotEqual(line.location, NSNotFound, "\(after) 없음")
        tv.setSelectedRange(NSRange(location: NSMaxRange(line), length: 0))
        tv.insertNewline(nil)
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    private func attributes(_ vc: EditorViewController, of needle: String) -> [NSAttributedString.Key: Any] {
        let storage = vc.textView.textStorage!
        let range = (storage.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\(needle) 없음")
        return storage.attributes(at: range.location, effectiveRange: nil)
    }

    func testNewListItemKeepsReadingFont() {
        let vc = makeEditor("- first item")
        pressReturn(after: "first item", andType: "second item", in: vc)

        let existing = attributes(vc, of: "first")
        let typed = attributes(vc, of: "second")
        XCTAssertEqual((typed[.font] as? NSFont)?.fontName, (existing[.font] as? NSFont)?.fontName,
                       "새 목록 항목이 조판 서체를 잃었다")
        XCTAssertEqual((typed[.font] as? NSFont)?.pointSize ?? 0, (existing[.font] as? NSFont)?.pointSize ?? 0,
                       accuracy: 0.01, "새 목록 항목이 조판 배율을 잃었다")
        XCTAssertEqual((typed[.paragraphStyle] as? NSParagraphStyle)?.lineHeightMultiple,
                       (existing[.paragraphStyle] as? NSParagraphStyle)?.lineHeightMultiple,
                       "새 목록 항목이 조판 행간을 잃었다")

        // 새 목록 기호도 같은 서체여야 기호 폭·높이가 앞 항목과 맞는다.
        let storage = vc.textView.textStorage!
        let bullets = (storage.string as NSString)
        let second = bullets.range(of: "•", options: .backwards)
        let bulletFont = storage.attribute(.font, at: second.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(bulletFont?.fontName, (existing[.font] as? NSFont)?.fontName, "새 목록 기호가 조판 서체를 잃었다")
    }

    func testNewParagraphKeepsReadingFont() {
        let vc = makeEditor("First paragraph.")
        pressReturn(after: "First paragraph.", andType: "Next paragraph.", in: vc)

        let existing = attributes(vc, of: "First")
        let typed = attributes(vc, of: "Next")
        XCTAssertEqual((typed[.font] as? NSFont)?.fontName, (existing[.font] as? NSFont)?.fontName,
                       "새 문단이 조판 서체를 잃었다")
        XCTAssertEqual((typed[.font] as? NSFont)?.pointSize ?? 0, (existing[.font] as? NSFont)?.pointSize ?? 0,
                       accuracy: 0.01, "새 문단이 조판 배율을 잃었다")
        XCTAssertEqual((typed[.paragraphStyle] as? NSParagraphStyle)?.lineHeightMultiple,
                       (existing[.paragraphStyle] as? NSParagraphStyle)?.lineHeightMultiple,
                       "새 문단이 조판 행간을 잃었다")
    }

    /// 화면에 조판을 입혀도 저장 경로로는 원본 스타일 마크다운이 나가야 한다.
    func testNewLinesStillSerializeAsPlainMarkdown() {
        let list = makeEditor("- first item")
        pressReturn(after: "first item", andType: "second item", in: list)
        let listMarkdown = MarkdownSerializer.serialize(ReaderMetrics.unstyled(list.textView.textStorage!))
        XCTAssertTrue(listMarkdown.contains("- second item"), "목록 항목으로 저장되지 않았다: \(listMarkdown)")
        XCTAssertFalse(listMarkdown.contains("**"), "조판 굵기가 마크업으로 새었다: \(listMarkdown)")

        let body = makeEditor("First paragraph.")
        pressReturn(after: "First paragraph.", andType: "Next paragraph.", in: body)
        let bodyMarkdown = MarkdownSerializer.serialize(ReaderMetrics.unstyled(body.textView.textStorage!))
        XCTAssertTrue(bodyMarkdown.contains("Next paragraph."), bodyMarkdown)
        XCTAssertFalse(bodyMarkdown.contains("**"), "조판 굵기가 마크업으로 새었다: \(bodyMarkdown)")
    }

    /// 조판이 꺼져 있으면 지금처럼 원본 스타일로 새 줄을 만든다.
    func testNewParagraphWithoutReadingLayoutUsesBodyStyle() {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("First paragraph."))
        let vc = EditorViewController()
        _ = vc.view
        vc.loadContent(of: doc)
        pressReturn(after: "First paragraph.", andType: "Next paragraph.", in: vc)

        let typed = attributes(vc, of: "Next")
        XCTAssertEqual((typed[.font] as? NSFont)?.fontName, MemoFont.body.fontName)
    }
}
