import AppKit

extension EditorWindowController {
    @objc func manageEndnotes(_ sender: Any?) {
        guard let doc = document as? MarkdownDocument, let window, !isShowingSource else { return }
        guard doc.fileURL?.pathExtension.lowercased() != "txt", doc.fileType != "public.plain-text" else {
            doc.presentError(AIError(message: L10n.tr("note.markdownOnly"))); return
        }
        readerVC?.finishComposition()
        let original = NSAttributedString(attributedString: doc.content)
        let selected = documentSelection
        let position = min(NSMaxRange(selected), original.length)
        if original.length > 0, original.attribute(.mdBlockType, at: min(position, original.length - 1), effectiveRange: nil) as? String == "codeblock" {
            doc.presentError(AIError(message: L10n.tr("note.outsideCode"))); return
        }
        let notes = DocumentEndnotes.notes(in: original)
        let alert = NSAlert()
        alert.messageText = L10n.tr("note.title")
        alert.informativeText = L10n.tr("note.hint")
        alert.addButton(withTitle: L10n.tr("note.save"))
        alert.addButton(withTitle: L10n.tr("note.delete"))
        alert.addButton(withTitle: L10n.tr("note.jump"))
        alert.addButton(withTitle: L10n.tr("confirm.cancel"))
        let editor = EndnoteEditorView(notes: notes)
        alert.accessoryView = editor
        editor.onChange = { [weak alert, weak editor] in
            guard let alert, let editor else { return }
            alert.buttons[0].isEnabled = !DocumentEndnotes.normalized(editor.field.stringValue).isEmpty
            alert.buttons[1].isEnabled = editor.picker.indexOfSelectedItem > 0
            alert.buttons[2].isEnabled = editor.picker.indexOfSelectedItem > 0
        }
        editor.onChange?()
        alert.beginSheetModal(for: window) { [weak self, weak doc] response in
            guard let self, let doc, self.document === doc else { return }
            guard doc.content.isEqual(to: original) else { doc.presentError(AIError(message: L10n.tr("ai.editConflict"))); return }
            let index = editor.picker.indexOfSelectedItem - 1
            let note = notes.indices.contains(index) ? notes[index] : nil
            if response == .alertThirdButtonReturn {
                if let note { self.selectDocumentRange(note.range) }
                return
            }
            let updated: NSAttributedString
            if response == .alertSecondButtonReturn {
                guard let note else { return }
                updated = DocumentEndnotes.update(note.id, text: nil, in: original)
            } else if response == .alertFirstButtonReturn {
                let text = DocumentEndnotes.normalized(editor.field.stringValue)
                guard !text.isEmpty else { return }
                if let note { updated = DocumentEndnotes.update(note.id, text: text, in: original) }
                else { updated = DocumentEndnotes.insert(into: original, at: position, text: text).content }
            } else { return }
            doc.undoManager?.beginUndoGrouping()
            doc.replaceReaderContent(in: NSRange(location: 0, length: doc.content.length), with: updated)
            doc.undoManager?.endUndoGrouping()
            doc.undoManager?.setActionName(L10n.tr("note.title"))
            self.selectDocumentRange(NSRange(location: min(position, doc.content.length), length: 0))
        }
        window.makeFirstResponder(editor.field)
    }

    var documentSelection: NSRange {
        readerVC?.selectedTextRange ?? editorVC.textView.selectedRange()
    }

    func selectDocumentRange(_ range: NSRange) {
        if isShowingSource { showMarkdownSource(nil) }
        if let reader = readerVC { reader.selectTextRange(range) }
        else {
            editorVC.textView.setSelectedRange(range)
            editorVC.textView.scrollRangeToVisible(range)
            window?.makeFirstResponder(editorVC.textView)
        }
    }

    /// Apply commands to original paragraph attributes, then send one document-owned undo edit.
    /// Display font/weight/spacing must never be mistaken for the author's formatting.
    func performDocumentFormatting(selection: NSRange? = nil, _ command: (NSTextView) -> Void) {
        guard !isShowingSource, let doc = document as? MarkdownDocument else { return }
        readerVC?.finishComposition()
        let selected = selection ?? documentSelection
        guard selected.location != NSNotFound, NSMaxRange(selected) <= doc.content.length else { return }
        let range = (doc.content.string as NSString).paragraphRange(for: selected)
        let original = doc.content.attributedSubstring(from: range)
        let staging = EditorTextView()
        staging.isRichText = true
        staging.allowsUndo = false
        staging.textStorage?.setAttributedString(original)
        staging.typingAttributes = [.font: MemoFont.body, .foregroundColor: NSColor.labelColor,
                                    .paragraphStyle: FormatCommands.bodyParagraphStyle(), .mdBlockType: "body"]
        staging.setSelectedRange(NSRange(location: selected.location - range.location, length: selected.length))
        if original.length > 0 {
            let index = min(max(0, staging.selectedRange().location - (selected.length == 0 ? 1 : 0)), original.length - 1)
            staging.typingAttributes = original.attributes(at: index, effectiveRange: nil)
        }
        command(staging)
        let updated = staging.attributedString()
        let next = staging.selectedRange()
        if !original.isEqual(to: updated) {
            editorVC.textView.breakUndoCoalescing()
            doc.undoManager?.beginUndoGrouping()
            doc.replaceReaderContent(in: range, with: updated)
            doc.undoManager?.endUndoGrouping()
        }
        let location = min(range.location + next.location, doc.content.length)
        selectDocumentRange(NSRange(location: location, length: min(next.length, doc.content.length - location)))
        if selected.length == 0 {
            let sample = NSAttributedString(string: " ", attributes: staging.typingAttributes)
            let settings = SettingsManager.shared
            let styled = ReaderMetrics.styled(sample, scale: settings.readingFontScale, font: settings.readingFont,
                                               lineHeightMultiple: settings.readingLineSpacing, weight: settings.readingWeight)
            let attributes = styled.attributes(at: 0, effectiveRange: nil)
            if let reader = readerVC { reader.setTypingAttributes(attributes) }
            else { editorVC.textView.typingAttributes = attributes }
        }
        editorVC.updateToolbarState()
    }

    func jumpToMatch(_ jump: SearchJump) {
        guard let doc = document as? MarkdownDocument,
              let range = SearchMatchLocator.range(ofOccurrence: jump.ordinal, query: jump.query, in: doc.content.string)
                ?? SearchMatchLocator.range(ofOccurrence: 0, query: jump.query, in: doc.content.string) else { return }
        selectDocumentRange(range)
    }

    func showPagedFind() {
        guard let doc = document as? MarkdownDocument, let window = window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("toolbar.find")
        alert.addButton(withTitle: L10n.tr("toolbar.find"))
        alert.addButton(withTitle: L10n.tr("confirm.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        let start = NSMaxRange(documentSelection)
        alert.beginSheetModal(for: window) { [weak self, weak doc] result in
            guard let self = self, let doc = doc, self.document === doc,
                  result == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            let text = doc.content.string as NSString
            let offset = min(start, text.length)
            var range = text.range(of: field.stringValue, options: .caseInsensitive,
                                   range: NSRange(location: offset, length: text.length - offset))
            if range.location == NSNotFound { range = text.range(of: field.stringValue, options: .caseInsensitive) }
            if range.location != NSNotFound { self.selectDocumentRange(range) } else { NSSound.beep() }
        }
        window.makeFirstResponder(field)
    }
}
