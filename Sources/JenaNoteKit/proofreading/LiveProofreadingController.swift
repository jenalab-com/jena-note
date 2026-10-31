import AppKit
import os

/// View-only annotations: never writes to NSTextStorage or the document's undo history.
final class LiveProofreadingController {
    typealias Check = (String) async throws -> String
    private weak var textView: NSTextView?
    private let check: Check
    private let delay: TimeInterval
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var stopped = false
    private var cache: [String: String] = [:]
    private let dictionary: PersonalDictionaryStore
    private(set) var candidates: [ProofreadingSuggestion] = []
    private(set) var popover: NSPopover?
    private var shownCandidate: ProofreadingSuggestion?
    private var hoverWork: DispatchWorkItem?
    private var checkedSource = ""
    private weak var observedDocument: MarkdownDocument?
    private var documentURLObservation: NSKeyValueObservation?

    private(set) var markedRanges: [NSRange] = []
    private static let logger = Logger(subsystem: "com.jenalab.jenanote", category: "proofreading")

    init(textView: NSTextView, delay: TimeInterval = 0.5, dictionary: PersonalDictionaryStore = .shared,
         check: @escaping Check = { try await KiwiProofreadingEngine.shared.check($0) }) {
        self.textView = textView
        self.dictionary = dictionary
        self.delay = delay
        self.check = check
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                            object: textView.textStorage, queue: .main) { [weak self] _ in
            self?.schedule()
            // TextKit has not consumed edited ranges inside didProcessEditing yet.
            DispatchQueue.main.async { [weak self] in self?.clear(all: true) }
        })
        observers.append(center.addObserver(forName: NSTextView.didChangeSelectionNotification,
                                            object: textView, queue: .main) { [weak self] _ in self?.selectionChanged() })
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let self, let clip = note.object as? NSClipView,
                  clip === self.textView?.enclosingScrollView?.contentView else { return }
            self.schedule()
        })
        observers.append(center.addObserver(forName: PersonalDictionaryStore.changed, object: dictionary, queue: .main) { [weak self] _ in
            self?.clear(); self?.schedule()
        })
        schedule()
    }

    deinit { stop() }

    func stop() {
        stopped = true; revision += 1
        documentURLObservation?.invalidate(); documentURLObservation = nil
        pending?.cancel(); task?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        clear()
    }

    func schedule() {
        guard !stopped else { return }
        revision += 1
        pending?.cancel(); task?.cancel()
        if textView?.hasMarkedText() == true {
            DispatchQueue.main.async { [weak self] in self?.clear() }
        }
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func refresh() {
        guard !stopped, let view = textView, view.window != nil, view.isEditable,
              !view.isHiddenOrHasHiddenAncestor, !view.hasMarkedText(),
              let layout = view.layoutManager, let container = view.textContainer else { return }
        let document = view.window?.windowController?.document as? MarkdownDocument
        if observedDocument !== document {
            observedDocument = document
            documentURLObservation = document?.observe(\.fileURL, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.clear(); self?.schedule() }
            }
        }
        let source = view.string
        guard !source.isEmpty else { clear(); return }
        var rect = view.visibleRect
        rect.origin.x -= view.textContainerOrigin.x
        rect.origin.y -= view.textContainerOrigin.y
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let visible = NSIntersectionRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil),
                                          NSRange(location: 0, length: source.utf16.count))
        guard visible.length > 0 else { clear(); return }
        let ns = source as NSString
        // Bound context even when an entire novel is stored as one paragraph.
        let paragraph = ns.paragraphRange(for: visible)
        let start = max(paragraph.location, visible.location - 500)
        let end = min(NSMaxRange(paragraph), NSMaxRange(visible) + 500, start + 6000)
        let context = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: max(0, end - start)))
        let pieces = ProofreadingAnnotations.chunks(source, in: context)
        let current = revision
        clear()
        checkedSource = source
        task = Task { @MainActor [weak self, weak view] in
            guard let self else { return }
            for (range, input) in pieces {
                do {
                    try Task.checkCancellation()
                    let corrected: String
                    if let cached = self.cache[input] { corrected = cached }
                    else {
                        corrected = try await self.check(input)
                        try Task.checkCancellation()
                        if self.cache.count >= 64 { self.cache.removeAll(keepingCapacity: true) }
                        self.cache[input] = corrected
                    }
                    let context = DictionaryWorkContext.locate(documentURL: (view?.window?.windowController?.document as? MarkdownDocument)?.fileURL)
                    let terms = try self.dictionary.terms(for: context)
                    let suggestions = ProofreadingSuggestion.suggestions(source: input, corrected: corrected, terms: terms)
                    guard !self.stopped, self.revision == current, let view,
                          !view.hasMarkedText(), view.string == source else { return }
                    for suggestion in suggestions {
                        let marks = suggestion.marks.map { mark in
                            NSIntersectionRange(NSRange(location: range.location + mark.location, length: mark.length), visible)
                        }.filter { $0.length > 0 }
                        guard !marks.isEmpty else { continue }
                        let item = ProofreadingSuggestion(range: NSRange(location: range.location + suggestion.range.location, length: suggestion.range.length), original: suggestion.original, replacement: suggestion.replacement, marks: marks)
                        self.candidates.append(item)
                        for mark in marks { self.mark(mark) }
                    }
                    self.selectionChanged()
                } catch is CancellationError { return }
                catch {
                    Self.logger.error("Local proofreading failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
        }
    }

    func selectionChanged() {
        guard let view = textView, view.window?.firstResponder === view else { return }
        if view.hasMarkedText() { dismissPopover(); schedule(); return }
        let selection = view.selectedRange()
        if let item = candidates.first(where: { item in
            selection.length == 0
                ? selection.location >= item.range.location && selection.location <= NSMaxRange(item.range)
                : item.marks.contains { NSIntersectionRange($0, selection).length > 0 }
        }) { schedulePresentation(item) }
        else { dismissPopover() }
    }

    func hover(at point: NSPoint) {
        guard let view = textView, !view.hasMarkedText() else { return }
        for item in candidates {
            if rectangles(for: item).contains(where: { $0.insetBy(dx: -2, dy: -6).contains(point) }) {
                schedulePresentation(item); return
            }
        }
        hoverEnded()
    }

    func hoverEnded() {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let window = self.popover?.contentViewController?.view.window,
               window.frame.contains(NSEvent.mouseLocation) { return }
            self.dismissPopover()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func schedulePresentation(_ item: ProofreadingSuggestion) {
        if shownCandidate == item, popover?.isShown == true { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showCandidate(item) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rectangles(for item: ProofreadingSuggestion) -> [NSRect] {
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return [] }
        var rectangles: [NSRect] = []
        for range in item.marks where NSMaxRange(range) <= (layout.textStorage?.length ?? 0) {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                rectangles.append(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y))
            }
        }
        return rectangles
    }

    func showCandidate(_ item: ProofreadingSuggestion) {
        guard !stopped, candidates.contains(item), let view = textView, !view.hasMarkedText(),
              view.string == checkedSource,
              let host = view.window?.windowController as? EditorWindowController,
              let doc = host.document as? MarkdownDocument,
              doc.content.string == checkedSource, let anchor = rectangles(for: item).first else { return }
        dismissPopover()
        let snapshot = AIEditSnapshot(document: doc, selection: item.range)
        let content = ProofreadingPopoverController(item: item, apply: { [weak self, weak host, weak doc] in
            guard let self, let host, let doc, host.document === doc else { return }
            self.dismissPopover()
            do { try host.applyProofreading(item.replacement, snapshot: snapshot) }
            catch { doc.presentError(error) }
        }, add: { [weak self, weak doc] in
            guard let self, let doc, snapshot.canApply(to: doc) else { return }
            self.dismissPopover()
            PersonalDictionaryWindowController.present(context: DictionaryWorkContext.locate(documentURL: doc.fileURL), term: item.original.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
        })
        let popup = NSPopover(); popup.behavior = .semitransient; popup.animates = false
        popup.contentViewController = content
        self.popover = popup; shownCandidate = item
        popup.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        // A focus-triggered suggestion must never interrupt typing or consume Return.
        view.window?.makeKey(); view.window?.makeFirstResponder(view)
    }

    func dismissPopover() {
        hoverWork?.cancel(); hoverWork = nil
        popover?.close(); popover = nil; shownCandidate = nil
    }

    private func mark(_ range: NSRange) {
        textView?.layoutManager?.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: NSColor.systemOrange,
            .proofreadingUnderline: true
        ], forCharacterRange: range)
        markedRanges.append(range)
        textView?.needsDisplay = true
    }

    private func clear(all: Bool = false) {
        dismissPopover()
        candidates.removeAll()
        guard let view = textView, let layout = view.layoutManager else { markedRanges.removeAll(); return }
        let full = NSRange(location: 0, length: layout.textStorage?.length ?? 0)
        for range in all ? [full] : markedRanges {
            let valid = NSIntersectionRange(range, full)
            guard valid.length > 0 else { continue }
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: valid)
            layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: valid)
            layout.removeTemporaryAttribute(.proofreadingUnderline, forCharacterRange: valid)
        }
        markedRanges.removeAll()
        view.needsDisplay = true
    }
}
