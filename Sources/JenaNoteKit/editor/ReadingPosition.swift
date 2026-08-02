import AppKit

/// 읽던 자리를 알려주고 되돌려놓을 수 있는 화면 (ADR-0008).
///
/// 읽기 조판이 편집 가능해지면서 "읽던 자리"의 주인이 둘이 됐다 — 스크롤 조판은
/// 에디터가, 페이징 조판은 리더 오버레이가 그린다. 이어읽기·책갈피는 어느 쪽이
/// 화면을 쥐고 있든 같은 방식으로 물어볼 수 있어야 하므로 이 얼굴로 통일한다.
protocol ReadingPositionProviding: AnyObject {
    /// 지금 화면 맨 위(페이징이면 현재 쪽 첫 글자)의 문자 오프셋.
    var currentCharacterOffset: Int { get }
    /// 지금 화면에 보이는 문자 범위. "이 화면에 이미 책갈피가 있나" 판정에 쓴다.
    var visibleCharacterRange: NSRange { get }
    /// 현재 조판 중인 원문 — 앵커의 문맥 스니펫을 뜨거나 되찾는 기준 텍스트.
    var contentString: String { get }
    /// 읽던 자리가 바뀌었을 때 알린다(코얼레싱). 저장 책임은 호출자에게 있다.
    var onPositionChanged: ((Int) -> Void)? { get set }
    /// 저장돼 있던 위치로 되돌린다.
    func restore(to offset: Int)
    /// 대기 중인 위치 알림을 즉시 흘려보낸다(모드 종료·문서 전환 직전용).
    func flushPositionChange()
}

/// 세로 스크롤 텍스트뷰에서 읽던 자리를 읽고 되돌리는 계산.
/// 에디터와 리더의 스크롤 조판이 같은 규칙을 쓰도록 한곳에 모았다.
enum ScrollReadingPosition {

    /// 화면 맨 윗줄의 문자 오프셋.
    static func offset(textView: NSTextView, scrollView: NSScrollView) -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              lm.numberOfGlyphs > 0 else { return 0 }
        // 뷰 좌표 → 텍스트 컨테이너 좌표 (상단 inset 만큼 어긋나 있다)
        let topY = scrollView.contentView.bounds.minY - textView.textContainerOrigin.y
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, topY)), in: tc)
        return lm.characterIndexForGlyph(at: glyph)
    }

    /// 주어진 오프셋이 화면 맨 위에 오도록 스크롤한다.
    static func scroll(textView: NSTextView, to offset: Int) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let length = textView.textStorage?.length, length > 0 else { return }
        if offset <= 0 { textView.scroll(.zero); return }
        // 길이 0 범위는 빈 사각형을 주는 경우가 있어 한 글자를 잡아 재본다.
        let loc = min(offset, length - 1)
        lm.ensureLayout(for: tc)
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 1),
                                   actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        let y = rect.minY + textView.textContainerOrigin.y
        textView.scroll(NSPoint(x: 0, y: max(0, y)))
    }

    /// 지금 화면에 보이는 문자 범위.
    static func visibleRange(textView: NSTextView, scrollView: NSScrollView) -> NSRange {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              lm.numberOfGlyphs > 0 else { return NSRange(location: 0, length: 0) }
        var rect = scrollView.contentView.bounds
        rect.origin.y -= textView.textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        return lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }
}
