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
                              lineHeight: CGFloat = 1.5,
                              weight: SettingsManager.ReadingWeight = .regular) -> NSAttributedString {
        let parsed = MarkdownSerializer.parse(sample)
        return ReaderMetrics.styled(parsed, scale: scale, font: font,
                                    lineHeightMultiple: lineHeight, weight: weight)
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

    // MARK: - 읽기 굵기가 문서를 오염시키지 않는가 (데이터 안전)
    //
    // 본문 굵기를 '굵게'로 두면 조판 폰트에 볼드 trait 이 생긴다. 직렬화는 볼드 trait 으로
    // `**` 를 판정하므로, 조판 굵기와 사용자의 `**볼드**` 를 구분하지 못하면 문서가 망가진다.

    func testBoldWeightDoesNotAddMarkupToPlainBody() {
        let before = MarkdownSerializer.serialize(MarkdownSerializer.parse(sample))
        let restored = ReaderMetrics.unstyled(styledSample(weight: .bold))
        XCTAssertEqual(MarkdownSerializer.serialize(restored), before,
                       "읽기 굵기 '굵게'가 원본 마크다운을 바꿔 놓았다")
    }

    func testBoldWeightDoesNotLeakIntoSerializationWhileStyled() {
        // 조판을 벗기지 않고 저장하는 경로 — 본문이 통째로 볼드 마크업이 되면 안 된다.
        let md = MarkdownSerializer.serialize(styledSample(weight: .bold))
        XCTAssertFalse(md.contains("**마지막 문단.**"),
                       "읽기 굵기가 평범한 본문을 볼드 마크업으로 만들었다")
        XCTAssertTrue(md.contains("**볼드**"),
                      "사용자가 준 볼드는 굵기 설정과 무관하게 살아 있어야 한다")
    }

    func testBoldWeightKeepsUserBoldDistinct() {
        // 굵게 조판이어도 '사용자 볼드'와 '조판 굵기'는 서로 다른 것으로 남아야 한다.
        let styled = styledSample(weight: .bold)
        let full = NSRange(location: 0, length: styled.length)
        var markedPlain = false, unmarkedUserBold = false
        styled.enumerateAttributes(in: full) { attrs, range, _ in
            let text = (styled.string as NSString).substring(with: range)
            if text.contains("마지막 문단") { markedPlain = attrs[.mdReaderBold] as? Bool == true }
            if text == "볼드" { unmarkedUserBold = attrs[.mdReaderBold] == nil }
        }
        XCTAssertTrue(markedPlain, "조판이 얹은 굵기에 표시가 없다 — 저장 시 볼드로 새어 나간다")
        XCTAssertTrue(unmarkedUserBold, "사용자 볼드에 조판 표시가 잘못 붙었다")
    }

    func testUnstyledRemovesReaderBoldMarker() {
        let restored = ReaderMetrics.unstyled(styledSample(weight: .bold))
        let full = NSRange(location: 0, length: restored.length)
        var found = false
        restored.enumerateAttribute(.mdReaderBold, in: full) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        XCTAssertFalse(found, "조판 표시가 문서에 남으면 안 된다")
    }

    func testTypedTextUnderBoldWeightDoesNotBecomeMarkup() {
        // 조판이 켜진 채 새로 친 글자 — .mdBaseFont 백업이 없는 가장 위험한 경로.
        let readerBold = ReaderMetrics.readerFont(family: .serif, size: 15 * 1.4,
                                                  traits: [], weight: .bold)
        let typed = NSAttributedString(string: "새로 친 글자",
                                       attributes: [.font: readerBold,
                                                    .mdBlockType: "body",
                                                    .mdReaderBold: true])
        let restored = ReaderMetrics.unstyled(typed)
        let f = restored.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertFalse(f.fontDescriptor.symbolicTraits.contains(.bold),
                       "읽기 굵기로 친 글자가 볼드로 굳었다 — 저장하면 **볼드** 가 된다")
        XCTAssertFalse(MarkdownSerializer.serialize(restored).contains("**"),
                       "새로 친 글자가 볼드 마크업으로 저장됐다")
    }

    func testRoundTripForEveryWeight() {
        let before = MarkdownSerializer.serialize(MarkdownSerializer.parse(sample))
        for w in SettingsManager.ReadingWeight.allCases {
            let restored = ReaderMetrics.unstyled(styledSample(weight: w))
            XCTAssertEqual(MarkdownSerializer.serialize(restored), before,
                           "굵기 \(w.rawValue) 왕복에서 마크다운이 변했다")
        }
    }

    // MARK: - 서체 목록

    func testAvailableFontsAlwaysIncludeAutoAndSans() {
        let fonts = ReaderMetrics.availableReadingFonts
        XCTAssertTrue(fonts.contains(.sans), "시스템 고딕은 언제나 고를 수 있어야 한다")
        XCTAssertTrue(fonts.contains(.serif), "자동 명조는 번들 글꼴이 있으므로 언제나 있어야 한다")
    }

    func testEveryAvailableFontResolvesToARealFont() {
        for f in ReaderMetrics.availableReadingFonts {
            let font = ReaderMetrics.readerFont(family: f, size: 16, traits: [])
            XCTAssertGreaterThan(font.pointSize, 0, "\(f.rawValue) 가 폰트로 풀리지 않는다")
        }
    }

    func testMissingFontFallsBackInsteadOfCrashing() {
        // 설정에 남았지만 머신에서 사라진 서체 — 자동 명조로 물러나야 한다.
        for f in SettingsManager.ReadingFont.allCases {
            let font = ReaderMetrics.readerFont(family: f, size: 16, traits: [.bold])
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold),
                          "\(f.rawValue) 폴백에서 볼드 trait 이 소실됐다")
        }
    }
}
