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
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        textContainerInset = NSSize(width: 60, height: 40)
        typingAttributes = defaultTypingAttributes()

        // 사이드바 이미지 리스트(또는 Finder)에서 이미지 파일을 드롭받기 위해 파일 URL 타입 등록.
        // 내부 텍스트/첨부 이동 드래그는 NSTextView 기본 처리(super)에 맡긴다.
        var types = registeredDraggedTypes
        if !types.contains(.fileURL) { types.append(.fileURL) }
        registerForDraggedTypes(types)
    }

    // MARK: - Drag & Drop (이미지 파일 드롭 → 첨부 삽입)

    private func imageURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else { return [] }
        return urls.filter { sidebarImageExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !imageURLs(from: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !imageURLs(from: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender.draggingPasteboard)
        // 이미지 파일 드롭이 아니면(내부 텍스트/첨부 이동 등) 기본 처리에 위임
        guard !urls.isEmpty else { return super.performDragOperation(sender) }

        guard let doc = window?.windowController?.document as? MarkdownDocument,
              doc.fileURL != nil else {
            // 저장 안 된 문서 → 첨부 폴더가 없으므로 기본 처리에 맡긴다
            return super.performDragOperation(sender)
        }

        let point = convert(sender.draggingLocation, from: nil)
        var insertAt = characterIndexForInsertion(at: point)

        var inserted = false
        for url in urls {
            guard let relPath = try? doc.importImage(from: url) else { continue }
            let alt = url.deletingPathExtension().lastPathComponent
            insertImageAttachment(relPath: relPath, alt: alt, baseURL: doc.attachmentBaseURL, at: insertAt)
            insertAt = selectedRange().location
            inserted = true
        }
        return inserted
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

    // MARK: - Image Attachment

    /// 지정 위치(기본: 현재 커서)에 이미지 첨부를 자체 단락으로 삽입한다.
    /// 앞뒤에 줄바꿈을 보장해 본문 텍스트와 한 줄에 섞이지 않게 한다.
    func insertImageAttachment(relPath: String, alt: String, baseURL: URL?, at location: Int) {
        guard let storage = textStorage else { return }
        let clamped = max(0, min(location, storage.length))
        let nsstr = storage.string as NSString

        let attachmentStr = MarkdownSerializer.makeImageAttachment(relPath: relPath, alt: alt, baseURL: baseURL)
        let bodyAttrs = defaultTypingAttributes()

        let needLeadingNL = clamped > 0 && nsstr.character(at: clamped - 1) != 10
        let needTrailingNL = clamped >= storage.length || nsstr.character(at: clamped) != 10

        let insertion = NSMutableAttributedString()
        if needLeadingNL { insertion.append(NSAttributedString(string: "\n", attributes: bodyAttrs)) }
        insertion.append(attachmentStr)
        if needTrailingNL { insertion.append(NSAttributedString(string: "\n", attributes: bodyAttrs)) }

        guard shouldChangeText(in: NSRange(location: clamped, length: 0), replacementString: nil) else { return }
        storage.insert(insertion, at: clamped)
        let caret = min(clamped + insertion.length, storage.length)
        setSelectedRange(NSRange(location: caret, length: 0))
        didChangeText()
        relayoutImageAttachments()
    }

    // MARK: - Context Menu: 이미지 크기 조절

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let storage = textStorage, let lm = layoutManager, let container = textContainer else { return menu }

        let point = convert(event.locationInWindow, from: nil)
        let inset = textContainerInset
        let cp = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
        let glyphIndex = lm.glyphIndex(for: cp, in: container)
        guard glyphIndex < lm.numberOfGlyphs else { return menu }
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)

        guard charIndex < storage.length,
              storage.attribute(.mdImageRelPath, at: charIndex, effectiveRange: nil) != nil else {
            return menu
        }

        let item = NSMenuItem(title: "이미지 크기…", action: #selector(editImageSize(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = charIndex
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func editImageSize(_ sender: NSMenuItem) {
        guard let charIndex = sender.representedObject as? Int,
              let storage = textStorage, charIndex < storage.length,
              let window = window else { return }
        let current = storage.attribute(.mdImageWidth, at: charIndex, effectiveRange: nil) as? Int

        let alert = NSAlert()
        alert.messageText = "이미지 크기"
        alert.informativeText = "폭(px)을 입력하세요. 비우면 창 너비에 맞춥니다."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = current.map(String.init) ?? ""
        field.placeholderString = "예: 300"
        alert.accessoryView = field
        alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
            self?.applyImageWidth(trimmed.isEmpty ? nil : Int(trimmed), at: charIndex)
        }
    }

    private func applyImageWidth(_ width: Int?, at charIndex: Int) {
        guard let storage = textStorage, charIndex < storage.length else { return }
        let range = NSRange(location: charIndex, length: 1)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        if let width = width, width > 0 {
            storage.addAttribute(.mdImageWidth, value: width, range: range)
        } else {
            storage.removeAttribute(.mdImageWidth, range: range)
        }
        didChangeText()
        relayoutImageAttachments()
    }

    // MARK: - Image Attachment Sizing

    /// 모든 이미지 첨부의 `bounds`를 현재 컨테이너 폭(과 지정 폭)에 맞춰 다시 계산한다.
    /// 창 리사이즈·문서 로드·크기 변경 시 호출 — bounds를 직접 갱신하므로 glyph 캐시와 무관하게 반영된다.
    func relayoutImageAttachments() {
        guard let storage = textStorage, let container = textContainer, let lm = layoutManager else { return }
        let available = container.size.width - 2 * container.lineFragmentPadding
        // 레이아웃 전(컨테이너 폭 미정)에는 건너뛴다 — 이후 setFrameSize에서 다시 불린다.
        guard available > 10 else { return }

        let fullRange = NSRange(location: 0, length: storage.length)
        var dirtyRanges: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image else { return }
            let cap: CGFloat
            if let w = storage.attribute(.mdImageWidth, at: range.location, effectiveRange: nil) as? Int, w > 0 {
                cap = min(CGFloat(w), available)
            } else {
                cap = available
            }
            let newBounds = MarkdownSerializer.imageBounds(for: image.size, maxWidth: cap)
            if abs(attachment.bounds.width - newBounds.width) > 0.5 ||
               abs(attachment.bounds.height - newBounds.height) > 0.5 {
                attachment.bounds = newBounds
                dirtyRanges.append(range)
            }
        }
        for r in dirtyRanges {
            lm.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        }
        if !dirtyRanges.isEmpty { needsDisplay = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayoutImageAttachments()
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
