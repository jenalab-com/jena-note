import AppKit

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

    @objc func changeLineSpacing(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        let multipliers: [CGFloat] = [1.0, 1.5, 2.0]
        let multiplier = multipliers[seg.selectedSegment]
        applyLineSpacing(multiplier)
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
            #selector(changeLineSpacing)
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
