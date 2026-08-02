import XCTest
import AppKit
@testable import JenaNoteKit

/// 읽기 조판(styled) ↔ 원본 복원(unstyled)의 왕복 불변성.
///
/// 읽기 조판이 편집 가능해지면서 조판된 텍스트가 저장 경로를 타게 됐다. 조판이 서식
/// 정보를 한 글자라도 먹으면 파일이 실제로 망가지므로, "조판을 입혔다 벗기면 원래
/// 마크다운이 그대로 나온다"를 불변식으로 못 박는다.
final class ReaderLayoutRoundTripTests: XCTestCase {

    private let sample = """
    # 제목

    본문에 **볼드**와 *이탤릭*이 섞여 있고 `인라인 코드`도 있어요.

    ## 두 번째 제목

    - 목록 항목
    - **볼드 항목**

    > 인용문입니다

    마지막 문단.
    """

    private func styledSample(scale: CGFloat = 1.4,
                              font: SettingsManager.ReadingFont = .serif,
                              lineHeight: CGFloat = 1.5) -> NSAttributedString {
        let parsed = MarkdownSerializer.parse(sample)
        return ReaderMetrics.styled(parsed, scale: scale, font: font, lineHeightMultiple: lineHeight)
    }

    // MARK: - 왕복 불변성

    func testRoundTripPreservesMarkdown() {
        let parsed = MarkdownSerializer.parse(sample)
        let before = MarkdownSerializer.serialize(parsed)
        let restored = ReaderMetrics.unstyled(styledSample())
        XCTAssertEqual(MarkdownSerializer.serialize(restored), before)
    }

    func testRoundTripPreservesMarkdownForSansFont() {
        let parsed = MarkdownSerializer.parse(sample)
        let before = MarkdownSerializer.serialize(parsed)
        let restored = ReaderMetrics.unstyled(styledSample(scale: 2.0, font: .sans, lineHeight: 2.0))
        XCTAssertEqual(MarkdownSerializer.serialize(restored), before)
    }

    /// 조판된 채로 저장돼도 파일은 멀쩡해야 한다 — 조판 해제를 잊은 경로의 안전망.
    func testStyledTextStillSerializesWithBoldIntact() {
        let styled = styledSample()
        XCTAssertTrue(MarkdownSerializer.serialize(styled).contains("**볼드**"),
                      "명조 조판에서 볼드 trait 이 소실되면 저장 시 마크업이 사라진다")
    }

    func testRoundTripRestoresOriginalFonts() {
        let parsed = MarkdownSerializer.parse(sample)
        let restored = ReaderMetrics.unstyled(styledSample())
        XCTAssertEqual(parsed.length, restored.length)
        for i in 0..<parsed.length {
            let a = parsed.attribute(.font, at: i, effectiveRange: nil) as? NSFont
            let b = restored.attribute(.font, at: i, effectiveRange: nil) as? NSFont
            XCTAssertEqual(a?.fontName, b?.fontName, "offset \(i) 폰트 이름 불일치")
            XCTAssertEqual(a?.pointSize ?? 0, b?.pointSize ?? 0, accuracy: 0.01, "offset \(i) 크기 불일치")
        }
    }

    func testUnstyledRemovesBackupAttributes() {
        let restored = ReaderMetrics.unstyled(styledSample())
        let full = NSRange(location: 0, length: restored.length)
        var found = false
        restored.enumerateAttribute(.mdBaseFont, in: full) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        XCTAssertFalse(found, "백업 속성이 문서에 남으면 안 된다")
    }

    // MARK: - 배율 누적 방지

    func testRestylingUsesOriginalFontNotAccumulated() {
        // 조판된 텍스트에 다시 조판(배율 변경)해도 원본 기준으로 계산돼야 한다.
        let once = styledSample(scale: 1.4)
        let twice = ReaderMetrics.styled(once, scale: 2.0, font: .serif, lineHeightMultiple: 1.5)
        let direct = styledSample(scale: 2.0)
        for i in 0..<direct.length {
            let a = (twice.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
            let b = (direct.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
            XCTAssertEqual(a, b, accuracy: 0.01, "offset \(i): 배율이 누적됐다")
        }
    }

    // MARK: - 조판 중 새로 입력된 구간 (백업 없음)

    func testUnstyledRebuildsFontForTextTypedWhileStyled() {
        // 조판 폰트로 입력된 새 본문 — .mdBaseFont 백업이 없는 상태를 흉내낸다.
        let typed = NSMutableAttributedString(
            string: "새로 친 글자",
            attributes: [.font: ReaderMetrics.readerFont(family: .serif, size: 15 * 1.4, traits: []),
                         .mdBlockType: "body"])
        let restored = ReaderMetrics.unstyled(typed)
        let f = restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(f?.pointSize ?? 0, MemoFont.body.pointSize, accuracy: 0.01)
        XCTAssertEqual(f?.fontName, MemoFont.body.fontName)
    }

    func testUnstyledKeepsUserBoldForTextTypedWhileStyled() {
        let bold = ReaderMetrics.readerFont(family: .serif, size: 15 * 1.4, traits: [.bold])
        let typed = NSAttributedString(string: "굵게 친 글자",
                                       attributes: [.font: bold, .mdBlockType: "body"])
        let restored = ReaderMetrics.unstyled(typed)
        let f = restored.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.bold),
                      "조판 중 준 볼드가 원본 복원에서 사라졌다")
        XCTAssertEqual(f.pointSize, MemoFont.body.pointSize, accuracy: 0.01)
    }

    func testUnstyledRebuildsHeadingFont() {
        let styled = ReaderMetrics.readerFont(family: .serif, size: 28 * 1.4, traits: [.bold])
        let typed = NSAttributedString(string: "제목",
                                       attributes: [.font: styled, .mdBlockType: "h1"])
        let restored = ReaderMetrics.unstyled(typed)
        let f = restored.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(f.pointSize, MemoFont.h1.pointSize, accuracy: 0.01)
    }

    // MARK: - trait 폴백 (데이터 안전의 뿌리)

    func testReaderFontKeepsBoldTraitForEveryFamily() {
        for family in [SettingsManager.ReadingFont.serif, .sans] {
            let f = ReaderMetrics.readerFont(family: family, size: 18, traits: [.bold])
            XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.bold),
                          "\(family) 에서 볼드 trait 이 소실됐다")
        }
    }

    func testReaderFontKeepsItalicTraitForEveryFamily() {
        for family in [SettingsManager.ReadingFont.serif, .sans] {
            let f = ReaderMetrics.readerFont(family: family, size: 18, traits: [.italic])
            XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.italic),
                          "\(family) 에서 이탤릭 trait 이 소실됐다")
        }
    }

    func testReaderFontKeepsBothTraits() {
        let f = ReaderMetrics.readerFont(family: .serif, size: 18, traits: [.bold, .italic])
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testReaderFontWithoutTraitsStaysInRequestedFamily() {
        let plain = ReaderMetrics.readerFont(family: .serif, size: 18, traits: [])
        XCTAssertEqual(plain.fontName, ReaderMetrics.serifFont(size: 18).fontName)
    }
}
