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
                       lineHeightMultiple: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        let full = NSRange(location: 0, length: result.length)

        // 1) 폰트: 패밀리 교체 + 크기 배율 (trait 유지)
        var fontChanges: [(NSRange, NSFont)] = []
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let base = value as? NSFont else { return }
            let traits = base.fontDescriptor.symbolicTraits
            let newFont = readerFont(family: family, size: base.pointSize * scale, traits: traits)
            fontChanges.append((range, newFont))
        }
        for (range, f) in fontChanges {
            result.addAttribute(.font, value: f, range: range)
        }

        // 2) 행간: 모든 문단의 lineHeightMultiple 설정 (정렬 등 기존 속성 유지)
        var paraChanges: [(NSRange, NSParagraphStyle)] = []
        result.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let base = (value as? NSParagraphStyle) ?? .default
            let m = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            m.lineHeightMultiple = lineHeightMultiple
            paraChanges.append((range, m))
        }
        for (range, p) in paraChanges {
            result.addAttribute(.paragraphStyle, value: p, range: range)
        }

        return result
    }

    /// 패밀리·크기·trait에 맞는 읽기 모드 폰트. 명조는 AppleMyungjo, 고딕은 시스템 폰트.
    static func readerFont(family: SettingsManager.ReadingFont,
                           size: CGFloat,
                           traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let base: NSFont
        switch family {
        case .sans:
            base = NSFont.systemFont(ofSize: size)
        case .serif:
            base = NSFont(name: "AppleMyungjo", size: size) ?? NSFont.systemFont(ofSize: size)
        }
        var f = base
        let fm = NSFontManager.shared
        if traits.contains(.bold)   { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if traits.contains(.italic) { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    /// 페이지 높이를 줄 높이의 정수배로 내림 — 페이지 경계 줄 잘림 방지.
    static func snappedPageHeight(viewHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        guard lineHeight > 0 else { return 0 }
        let lines = floor(viewHeight / lineHeight)
        return max(lineHeight, lines * lineHeight)
    }

    /// 글자 수 × 글리프 advance = 컬럼 폭.
    static func columnWidth(charCount: Int, glyphAdvance: CGFloat) -> CGFloat {
        return CGFloat(charCount) * glyphAdvance
    }
}
