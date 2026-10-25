import AppKit

/// A read-only view of the current document's save representation, including unsaved edits.
final class MarkdownSourceViewController: NSViewController {
    let textView = NSTextView()
    private weak var sourceDocument: MarkdownDocument?
    private var refreshWork: DispatchWorkItem?

    override func loadView() {
        let description = NSTextField(wrappingLabelWithString: L10n.tr("source.description"))
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        let copy = NSButton(title: L10n.tr("source.copyAll"), target: self, action: #selector(copyAll))
        let header = NSStackView(views: [description, copy])
        header.orientation = .horizontal
        header.spacing = 12
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(L10n.tr("source.title"))
        scroll.documentView = textView
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.alignment = .leading
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        view = stack
    }

    deinit { refreshWork?.cancel() }

    func show(document: MarkdownDocument) {
        _ = view
        sourceDocument = document
        refresh()
    }

    func suspend() { refreshWork?.cancel() }

    func setDocument(_ document: MarkdownDocument?) {
        sourceDocument = document
        refreshWork?.cancel()
        textView.string = ""
        if isViewLoaded, view.window != nil { refresh() }
    }

    func scheduleRefresh() {
        guard isViewLoaded, view.window?.isVisible == true else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func refresh() {
        refreshWork?.cancel()
        guard let document = sourceDocument else {
            textView.string = ""
            return
        }
        do {
            let source = String(decoding: try document.data(ofType: document.fileType ?? "net.daringfireball.markdown"), as: UTF8.self)
            guard source != textView.string else { return }
            let selection = textView.selectedRange()
            let origin = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
            textView.string = source
            let start = min(selection.location, source.utf16.count)
            textView.setSelectedRange(NSRange(location: start, length: min(selection.length, source.utf16.count - start)))
            textView.enclosingScrollView?.contentView.scroll(to: origin)
        } catch {
            textView.string = error.localizedDescription
        }
    }

    @objc private func copyAll() {
        refresh()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

}
