import AppKit

/// 읽기 모드의 순수 계산. AppKit 타입을 다루지만 UI 상태는 갖지 않는다.
enum ReaderMetrics {

    /// 모든 `.font` 속성에 배율을 곱한 새 attributed string을 반환한다.
    /// 원본은 변경하지 않는다 (읽기 모드 표시 전용).
    static func scaled(_ content: NSAttributedString, by scale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        let full = NSRange(location: 0, length: result.length)
        var changes: [(NSRange, NSFont)] = []
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
            changes.append((range, scaled))
        }
        for (range, font) in changes {
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }

    /// 읽기 모드 표시용 스타일을 적용한 새 attributed string을 반환한다.
    /// 폰트 패밀리(명조/고딕) 교체 + 크기 배율 + 줄 높이 배수. 원본은 변경하지 않는다.
    /// bold/italic trait과 문단 정렬 등 기존 속성은 보존한다.
    static func styled(_ content: NSAttributedString,
                       scale: CGFloat,
                       font family: SettingsManager.ReadingFont,
                       lineHeightMultiple: CGFloat,
                       maxImageWidth: CGFloat = .greatestFiniteMagnitude) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        let full = NSRange(location: 0, length: result.length)

        // 1) 폰트: 패밀리 교체 + 크기 배율 (trait 유지)
        //    원본 폰트를 .mdBaseFont 에 백업해 둔다 — 조판을 벗길 때 추측 없이 되돌리고,
        //    이미 조판된 텍스트를 다시 조판할 때도 배율이 누적되지 않게 하는 기준이 된다.
        var fontChanges: [(NSRange, NSFont, NSFont)] = []
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let current = value as? NSFont else { return }
            let origin = (result.attribute(.mdBaseFont, at: range.location, effectiveRange: nil) as? NSFont) ?? current
            let traits = origin.fontDescriptor.symbolicTraits
            let newFont = readerFont(family: family, size: origin.pointSize * scale, traits: traits)
            fontChanges.append((range, newFont, origin))
        }
        for (range, f, origin) in fontChanges {
            result.addAttribute(.font, value: f, range: range)
            result.addAttribute(.mdBaseFont, value: origin, range: range)
        }

        // 2) 행간: 문단별 lineHeightMultiple 설정 (정렬 등 기존 속성 유지).
        //    단, 이미지 첨부가 든 문단은 제외한다 — 이미지 줄에 배수를 곱하면
        //    줄 높이(=이미지 높이)에 배수가 곱해져 이미지 위아래로 큰 공백이 생긴다.
        let nsstr = result.string as NSString
        var loc = 0
        while loc < result.length {
            let paraRange = nsstr.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(paraRange)
            if rangeContainsAttachment(result, paraRange) { continue }
            let current = (result.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default
            let origin = (result.attribute(.mdBaseParagraph, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle) ?? current
            let m = (origin.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            m.lineHeightMultiple = lineHeightMultiple
            result.addAttribute(.paragraphStyle, value: m, range: paraRange)
            result.addAttribute(.mdBaseParagraph, value: origin, range: paraRange)
        }

        // 3) 이미지: 읽기 컬럼 폭에 맞춰 크기 조정.
        //    원본 첨부 객체는 에디터와 공유될 수 있으므로 복제본으로 교체한다(원본 불변).
        if maxImageWidth.isFinite {
            var attChanges: [(NSRange, NSTextAttachment)] = []
            result.enumerateAttribute(.attachment, in: full) { value, range, _ in
                guard let original = value as? NSTextAttachment, let image = original.image else { return }
                let copy = NSTextAttachment()
                copy.image = image
                let cap: CGFloat
                if let w = result.attribute(.mdImageWidth, at: range.location, effectiveRange: nil) as? Int, w > 0 {
                    cap = min(CGFloat(w), maxImageWidth)
                } else {
                    cap = maxImageWidth
                }
                copy.bounds = MarkdownSerializer.imageBounds(for: image.size, maxWidth: cap)
                attChanges.append((range, copy))
            }
            for (range, att) in attChanges {
                result.addAttribute(.attachment, value: att, range: range)
            }
        }

        return result
    }

    /// 읽기 조판을 벗겨 원본 스타일로 되돌린 새 attributed string. 원본은 변경하지 않는다.
    ///
    /// 백업(.mdBaseFont/.mdBaseParagraph)이 있으면 그대로 복원한다. 조판이 켜진 채 새로
    /// 입력돼 백업이 없는 구간은 블록 타입에서 기준 폰트를 다시 세우고, 사용자가 준
    /// 볼드·이탤릭 trait 만 얹는다 — 조판 서체·배율이 문서에 눌러앉지 않게 하는 자리다.
    /// 이미지 첨부 크기는 되돌리지 않는다 (에디터가 자기 폭에 맞춰 다시 잡는다).
    static func unstyled(_ content: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        let full = NSRange(location: 0, length: result.length)

        var fontChanges: [(NSRange, NSFont)] = []
        result.enumerateAttributes(in: full) { attrs, range, _ in
            guard let current = attrs[.font] as? NSFont else { return }
            if let backup = attrs[.mdBaseFont] as? NSFont {
                fontChanges.append((range, backup))
            } else {
                fontChanges.append((range, originalFont(for: attrs, styled: current)))
            }
        }
        for (range, f) in fontChanges {
            result.addAttribute(.font, value: f, range: range)
        }

        var paraChanges: [(NSRange, NSParagraphStyle)] = []
        result.enumerateAttribute(.mdBaseParagraph, in: full) { value, range, _ in
            guard let backup = value as? NSParagraphStyle else { return }
            paraChanges.append((range, backup))
        }
        for (range, p) in paraChanges {
            result.addAttribute(.paragraphStyle, value: p, range: range)
        }

        result.removeAttribute(.mdBaseFont, range: full)
        result.removeAttribute(.mdBaseParagraph, range: full)
        return result
    }

    /// 백업이 없는 구간의 원본 폰트를 블록 타입에서 되세운다.
    /// 볼드·이탤릭은 조판 폰트에 남아 있는 trait 을 그대로 물려받는다 — 조판이 trait 을
    /// 지키도록 폴백을 두는(readerFont) 이유가 여기서 값을 한다.
    static func originalFont(for attrs: [NSAttributedString.Key: Any], styled: NSFont) -> NSFont {
        let base: NSFont
        if attrs[.mdInlineCode] as? Bool == true {
            base = MemoFont.code
        } else {
            switch attrs[.mdBlockType] as? String {
            case "h1": base = MemoFont.h1
            case "h2": base = MemoFont.h2
            case "h3": base = MemoFont.h3
            case "codeblock": base = MemoFont.codeBlock
            default: base = MemoFont.body
            }
        }
        // 기준 폰트가 이미 가진 trait 은 블록의 성질이므로 다시 씌우지 않는다.
        let want = styled.fontDescriptor.symbolicTraits.subtracting(base.fontDescriptor.symbolicTraits)
        let userTraits = want.intersection([.bold, .italic])
        guard !userTraits.isEmpty else { return base }
        return applying(userTraits, to: base, size: base.pointSize)
    }

    /// 주어진 범위에 이미지 첨부(NSTextAttachment)가 하나라도 있는지.
    private static func rangeContainsAttachment(_ s: NSAttributedString, _ range: NSRange) -> Bool {
        var found = false
        s.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// 명조 후보 — 설치된 첫 서체를 쓴다. 볼드·이탤릭 변형이 있는 서체를 앞에 둔다.
    ///
    /// AppleMyungjo(macOS 기본 탑재)에는 볼드·이탤릭 변형이 없어 `NSFontManager` 가
    /// 원본을 그대로 돌려준다 — 즉 **trait 이 소실된다**. 마크다운 직렬화는 볼드·이탤릭을
    /// 폰트 trait 으로 판정하므로(MarkdownSerializer), 조판된 텍스트가 저장 경로를 타면
    /// `**볼드**` 마크업이 실제로 사라진다. 그래서 변형이 있는 명조를 먼저 찾는다.
    static let serifCandidates = ["NanumMyeongjo", "AppleMyungjo"]

    /// 설치된 첫 명조 후보. 하나도 없으면 시스템 폰트.
    static func serifFont(size: CGFloat) -> NSFont {
        for name in serifCandidates {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.systemFont(ofSize: size)
    }

    /// 패밀리·크기·trait에 맞는 읽기 모드 폰트.
    /// 요청한 trait 을 서체가 표현하지 못하면 표현 가능한 폰트로 내려가 **trait 을 지킨다**.
    static func readerFont(family: SettingsManager.ReadingFont,
                           size: CGFloat,
                           traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let base: NSFont
        switch family {
        case .sans:
            base = NSFont.systemFont(ofSize: size)
        case .serif:
            base = serifFont(size: size)
        }
        return applying(traits, to: base, size: size)
    }

    /// 폰트에 trait 을 씌운다. 서체가 그 변형을 갖고 있지 않아 trait 이 붙지 않으면,
    /// 서체 일관성보다 **서식 정보 보존**을 우선해 시스템 폰트로 내려간다.
    static func applying(_ traits: NSFontDescriptor.SymbolicTraits,
                         to base: NSFont,
                         size: CGFloat) -> NSFont {
        let fm = NSFontManager.shared
        var f = base
        if traits.contains(.bold)   { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if traits.contains(.italic) { f = fm.convert(f, toHaveTrait: .italicFontMask) }

        let got = f.fontDescriptor.symbolicTraits
        let lostBold   = traits.contains(.bold)   && !got.contains(.bold)
        let lostItalic = traits.contains(.italic) && !got.contains(.italic)
        guard lostBold || lostItalic else { return f }

        var sys = NSFont.systemFont(ofSize: size)
        if traits.contains(.bold)   { sys = fm.convert(sys, toHaveTrait: .boldFontMask) }
        if traits.contains(.italic) { sys = fm.convert(sys, toHaveTrait: .italicFontMask) }
        return sys
    }

    /// 페이지 높이를 줄 높이의 정수배로 내림 — 페이지 경계 줄 잘림 방지.
    static func snappedPageHeight(viewHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        guard lineHeight > 0 else { return 0 }
        let lines = floor(viewHeight / lineHeight)
        return max(lineHeight, lines * lineHeight)
    }

    /// 모바일 읽기 폭 — iPhone 본문 폭(화면 ~390 − 좌우 여백) 느낌의 고정 컬럼 폭.
    /// "책"(글자수 기반)과 달리 폰트 크기와 무관한 고정 px다.
    static let mobileColumnWidth: CGFloat = 360

    /// 글자 수 × 글리프 advance = 컬럼 폭.
    static func columnWidth(charCount: Int, glyphAdvance: CGFloat) -> CGFloat {
        return CGFloat(charCount) * glyphAdvance
    }

    /// 읽기 단(컬럼) 폭 프리셋. 저장하지 않으며 매 진입 시 .book 으로 시작한다.
    enum WidthMode {
        case book      // 글자수(readingLineLength) 기반
        case mobile    // 모바일 화면 폭(고정 px)
    }

    /// 현재 읽기 설정에서의 컬럼 폭. 리더와 에디터가 같은 조판 폭을 쓰도록 한곳에 둔다.
    static func columnWidth(mode: WidthMode,
                            scale: CGFloat,
                            family: SettingsManager.ReadingFont,
                            charCount: Int) -> CGFloat {
        switch mode {
        case .mobile:
            return mobileColumnWidth
        case .book:
            let probe = readerFont(family: family, size: MemoFont.body.pointSize * scale, traits: [])
            let advance = ("한" as NSString).size(withAttributes: [.font: probe]).width
            return columnWidth(charCount: charCount, glyphAdvance: advance)
        }
    }

    /// 저장된 읽기 설정을 그대로 읽어 컬럼 폭을 낸다.
    static func columnWidth(mode: WidthMode) -> CGFloat {
        let s = SettingsManager.shared
        return columnWidth(mode: mode, scale: s.readingFontScale,
                           family: s.readingFont, charCount: s.readingLineLength)
    }

    // MARK: - 펼침면(2페이지) 레이아웃

    /// 좌·우 페이지 사이 홈. 종이책 게터 느낌의 여백만 두고 구분선은 두지 않는다.
    static let spreadGutter: CGFloat = 56
    /// 펼침면 바깥쪽 최소 여백(한쪽).
    static let spreadSideMargin: CGFloat = 24
    /// 전환 임계의 히스테리시스 폭. 경계에서 창을 끌 때 1단↔2단이 뒤집히며
    /// 화면이 요동치는 것을 막는다.
    static let spreadHysteresis: CGFloat = 40

    /// 두 단이 나란히 들어가는 최소 호스트 폭.
    static func spreadMinWidth(columnWidth: CGFloat) -> CGFloat {
        return 2 * columnWidth + spreadGutter + 2 * spreadSideMargin
    }

    /// 지금 폭에서 펼침면(2페이지)으로 보여줄지. 이미 펼침면이면 조금 좁아져도
    /// 버티도록 임계를 낮춰 잡는다(히스테리시스).
    static func fitsSpread(hostWidth: CGFloat,
                           columnWidth: CGFloat,
                           currentlySpread: Bool) -> Bool {
        guard columnWidth > 0 else { return false }
        let enter = spreadMinWidth(columnWidth: columnWidth)
        let threshold = currentlySpread ? enter - spreadHysteresis : enter
        return hostWidth >= threshold
    }

    /// 주어진 페이지가 속한 펼침면의 왼쪽(짝수) 페이지 인덱스.
    static func spreadStart(page: Int) -> Int {
        guard page > 0 else { return 0 }
        return page - (page % 2)
    }
}
