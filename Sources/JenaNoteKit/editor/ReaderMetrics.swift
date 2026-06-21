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
