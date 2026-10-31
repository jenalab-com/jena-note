import AppKit

/// A document-scoped comparison sheet. No edit happens before explicit acceptance.
final class AIProofreadingController {
    let snapshot: AIEditSnapshot
    let alert = NSAlert()
    let originalView = NSTextView()
    let suggestionView = NSTextView()
    let status = NSTextField(wrappingLabelWithString: L10n.tr("proof.checking"))
    private let spinner = NSProgressIndicator()
    private let dictionaryTerms: () throws -> [String]
    private let service: AISelectionProofreader
    private let apply: (String) throws -> Void
    private let onClose: () -> Void
    private var cancelRequest: (() -> Void)?
    private var dictionaryObserver: NSObjectProtocol?
    private var rawSuggestion: String?
    private(set) var suggestion: String?
    private(set) var isActive = false

    init(snapshot: AIEditSnapshot, service: AISelectionProofreader = AISelectionProofreader(),
         dictionaryTerms: @escaping () throws -> [String] = { try PersonalDictionaryStore.shared.terms(for: nil) },
         apply: @escaping (String) throws -> Void, onClose: @escaping () -> Void) {
        self.snapshot = snapshot
        self.dictionaryTerms = dictionaryTerms
        self.service = service
        self.apply = apply
        self.onClose = onClose
        alert.messageText = L10n.tr("proof.title")
        alert.informativeText = L10n.tr("proof.hint")
        alert.addButton(withTitle: L10n.tr("proof.apply"))
        alert.addButton(withTitle: L10n.tr("confirm.cancel"))
        alert.buttons[0].isEnabled = false
        originalView.string = snapshot.content.attributedSubstring(from: snapshot.range).string
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (title, textView) in [(L10n.tr("proof.original"), originalView), (L10n.tr("proof.suggestion"), suggestionView)] {
            stack.addArrangedSubview(NSTextField(labelWithString: title))
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            textView.isEditable = false
            textView.isRichText = false
            textView.font = .systemFont(ofSize: 13)
            textView.frame = NSRect(x: 0, y: 0, width: 480, height: 110)
            textView.minSize = NSSize(width: 0, height: 110)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.setAccessibilityLabel(title)
            scroll.documentView = textView
            stack.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        let progress = NSStackView(views: [spinner, status])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.spacing = 8
        stack.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: 310)
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(NSSize(width: 480, height: stack.fittingSize.height))
        alert.accessoryView = stack
    }

    deinit { if let dictionaryObserver { NotificationCenter.default.removeObserver(dictionaryObserver) } }

    func show(in window: NSWindow) {
        isActive = true
        dictionaryObserver = NotificationCenter.default.addObserver(forName: PersonalDictionaryStore.changed, object: nil, queue: .main) { [weak self] _ in self?.refreshSuggestion() }
        spinner.startAnimation(nil)
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self else { return }
            self.isActive = false
            self.cancelRequest?()
            self.cancelRequest = nil
            if response == .alertFirstButtonReturn, let suggestion = self.suggestion {
                do { try self.apply(suggestion) }
                catch {
                    let failure = NSAlert(error: error)
                    if let window { failure.beginSheetModal(for: window) }
                }
            }
            self.onClose()
        }
        cancelRequest = service.check(originalView.string) { [weak self] result in
            guard let self, self.isActive else { return }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            switch result {
            case .success(let raw):
                self.rawSuggestion = raw
                self.refreshSuggestion()
            case .failure(let error):
                self.status.stringValue = error.localizedDescription
                self.alert.buttons[0].isEnabled = false
            }
        }
    }

    private func refreshSuggestion() {
        guard isActive, let rawSuggestion else { return }
        do {
            let text = ProofreadingSuggestion.filteredText(source: originalView.string, corrected: rawSuggestion, terms: try dictionaryTerms())
            suggestion = text
            suggestionView.string = text
            let changed = text != originalView.string
            status.stringValue = L10n.tr(changed ? "proof.review" : "proof.unchanged")
            alert.buttons[0].isEnabled = changed
        } catch { status.stringValue = error.localizedDescription; alert.buttons[0].isEnabled = false }
    }

    func cancel() {
        isActive = false
        cancelRequest?()
        cancelRequest = nil
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
    }
}
