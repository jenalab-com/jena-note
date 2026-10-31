import AppKit

extension EditorWindowController {
    var canProofreadSelection: Bool {
        guard !isShowingSource, proofreadingController == nil, let doc = document as? MarkdownDocument else { return false }
        let range = documentSelection
        return range.location != NSNotFound && range.length > 0 && NSMaxRange(range) <= doc.content.length
    }

    private var isComposingProofreadingText: Bool {
        editorVC.textView.hasMarkedText() || (readerVC?.visiblePageTextViews.contains { $0.hasMarkedText() } ?? false)
    }

    @objc func proofreadSelection(_ sender: Any?) {
        guard let doc = document as? MarkdownDocument, let window, canProofreadSelection else { return }
        do {
            guard !isComposingProofreadingText else { throw AIError(message: L10n.tr("ai.editConflict")) }
            let snapshot = AIEditSnapshot(document: doc, selection: documentSelection)
            try AISelectionProofreader.validate(snapshot.content.attributedSubstring(from: snapshot.range).string)
            let controller = AIProofreadingController(snapshot: snapshot, service: proofreadingService,
                dictionaryTerms: { [weak doc] in try PersonalDictionaryStore.shared.terms(for: DictionaryWorkContext.locate(documentURL: doc?.fileURL)) },
                apply: { [weak self, weak doc] text in
                    guard let self, let doc, self.document === doc else {
                        throw AIError(message: L10n.tr("ai.editConflict"))
                    }
                    try self.applyProofreading(text, snapshot: snapshot)
                }, onClose: { [weak self] in self?.proofreadingController = nil })
            proofreadingController = controller
            controller.show(in: window)
        } catch { doc.presentError(error) }
    }

    func applyProofreading(_ text: String, snapshot: AIEditSnapshot) throws {
        guard !isShowingSource, let doc = document as? MarkdownDocument,
              snapshot.canApply(to: doc), !isComposingProofreadingText else {
            throw AIError(message: L10n.tr("ai.editConflict"))
        }
        let (range, replacement) = try snapshot.replacement(text)
        guard range.length > 0 || replacement.length > 0 else { return }
        editorVC.textView.breakUndoCoalescing()
        doc.undoManager?.beginUndoGrouping()
        doc.replaceReaderContent(in: range, with: replacement)
        doc.undoManager?.setActionName(L10n.tr("proof.title"))
        doc.undoManager?.endUndoGrouping()
        selectDocumentRange(NSRange(location: range.location, length: replacement.length))
    }
}
