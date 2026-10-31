import AppKit

/// A persistent TextKit layout network with a valid prefix of page boundaries.
/// All calls, including edits to storage, belong to the main thread. The caller schedules
/// idle batches; no timers or views are owned here.
final class IncrementalPaginator {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    private let pageSize: NSSize

    /// Containers outlive cached boundaries so an edit never detaches a live text view.
    private(set) var containers: [NSTextContainer] = []
    private(set) var ranges: [NSRange] = []
    private(set) var isComplete = false
    /// A nonempty range that TextKit cannot place must not create endless blank pages.
    private(set) var isBlocked = false
    private(set) var computedPageCount = 0
    private var pendingInvalidationStart: Int?

    init(storage: NSTextStorage, pageSize: NSSize) {
        self.storage = storage
        self.pageSize = NSSize(width: max(1, pageSize.width), height: max(1, pageSize.height))
        layoutManager = ProofreadingLayoutManager()
        layoutManager.backgroundLayoutEnabled = false
        storage.addLayoutManager(layoutManager)
    }

    /// Called from storage's editing notification. Do not ask TextKit to lay out here:
    /// its own invalidation transaction has not necessarily finished yet.
    func invalidate(editedRange: NSRange) {
        let location = min(max(0, editedRange.location), storage.length)
        let paragraphStart = (storage.string as NSString)
            .paragraphRange(for: NSRange(location: location, length: 0)).location
        let affected = ranges.firstIndex { NSMaxRange($0) >= paragraphStart } ?? ranges.count
        let firstInvalid = max(0, affected - 1)
        let start = firstInvalid < ranges.count ? ranges[firstInvalid].location : (ranges.last.map(NSMaxRange) ?? 0)
        if firstInvalid < ranges.count { ranges.removeSubrange(firstInvalid...) }
        pendingInvalidationStart = min(pendingInvalidationStart ?? start, start)
        isComplete = false
        isBlocked = false
    }

    func ensurePage(_ index: Int) {
        guard index >= 0 else { return }
        while !isComplete && !isBlocked && ranges.count <= index { advance(maxPages: 1) }
    }

    func ensureCharacter(_ offset: Int) {
        let target = min(max(0, offset), storage.length)
        while !isComplete && !isBlocked && (ranges.isEmpty || NSMaxRange(ranges.last!) <= target) {
            advance(maxPages: 1)
        }
    }

    /// An upper bound on page work per turn, rather than a delayed full-document pass.
    func advance(maxPages: Int = 2) {
        guard maxPages > 0 else { return }
        for _ in 0..<maxPages {
            guard !isComplete && !isBlocked else { return }
            layoutNextPage()
        }
    }

    /// Call ensureCharacter first if the offset may be beyond the valid prefix.
    func pageIndex(containing offset: Int) -> Int {
        guard !ranges.isEmpty else { return 0 }
        let target = min(max(0, offset), storage.length)
        return ranges.firstIndex { target < NSMaxRange($0) } ?? (ranges.count - 1)
    }

    private func layoutNextPage() {
        if let start = pendingInvalidationStart {
            // Storage delegates run inside an edit transaction. Invalidate TextKit's
            // suffix only now, before asking for layout; cached prefix pages survive.
            let clamped = min(start, storage.length)
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: clamped, length: storage.length - clamped), actualCharacterRange: nil)
            pendingInvalidationStart = nil
        }
        let index = ranges.count
        let container: NSTextContainer
        if index < containers.count {
            container = containers[index]
        } else {
            container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
        }
        // TextKit places a paragraph's final fitting line differently when its
        // container is the last available one. A spare container keeps page
        // boundaries stable as more pages are requested (including line spacing).
        if containers.count <= index + 1 {
            let lookahead = NSTextContainer(size: pageSize)
            lookahead.lineFragmentPadding = 0
            layoutManager.addTextContainer(lookahead)
            containers.append(lookahead)
        }
        // It may already contain speculative layout from before the lookahead
        // existed. Clear that container's cache, not the preceding page's cache.
        layoutManager.textContainerChangedGeometry(container)
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(for: container)
        let range = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        computedPageCount += 1
        if range.length == 0 && range.location < storage.length {
            isBlocked = true
            return
        }
        ranges.append(range)

        // A final newline may need an extra empty page for its insertion point.
        // It is still a real page even though its character range has zero length.
        if storage.length == 0 {
            isComplete = true
        } else if NSMaxRange(range) >= storage.length {
            let needsInsertionLine = endsInLineBreak
            let insertionContainer = layoutManager.extraLineFragmentTextContainer
            let insertionPage = containers.firstIndex { $0 === insertionContainer }
            isComplete = !needsInsertionLine || insertionPage.map { $0 <= index } == true
        }
    }

    private var endsInLineBreak: Bool {
        guard storage.length > 0 else { return false }
        let last = (storage.string as NSString).character(at: storage.length - 1)
        return last == 10 || last == 13 || last == 0x2028 || last == 0x2029
    }
}
