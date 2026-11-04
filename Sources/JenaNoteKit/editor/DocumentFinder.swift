import AppKit

/// 헤더 검색창이 찾는 화면 — 페이지 조판, 연속 편집기, 원문 보기.
protocol DocumentFindTarget: AnyObject {
    var findableString: String { get }
    var findStartLocation: Int { get }
    func showFindMatches(_ matches: [NSRange], current: NSRange?)
    func revealFindMatch(_ range: NSRange)
    func selectFindMatch(_ range: NSRange)
    /// 일치를 글자만 바꾼다. 서식은 바뀌는 글자의 첫 글자를 따르고, 전체가 실행 취소 한 번이다.
    func replaceFindMatches(_ ranges: [NSRange], with text: String)
}

/// 문서 내 찾기 (ADR-0007). macOS 찾기 바는 바깥에서 검색어를 넣을 수 없어서 헤더 검색창이
/// 직접 찾고 강조한다. 강조는 임시 속성이라 문서 내용·저장·실행 취소와 무관하다.
final class DocumentFinder {
    static let matchColor = NSColor.findHighlightColor.withAlphaComponent(0.35)
    static let currentMatchColor = NSColor.findHighlightColor

    private(set) var query = ""
    private(set) var matches: [NSRange] = []
    private(set) var current: NSRange?
    /// 검색을 시작한 자리. 글자를 더 쳐도 이 자리부터 다시 찾아야 현재 일치가 튀지 않는다.
    private var anchor = 0
    private var target: DocumentFindTarget?
    /// 바꾸는 도중의 본문 변경 알림은 무시한다. 끝난 뒤 한 번만 다시 찾는다.
    private var isReplacing = false
    var onChange: ((_ current: Int?, _ total: Int) -> Void)?

    static func ranges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var result: [NSRange] = [], start = 0
        while start < ns.length {
            let found = ns.range(of: query, options: .caseInsensitive,
                                 range: NSRange(location: start, length: ns.length - start))
            guard found.location != NSNotFound else { break }
            result.append(found)
            start = NSMaxRange(found)
        }
        return result
    }

    func search(_ newQuery: String) {
        guard newQuery != query else { return }
        if query.isEmpty { anchor = target?.findStartLocation ?? 0 }
        query = newQuery
        matches = Self.ranges(of: query, in: target?.findableString ?? "")
        current = matches.first { $0.location >= anchor } ?? matches.first
        present(reveal: true)
    }

    func move(forward: Bool) {
        guard !query.isEmpty else { return }
        let reference = current ?? NSRange(location: target?.findStartLocation ?? 0, length: 0)
        matches = Self.ranges(of: query, in: target?.findableString ?? "")
        current = forward
            ? matches.first { $0.location >= NSMaxRange(reference) } ?? matches.first
            : matches.last { NSMaxRange($0) <= reference.location } ?? matches.last
        present(reveal: true)
    }

    /// 본문이 바뀌면 일치 위치도 바뀐다. 읽던 자리를 옮기지 않고 강조만 맞춘다.
    func refresh() {
        guard !query.isEmpty, !isReplacing else { return }
        let location = current?.location ?? anchor
        matches = Self.ranges(of: query, in: target?.findableString ?? "")
        current = matches.first { $0.location >= location } ?? matches.first
        present(reveal: false)
    }

    /// 현재 일치만 바꾸고 그 뒤의 일치로 넘어간다. 바꾼 글자에 검색어가 들어 있어도 다시 잡지 않는다.
    func replaceCurrent(with text: String) {
        guard !query.isEmpty else { return }
        matches = Self.ranges(of: query, in: target?.findableString ?? "")
        guard let range = current, matches.contains(range) else { refresh(); return }
        replace([range], with: text)
        let next = range.location + text.utf16.count
        current = matches.first { $0.location >= next } ?? matches.first
        present(reveal: true)
    }

    /// 문서의 일치를 모두 바꾸고 바꾼 개수를 돌려준다.
    @discardableResult
    func replaceAll(with text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let all = Self.ranges(of: query, in: target?.findableString ?? "")
        guard !all.isEmpty else { return 0 }
        replace(all, with: text)
        current = matches.first
        present(reveal: false)
        return all.count
    }

    private func replace(_ ranges: [NSRange], with text: String) {
        isReplacing = true
        target?.replaceFindMatches(ranges, with: text)
        isReplacing = false
        matches = Self.ranges(of: query, in: target?.findableString ?? "")
    }

    /// 보기 방식이 바뀌면 찾는 화면도 바뀐다. 이전 화면의 강조는 지우고 검색어는 이어간다.
    func retarget(_ newTarget: DocumentFindTarget) {
        guard newTarget !== target else { return }
        target?.showFindMatches([], current: nil)
        target = newTarget
        refresh()
    }

    /// 찾는 동안에는 선택하지 않는다 — 비활성 선택의 회색이 현재 일치의 강조를 덮는다.
    /// 끝낼 때 현재 일치를 선택해 바로 고칠 수 있게 한다.
    func finish() {
        if let current { target?.selectFindMatch(current) }
        clear()
    }

    func clear() {
        query = ""
        matches = []
        current = nil
        present(reveal: false)
    }

    private func present(reveal: Bool) {
        target?.showFindMatches(matches, current: current)
        if reveal, let current { target?.revealFindMatch(current) }
        onChange?(current.flatMap { matches.firstIndex(of: $0) }, matches.count)
    }
}

/// 연속 편집기와 원문 보기는 텍스트 뷰 하나가 문서 전체를 쥐고 있다.
final class TextViewFindTarget: DocumentFindTarget {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
    }

    var findableString: String { textView?.string ?? "" }
    var findStartLocation: Int { textView?.selectedRange().location ?? 0 }

    func showFindMatches(_ matches: [NSRange], current: NSRange?) {
        guard let layout = textView?.layoutManager else { return }
        layout.drawFindHighlights(matches, current: current, length: findableString.utf16.count)
    }

    func revealFindMatch(_ range: NSRange) {
        textView?.scrollRangeToVisible(range)
    }

    func selectFindMatch(_ range: NSRange) {
        textView?.setSelectedRange(range)
    }

    func replaceFindMatches(_ ranges: [NSRange], with text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        if textView.hasMarkedText() { textView.unmarkText() }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                                        replacementStrings: ranges.map { _ in text }) else { return }
        storage.beginEditing()
        for range in ranges.reversed() { storage.replaceCharacters(in: range, with: text) }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(L10n.tr("find.replace"))
        textView.breakUndoCoalescing()
    }
}

extension NSLayoutManager {
    func drawFindHighlights(_ matches: [NSRange], current: NSRange?, length: Int) {
        let full = NSRange(location: 0, length: length)
        removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for range in matches where NSMaxRange(range) <= length {
            addTemporaryAttribute(.backgroundColor, value: DocumentFinder.matchColor, forCharacterRange: range)
        }
        if let current, NSMaxRange(current) <= length {
            addTemporaryAttribute(.backgroundColor, value: DocumentFinder.currentMatchColor, forCharacterRange: current)
            // 현재 일치의 바탕은 밝은 노랑이라 어두운 화면의 흰 글자가 보이지 않는다.
            addTemporaryAttribute(.foregroundColor, value: NSColor.black, forCharacterRange: current)
        }
    }
}
