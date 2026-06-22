import AppKit
import UniformTypeIdentifiers

class EditorViewController: NSViewController {

    // MARK: - Properties

    var textView: EditorTextView!
    private var scrollView: NSScrollView!

    var document: MarkdownDocument? {
        return view.window?.windowController?.document as? MarkdownDocument
    }

    // MARK: - View Lifecycle

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize

        let textContainer = NSTextContainer(containerSize: NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = EditorTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.configure()
        textView.delegate = self

        scrollView.documentView = textView
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // document는 아직 nil — loadDocumentContent는 viewWillAppear에서 실행
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadDocumentContent()
    }

    // MARK: - Document Content

    func loadDocumentContent() {
        guard let doc = document, let storage = textView.textStorage else { return }
        storage.setAttributedString(doc.content)
        if storage.length == 0 {
            textView.typingAttributes = textView.defaultTypingAttributes()
        }
        textView.relayoutImageAttachments()
    }

    // MARK: - Format Actions (Responder Chain)

    @objc func toggleBold(_ sender: Any?) {
        FormatCommands.toggleBold(textView)
    }

    @objc func toggleItalic(_ sender: Any?) {
        FormatCommands.toggleItalic(textView)
    }

    @objc func toggleInlineCode(_ sender: Any?) {
        FormatCommands.toggleInlineCode(textView)
    }

    @objc func setHeading1(_ sender: Any?) {
        FormatCommands.setHeading(1, textView: textView)
    }

    @objc func setHeading2(_ sender: Any?) {
        FormatCommands.setHeading(2, textView: textView)
    }

    @objc func setHeading3(_ sender: Any?) {
        FormatCommands.setHeading(3, textView: textView)
    }

    @objc func setBodyText(_ sender: Any?) {
        FormatCommands.setHeading(0, textView: textView)
    }

    @objc func toggleUnorderedList(_ sender: Any?) {
        FormatCommands.toggleUnorderedList(textView)
    }

    @objc func toggleOrderedList(_ sender: Any?) {
        FormatCommands.toggleOrderedList(textView)
    }

    @objc func toggleBlockquote(_ sender: Any?) {
        FormatCommands.toggleBlockquote(textView)
    }

    @objc func insertLink(_ sender: Any?) {
        showLinkDialog()
    }

    @objc func insertHorizontalRule(_ sender: Any?) {
        FormatCommands.insertHorizontalRule(textView)
    }

    // MARK: - Image Insertion

    /// 툴바 이미지 버튼 → 이미지 선택 → attachments로 복사 → 커서 위치에 삽입.
    @objc func insertImage(_ sender: Any?) {
        guard let doc = document, let window = view.window else { return }
        // 미저장 새 문서는 attachments를 둘 폴더(노트 위치)가 없음 → 먼저 저장 유도
        guard doc.fileURL != nil else {
            promptSaveBeforeAttaching(doc, in: window)
            return
        }
        presentImagePicker(for: doc, in: window)
    }

    private func promptSaveBeforeAttaching(_ doc: MarkdownDocument, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "먼저 노트를 저장해주세요"
        alert.informativeText = "이미지는 노트 옆 attachments 폴더에 저장돼요. 노트를 저장한 뒤 다시 첨부해주세요."
        alert.addButton(withTitle: "저장…")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { resp in
            if resp == .alertFirstButtonReturn {
                doc.save(withDelegate: nil, didSave: nil, contextInfo: nil)
            }
        }
    }

    private func presentImagePicker(for doc: MarkdownDocument, in window: NSWindow) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.image]
        } else {
            panel.allowedFileTypes = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            self.attachImage(from: url, to: doc)
        }
    }

    /// 선택한 이미지 파일을 attachments로 복사하고 커서 위치에 삽입한다.
    func attachImage(from url: URL, to doc: MarkdownDocument) {
        do {
            let relPath = try doc.importImage(from: url)
            let alt = url.deletingPathExtension().lastPathComponent
            textView.insertImageAttachment(
                relPath: relPath, alt: alt,
                baseURL: doc.attachmentBaseURL,
                at: textView.selectedRange().location
            )
        } catch {
            if let window = view.window {
                presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
        }
    }

    @objc func changeLineSpacing(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        let multipliers: [CGFloat] = [1.0, 1.5, 2.0]
        let multiplier = multipliers[seg.selectedSegment]
        applyLineSpacing(multiplier)
    }

    /// 툴바의 NSColorWell이 색상 변경을 통지할 때 호출된다.
    /// 선택 범위가 있을 때만 색을 적용한다.
    @objc func changeTextColor(_ sender: Any?) {
        guard let well = sender as? NSColorWell else { return }
        FormatCommands.applyTextColor(textView, color: well.color)
    }

    /// 메뉴 > 서식 > 글자 색… — NSColorPanel을 직접 띄운다.
    @objc func showColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelDidChange(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelDidChange(_ sender: NSColorPanel) {
        FormatCommands.applyTextColor(textView, color: sender.color)
    }

    private func applyLineSpacing(_ multiplier: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        // 변경할 (range, style) 쌍을 먼저 수집 후 일괄 적용 (enumeration 중 수정 방지)
        var changes: [(NSRange, NSMutableParagraphStyle)] = []
        storage.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let base = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
            guard let mutable = base.mutableCopy() as? NSMutableParagraphStyle else { return }
            mutable.lineHeightMultiple = multiplier
            changes.append((range, mutable))
        }
        storage.beginEditing()
        for (range, style) in changes {
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
        // typingAttributes 갱신
        let currentStyle = (textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? NSParagraphStyle.default
        let typingStyle = (currentStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        typingStyle.lineHeightMultiple = multiplier
        textView.typingAttributes[.paragraphStyle] = typingStyle
    }

    // MARK: - Link Dialog

    private func showLinkDialog() {
        guard textView.selectedRange().length > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "링크 삽입"
        alert.informativeText = "URL을 입력하세요"
        alert.addButton(withTitle: "삽입")
        alert.addButton(withTitle: "취소")

        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        urlField.placeholderString = "https://"
        alert.accessoryView = urlField

        alert.beginSheetModal(for: view.window!) { response in
            guard response == .alertFirstButtonReturn else { return }
            let url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { return }
            FormatCommands.insertLink(self.textView, url: url)
        }
    }

    // MARK: - Responder Chain

    override func responds(to aSelector: Selector!) -> Bool {
        let formatSelectors: [Selector] = [
            #selector(toggleBold), #selector(toggleItalic), #selector(toggleInlineCode),
            #selector(setHeading1), #selector(setHeading2), #selector(setHeading3),
            #selector(setBodyText), #selector(toggleUnorderedList), #selector(toggleOrderedList),
            #selector(toggleBlockquote), #selector(insertLink), #selector(insertHorizontalRule),
            #selector(insertImage), #selector(changeLineSpacing),
            #selector(changeTextColor), #selector(showColorPanel)
        ]
        if formatSelectors.contains(aSelector) { return true }
        return super.responds(to: aSelector)
    }
}

// MARK: - NSTextViewDelegate

extension EditorViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let storage = textView.textStorage else { return }
        document?.textDidChange(storage)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateToolbarState()
    }

    private func updateToolbarState() {
        guard let toolbar = view.window?.toolbar as? FormatToolbar else { return }
        guard let storage = textView.textStorage, storage.length > 0 else {
            toolbar.updateState(attributes: textView.typingAttributes)
            return
        }

        let sel = textView.selectedRange()

        // 커서 바로 앞 문자에서 인라인 속성(font/code/link) 읽기
        let readPos: Int
        if sel.length > 0 {
            readPos = min(sel.location, storage.length - 1)
        } else if sel.location > 0 {
            readPos = sel.location - 1
        } else {
            toolbar.updateState(attributes: textView.typingAttributes)
            return
        }

        var attrs = storage.attributes(at: readPos, effectiveRange: nil)

        // mdBlockType이 없거나 설정되지 않은 경우(헤딩 인라인 내용 등)
        // 커서 위치에서 앞으로 스캔해 가장 가까운 \n의 mdBlockType을 사용
        if attrs[.mdBlockType] as? String == nil {
            let str = storage.string as NSString
            var pos = readPos + 1
            while pos < storage.length {
                if str.character(at: pos) == 10 { // \n
                    let nlAttrs = storage.attributes(at: pos, effectiveRange: nil)
                    if let blockType = nlAttrs[.mdBlockType] as? String {
                        attrs[.mdBlockType] = blockType
                    }
                    break
                }
                pos += 1
            }
        }

        toolbar.updateState(attributes: attrs)
    }
}
