import AppKit

extension EditorWindowController {
    @objc func toggleDialogueMark(_ sender: Any?) { togglePunctuation(.dialogue, sender: sender) }
    @objc func toggleQuotationMark(_ sender: Any?) { togglePunctuation(.quotation, sender: sender) }
    @objc func toggleThoughtMark(_ sender: Any?) { togglePunctuation(.thought, sender: sender) }

    /// 여러 칸을 켜 둘 수 있는 컨트롤이라, 눌린 칸은 현재 상태와 달라진 칸으로 찾는다.
    @objc func punctuationSegmentChanged(_ sender: NSSegmentedControl) {
        let changed = PunctuationKind.allCases.enumerated().first { index, kind in
            sender.isSelected(forSegment: index) != punctuationController.isActive(kind)
        }
        if let kind = changed?.element { togglePunctuation(kind, sender: sender) }
        updatePunctuationToolbar()
    }

    func updatePunctuationToolbar() {
        (window?.toolbar as? ReaderToolbar)?.updatePunctuation(active: punctuationController.active)
    }

    var canTogglePunctuation: Bool { !isShowingSource && document is MarkdownDocument }

    private func togglePunctuation(_ kind: PunctuationKind, sender: Any?) {
        guard canTogglePunctuation else { return }
        let focused = window?.firstResponder
        let input: NSTextView?
        if focused is EditorTextView || focused is PageTextView {
            input = focused as? NSTextView
        } else if sender is NSMenuItem, focused is NSTextView {
            // 단축키는 지금 글을 쓰는 곳의 것이다. AI 입력창이나 찾기 칸의 입력을 본문으로 빼앗지 않는다.
            return
        } else {
            input = readerVC?.inputTextView ?? editorVC.textView
            if let input { window?.makeFirstResponder(input) }
        }
        if let input { punctuationController.toggle(kind, in: input) }
    }
}
