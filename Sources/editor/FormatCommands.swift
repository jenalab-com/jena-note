import AppKit

/// 서식 적용 액션 모음.
/// 모든 변경은 NSTextView를 통해 이루어지므로 NSUndoManager에 자동 등록됨.
enum FormatCommands {

    // MARK: - Inline Format

    static func toggleBold(_ textView: NSTextView) {
        toggleTrait(.boldFontMask, in: textView)
    }

    static func toggleItalic(_ textView: NSTextView) {
        toggleTrait(.italicFontMask, in: textView)
    }

    static func toggleInlineCode(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }

        let current = storage.attribute(.mdInlineCode, at: range.location, effectiveRange: nil) as? Bool
        let isCode = current == true

        textView.shouldChangeText(in: range, replacementString: nil)
        if isCode {
            storage.removeAttribute(.mdInlineCode, range: range)
            storage.addAttribute(.font, value: MemoFont.body, range: range)
        } else {
            storage.addAttributes([
                .font: MemoFont.code,
                .mdInlineCode: true
            ], range: range)
        }
        textView.didChangeText()
    }

    static func insertHorizontalRule(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let sel = textView.selectedRange()
        let paraRange = (storage.string as NSString).paragraphRange(for: sel)
        let insertPos = paraRange.location + paraRange.length

        let hr = MarkdownSerializer.makeHorizontalRule()
        let bodyPara = NSAttributedString(string: "\n", attributes: [
            .font: MemoFont.body,
            .foregroundColor: NSColor.labelColor,
            .mdBlockType: "body",
            .paragraphStyle: bodyParagraphStyle()
        ])
        let toInsert = NSMutableAttributedString(attributedString: hr)
        toInsert.append(bodyPara)

        let insertRange = NSRange(location: insertPos, length: 0)
        textView.shouldChangeText(in: insertRange, replacementString: nil)
        storage.replaceCharacters(in: insertRange, with: toInsert)
        textView.setSelectedRange(NSRange(location: insertPos + hr.length, length: 0))
        textView.didChangeText()
    }

    static func insertLink(_ textView: NSTextView, url: String) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }

        textView.shouldChangeText(in: range, replacementString: nil)
        storage.addAttributes([
            .link: url,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ], range: range)
        textView.didChangeText()
    }

    // MARK: - Block Format

    static func setHeading(_ level: Int, textView: NSTextView) {
        applyBlockType(textView: textView) { storage, paraRange in
            let font: NSFont
            let blockType: String
            switch level {
            case 1: font = MemoFont.h1; blockType = "h1"
            case 2: font = MemoFont.h2; blockType = "h2"
            case 3: font = MemoFont.h3; blockType = "h3"
            default: font = MemoFont.body; blockType = "body"
            }
            let style = level == 0 ? bodyParagraphStyle() : headingParagraphStyle()
            storage.addAttributes([
                .font: font,
                .mdBlockType: blockType,
                .paragraphStyle: style
            ], range: paraRange)
        }
    }

    static func toggleUnorderedList(_ textView: NSTextView) {
        applyBlockType(textView: textView) { storage, paraRange in
            let current = storage.attribute(.mdBlockType, at: paraRange.location, effectiveRange: nil) as? String
            if current == "ul" {
                // 해제
                storage.addAttributes([
                    .mdBlockType: "body",
                    .font: MemoFont.body,
                    .paragraphStyle: bodyParagraphStyle()
                ], range: paraRange)
                // 앞의 "•\t" 접두사 제거
                removeBulletPrefix(storage: storage, paraRange: paraRange)
            } else {
                storage.addAttributes([
                    .mdBlockType: "ul",
                    .font: MemoFont.body,
                    .paragraphStyle: listParagraphStyle()
                ], range: paraRange)
                addBulletPrefix(storage: storage, paraRange: paraRange, ordered: false, index: 0)
            }
        }
    }

    static func toggleOrderedList(_ textView: NSTextView) {
        applyBlockType(textView: textView) { storage, paraRange in
            let current = storage.attribute(.mdBlockType, at: paraRange.location, effectiveRange: nil) as? String
            if current == "ol" {
                storage.addAttributes([
                    .mdBlockType: "body",
                    .font: MemoFont.body,
                    .paragraphStyle: bodyParagraphStyle()
                ], range: paraRange)
                removeBulletPrefix(storage: storage, paraRange: paraRange)
            } else {
                storage.addAttributes([
                    .mdBlockType: "ol",
                    .mdListIndex: 1,
                    .font: MemoFont.body,
                    .paragraphStyle: listParagraphStyle()
                ], range: paraRange)
                addBulletPrefix(storage: storage, paraRange: paraRange, ordered: true, index: 1)
            }
        }
    }

    static func toggleBlockquote(_ textView: NSTextView) {
        applyBlockType(textView: textView) { storage, paraRange in
            let current = storage.attribute(.mdBlockType, at: paraRange.location, effectiveRange: nil) as? String
            if current == "blockquote" {
                storage.addAttributes([
                    .mdBlockType: "body",
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: bodyParagraphStyle()
                ], range: paraRange)
            } else {
                storage.addAttributes([
                    .mdBlockType: "blockquote",
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: blockquoteParagraphStyle()
                ], range: paraRange)
            }
        }
    }

    // MARK: - Private Helpers

    private static func toggleTrait(_ trait: NSFontTraitMask, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }

        let descriptorTrait: NSFontDescriptor.SymbolicTraits = (trait == .boldFontMask) ? .bold : .italic

        // 범위 전체가 이미 해당 trait을 가지면 해제, 아니면 적용
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { val, _, stop in
            guard let font = val as? NSFont else { allHave = false; stop.pointee = true; return }
            if !font.fontDescriptor.symbolicTraits.contains(descriptorTrait) {
                allHave = false
                stop.pointee = true
            }
        }

        textView.shouldChangeText(in: range, replacementString: nil)
        storage.enumerateAttribute(.font, in: range) { val, subRange, _ in
            let base = (val as? NSFont) ?? MemoFont.body
            var traits = base.fontDescriptor.symbolicTraits
            if allHave {
                traits.remove(descriptorTrait)
            } else {
                traits.insert(descriptorTrait)
            }
            let desc = base.fontDescriptor.withSymbolicTraits(traits)
            let newFont = NSFont(descriptor: desc, size: base.pointSize) ?? base
            storage.addAttribute(.font, value: newFont, range: subRange)
        }
        textView.didChangeText()
    }

    private static func applyBlockType(textView: NSTextView, block: (NSTextStorage, NSRange) -> Void) {
        guard let storage = textView.textStorage else { return }
        let selected = textView.selectedRange()
        let paraRange = (storage.string as NSString).paragraphRange(for: selected)

        textView.shouldChangeText(in: paraRange, replacementString: nil)
        block(storage, paraRange)
        textView.didChangeText()
    }

    private static func addBulletPrefix(storage: NSTextStorage, paraRange: NSRange, ordered: Bool, index: Int) {
        let prefix = ordered ? "\(index).\t" : "•\t"
        let text = (storage.string as NSString).substring(with: paraRange)
        // 이미 접두사가 있으면 추가하지 않음
        if text.hasPrefix("•\t") || (ordered && text.first?.isNumber == true) { return }
        let prefixAttr = NSAttributedString(string: prefix, attributes: [
            .font: MemoFont.body,
            .foregroundColor: NSColor.labelColor,
            .mdBlockType: ordered ? "ol" : "ul",
            .paragraphStyle: listParagraphStyle()
        ])
        storage.insert(prefixAttr, at: paraRange.location)
    }

    private static func removeBulletPrefix(storage: NSTextStorage, paraRange: NSRange) {
        let text = (storage.string as NSString).substring(with: paraRange)
        if text.hasPrefix("•\t") {
            storage.deleteCharacters(in: NSRange(location: paraRange.location, length: 2))
        } else if let tabIdx = text.firstIndex(of: "\t"), text[text.startIndex..<tabIdx].allSatisfy({ $0.isNumber || $0 == "." }) {
            let prefixLen = text.distance(from: text.startIndex, to: tabIdx) + 1
            storage.deleteCharacters(in: NSRange(location: paraRange.location, length: prefixLen))
        }
    }

    // MARK: - Paragraph Styles (shared with MarkdownSerializer)

    static func bodyParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 4
        return style
    }

    static func headingParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 12
        style.paragraphSpacing = 6
        return style
    }

    static func listParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = 20
        style.firstLineHeadIndent = 0
        style.tabStops = [NSTextTab(type: .leftTabStopType, location: 20)]
        style.paragraphSpacing = 2
        return style
    }

    static func blockquoteParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = 16
        style.firstLineHeadIndent = 16
        style.paragraphSpacing = 4
        return style
    }
}
