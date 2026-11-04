import AppKit

/// 페이지 조판을 NSTextFinder 한 문서로 보여주는 클라이언트 (ADR-0007).
///
/// 페이지 조판은 화면에 보이는 1~2쪽만 `PageTextView` 로 얹고 모든 쪽이 한 레이아웃
/// 관리자를 공유한다. 표준 찾기 바는 텍스트 뷰 하나를 전제하므로, 문자열·보이는 범위·
/// 일치 위치는 문서 전체 기준으로 답하고, 다른 쪽의 일치는 그 쪽으로 넘겨서 보여준다.
/// 선택을 옮겨도 포커스는 찾기 바에 남겨 계속 입력하고 Enter로 이동할 수 있게 한다.
final class PagedFindClient: NSObject, NSTextFinderClient {
    private weak var reader: ReaderViewController?

    init(reader: ReaderViewController) {
        self.reader = reader
    }

    var string: String { reader?.findableString ?? "" }

    var isSelectable: Bool { true }
    // 바꾸기는 문서 소유 Undo와 페이지 재조판을 거쳐야 하므로 찾기만 제공한다.
    var isEditable: Bool { false }
    var allowsMultipleSelection: Bool { false }

    var firstSelectedRange: NSRange {
        reader?.selectedTextRange ?? NSRange(location: 0, length: 0)
    }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: firstSelectedRange)] }
        set {
            guard let range = newValue.first?.rangeValue else { return }
            reader?.selectFindRange(range)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        reader?.revealFindRange(range)
        reader?.noteFindMatch(range)
    }

    var visibleCharacterRanges: [NSValue] {
        guard let reader = reader else { return [] }
        return [NSValue(range: reader.visibleCharacterRange)]
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        guard let reader = reader, let (view, range) = reader.findContentView(at: index) else {
            outRange.pointee = NSRange(location: 0, length: (reader?.findableString as NSString?)?.length ?? 0)
            return reader?.view ?? NSView()
        }
        outRange.pointee = range
        return view
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        reader?.findRects(for: range).map { NSValue(rect: $0) }
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        // 찾기 표시(노란 상자) 안에 글자를 그린다.
        reader?.drawFindCharacters(in: range)
    }
}
