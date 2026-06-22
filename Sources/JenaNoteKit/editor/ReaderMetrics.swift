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

        // 2) 행간: 문단별 lineHeightMultiple 설정 (정렬 등 기존 속성 유지).
        //    단, 이미지 첨부가 든 문단은 제외한다 — 이미지 줄에 배수를 곱하면
        //    줄 높이(=이미지 높이)에 배수가 곱해져 이미지 위아래로 큰 공백이 생긴다.
        let nsstr = result.string as NSString
        var loc = 0
        while loc < result.length {
            let paraRange = nsstr.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(paraRange)
            if rangeContainsAttachment(result, paraRange) { continue }
            let base = (result.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default
            let m = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            m.lineHeightMultiple = lineHeightMultiple
            result.addAttribute(.paragraphStyle, value: m, range: paraRange)
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

    /// 주어진 범위에 이미지 첨부(NSTextAttachment)가 하나라도 있는지.
    private static func rangeContainsAttachment(_ s: NSAttributedString, _ range: NSRange) -> Bool {
        var found = false
        s.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
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

    /// 모바일 읽기 폭 — iPhone 본문 폭(화면 ~390 − 좌우 여백) 느낌의 고정 컬럼 폭.
    /// "책"(글자수 기반)과 달리 폰트 크기와 무관한 고정 px다.
    static let mobileColumnWidth: CGFloat = 360

    /// 글자 수 × 글리프 advance = 컬럼 폭.
    static func columnWidth(charCount: Int, glyphAdvance: CGFloat) -> CGFloat {
        return CGFloat(charCount) * glyphAdvance
    }
}
