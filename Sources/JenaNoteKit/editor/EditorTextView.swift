import AppKit

class EditorTextView: NSTextView {

    // MARK: - Setup

    override func awakeFromNib() {
        super.awakeFromNib()
        configure()
    }

    func configure() {
        isRichText = true
        isEditable = true
        isSelectable = true
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isContinuousSpellCheckingEnabled = true

        textContainerInset = NSSize(width: 60, height: 40)
        typingAttributes = defaultTypingAttributes()
    }

    // MARK: - Default Typing Attributes

    func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: MemoFont.body,
            .foregroundColor: NSColor.labelColor,
            .mdBlockType: "body",
            .paragraphStyle: FormatCommands.bodyParagraphStyle()
        ]
    }

    // MARK: - Paste: 서식 없이 붙여넣기 지원

    /// Cmd+Shift+V: 서식 없이 붙여넣기
    override func pasteAsPlainText(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        insertText(str, replacementRange: selectedRange())
    }

    // MARK: - Return Key: 목록에서 Enter 시 새 항목 추가

    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage else {
            super.insertNewline(sender)
            return
        }

        let loc = selectedRange().location
        guard loc > 0 else {
            super.insertNewline(sender)
            return
        }

        let blockType = storage.attribute(.mdBlockType, at: max(0, loc - 1), effectiveRange: nil) as? String ?? "body"

        if blockType == "ul" || blockType == "ol" {
            // 현재 줄이 비어있으면 목록 해제
            let paraRange = (storage.string as NSString).paragraphRange(for: NSRange(location: loc, length: 0))
            let paraText = (storage.string as NSString).substring(with: paraRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if paraText.isEmpty || paraText == "•" || paraText == "•\t" {
                // 빈 목록 항목 → 목록 해제하고 일반 줄바꿈
                if blockType == "ul" {
                    FormatCommands.toggleUnorderedList(self)
                } else {
                    FormatCommands.toggleOrderedList(self)
                }
                return
            }

            // 새 목록 항목 삽입
            super.insertNewline(sender)
            let newLoc = selectedRange().location
            let prefix: NSAttributedString
            if blockType == "ul" {
                prefix = NSAttributedString(string: "•\t", attributes: [
                    .font: MemoFont.body,
                    .foregroundColor: NSColor.labelColor,
                    .mdBlockType: "ul",
                    .paragraphStyle: FormatCommands.listParagraphStyle()
                ])
            } else {
                let idx = (storage.attribute(.mdListIndex, at: max(0, loc - 1), effectiveRange: nil) as? Int ?? 1) + 1
                prefix = NSAttributedString(string: "\(idx).\t", attributes: [
                    .font: MemoFont.body,
                    .foregroundColor: NSColor.labelColor,
                    .mdBlockType: "ol",
                    .mdListIndex: idx,
                    .paragraphStyle: FormatCommands.listParagraphStyle()
                ])
            }
            shouldChangeText(in: NSRange(location: newLoc, length: 0), replacementString: nil)
            storage.insert(prefix, at: newLoc)
            setSelectedRange(NSRange(location: newLoc + prefix.length, length: 0))
            didChangeText()
            return
        }

        super.insertNewline(sender)

        // 일반 줄바꿈 후 typing attributes 리셋 (heading → body 전환)
        typingAttributes = defaultTypingAttributes()
    }
}
