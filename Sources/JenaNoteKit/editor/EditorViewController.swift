import AppKit
import UniformTypeIdentifiers

class EditorViewController: NSViewController, ReadingPositionProviding {

    // MARK: - Properties

    var textView: EditorTextView!
    private var scrollView: NSScrollView!

    var document: MarkdownDocument? {
        return view.window?.windowController?.document as? MarkdownDocument
    }

    /// 마지막으로 로드한 문서 — 문서가 바뀐 로드인지(→ 맨 위로), 같은 문서의
    /// 재로드인지(읽기 모드 복귀·외부 리로드 → 보던 위치 유지) 구분용.
    private weak var lastLoadedDocument: MarkdownDocument?

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

        // 읽기 조판에서 읽던 자리를 따라가기 위한 관측 (ADR-0008)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        positionSaveTimer?.invalidate()
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
        guard let doc = document else { return }
        loadContent(of: doc)
    }

    /// 지정한 문서의 내용을 싣는다.
    ///
    /// `document` 는 `view.window?.windowController` 를 타고 오므로, 뷰가 윈도우에서
    /// 분리돼 있는 동안(페이징 조판 등)에는 nil 이라 `loadDocumentContent()` 가 조용히
    /// 건너뛴다. 그 사이 문서가 바뀌면 옛 문서가 에디터에 남으므로, 호출자가 문서를
    /// 알고 있을 때는 이쪽으로 직접 실어 윈도우 부착 타이밍에 기대지 않는다.
    func loadContent(of doc: MarkdownDocument) {
        guard let storage = textView.textStorage else { return }
        storage.setAttributedString(doc.content)
        if storage.length == 0 {
            textView.typingAttributes = textView.defaultTypingAttributes()
        }
        // 문서는 언제나 원본 스타일로 들어온다 — 조판이 켜져 있으면 새 문서에도 다시 입힌다.
        if isReadingLayout { restyleStorage(keepSelection: false) }
        textView.relayoutImageAttachments()
        if lastLoadedDocument !== doc {
            lastLoadedDocument = doc
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scroll(.zero)
        }
        updateStatusBarCharCount()
    }

    // MARK: - Reading Layout (ADR-0009)

    /// 읽기 조판이 켜져 있는지. 켜져 있어도 편집·서식·저장은 그대로 동작한다.
    private(set) var isReadingLayout = false

    /// 읽기 단 폭 프리셋. 조판이 켜져 있을 때만 의미가 있고 저장하지 않는다.
    var readingWidthMode: ReaderMetrics.WidthMode = .book {
        // 단 폭은 조판(폰트·행간)이 아니라 여백만 바꾸므로 다시 칠할 필요가 없다.
        didSet { if isReadingLayout && readingWidthMode != oldValue { updateColumnInset() } }
    }

    /// 읽기 조판을 켜거나 끈다.
    ///
    /// 조판은 **화면에만** 입힌다. 문서로 나가는 내용은 `textDidChange` 에서 조판을 벗겨
    /// 넘기므로, 켜고 끄는 것만으로는 문서가 더러워지지도(dirty) 저장 결과가 달라지지도
    /// 않는다. 읽기 전용이던 시절의 계약(원본 불변)을 편집 가능해진 뒤에도 지키는 방식이다.
    func setReadingLayout(_ on: Bool) {
        guard on != isReadingLayout else { return }
        isReadingLayout = on
        restyleStorage()
    }

    /// 읽기 설정(배율·서체·행간)이 바뀌었을 때 조판을 다시 입힌다.
    func refreshReadingLayout() {
        guard isReadingLayout else { return }
        restyleStorage()
    }

    /// 현재 조판 상태에 맞춰 화면 스토리지를 다시 칠한다. 문자열은 건드리지 않으므로
    /// 선택 위치가 그대로 유효하다.
    private func restyleStorage(keepSelection: Bool = true) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let source = NSAttributedString(attributedString: storage)
        let s = SettingsManager.shared
        let next = isReadingLayout
            ? ReaderMetrics.styled(source, scale: s.readingFontScale, font: s.readingFont,
                                   lineHeightMultiple: s.readingLineSpacing,
                                   weight: s.readingWeight)
            : ReaderMetrics.unstyled(source)

        storage.beginEditing()
        storage.setAttributedString(next)
        storage.endEditing()

        if keepSelection, NSMaxRange(selection) <= storage.length {
            textView.setSelectedRange(selection)
        }
        syncTypingAttributes(at: selection.location)
        updateColumnInset()
        textView.relayoutImageAttachments()
    }

    /// 커서 자리의 실제 속성을 타이핑 속성으로 물려준다 — 조판 상태에서 이어 쳐도
    /// 글자가 튀지 않는다. 단, 조판 백업 키는 빼고 넘긴다. 새로 친 글자에 남의 원본
    /// 폰트가 백업으로 붙으면 조판을 벗길 때 엉뚱한 폰트로 되돌아간다.
    private func syncTypingAttributes(at location: Int) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let pos = min(max(0, location), storage.length - 1)
        var attrs = storage.attributes(at: pos, effectiveRange: nil)
        attrs.removeValue(forKey: .mdBaseFont)
        attrs.removeValue(forKey: .mdBaseParagraph)
        textView.typingAttributes = attrs
    }

    /// 조판이 켜져 있으면 본문 단을 가운데로 좁히고, 꺼져 있으면 기본 여백으로 되돌린다.
    private func updateColumnInset() {
        let base = EditorTextView.defaultContainerInset
        guard isReadingLayout else {
            if abs(textView.textContainerInset.width - base.width) > 0.5 {
                textView.textContainerInset = base
            }
            return
        }
        let available = scrollView.contentView.bounds.width
        guard available > 0 else { return }
        let column = ReaderMetrics.columnWidth(mode: readingWidthMode)
        let side = max(base.width, (available - column) / 2)
        if abs(textView.textContainerInset.width - side) > 0.5 {
            textView.textContainerInset = NSSize(width: side, height: base.height)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateColumnInset()
        // 레이아웃이 잡히길 기다리던 복원이 있으면 지금 적용한다.
        if needsAnchorApply { applyAnchor() }
    }

    // MARK: - Reading Position (ADR-0008)

    /// 읽던 자리의 문자 오프셋 — 표시 설정과 무관한 유일한 좌표.
    private var anchorOffset = 0
    /// 복원이 아직 화면에 반영되지 않았음. 이 동안은 화면에서 위치를 되읽지 않는다.
    private var needsAnchorApply = false
    private var positionSaveTimer: Timer?

    var currentCharacterOffset: Int { anchorOffset }
    var contentString: String { textView.string }
    var visibleCharacterRange: NSRange {
        ScrollReadingPosition.visibleRange(textView: textView, scrollView: scrollView)
    }
    var onPositionChanged: ((Int) -> Void)?

    func restore(to offset: Int) {
        anchorOffset = max(0, offset)
        needsAnchorApply = true
        applyAnchor()
    }

    func flushPositionChange() {
        guard positionSaveTimer != nil else { return }
        positionSaveTimer?.invalidate()
        positionSaveTimer = nil
        onPositionChanged?(anchorOffset)
    }

    private func applyAnchor() {
        guard view.bounds.height > 0 else { return }
        ScrollReadingPosition.scroll(textView: textView, to: anchorOffset)
        needsAnchorApply = false
    }

    /// 화면에 보이는 위치를 읽어 앵커에 반영한다. 복원 대기 중이면 건너뛴다
    /// (아직 옛 위치를 보여주는 화면에서 되읽으면 복원값을 덮어쓰게 된다).
    private func captureAnchor() {
        guard isReadingLayout, !needsAnchorApply else { return }
        let newOffset = ScrollReadingPosition.offset(textView: textView, scrollView: scrollView)
        guard newOffset != anchorOffset else { return }
        anchorOffset = newOffset
        positionSaveTimer?.invalidate()
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.positionSaveTimer = nil
            self.onPositionChanged?(self.anchorOffset)
        }
    }

    @objc private func editorDidScroll(_ note: Notification) {
        captureAnchor()
    }

    /// 주어진 오프셋에 커서를 두고 그 자리를 화면에 띄운다.
    /// 페이징 조판에서 타이핑이 시작돼 스크롤 조판으로 갈아탈 때 쓴다.
    func placeCursor(at offset: Int) {
        guard let storage = textView.textStorage else { return }
        let loc = min(max(0, offset), storage.length)
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        restore(to: loc)
        syncTypingAttributes(at: loc)
    }

    /// 전체 검색 결과 클릭 → 에디터 텍스트에서 검색어의 n번째 occurrence를 선택·표시.
    /// 원문(.md) 오프셋은 WYSIWYG 변환 후와 달라 직접 매핑이 불가하므로 순번 매칭을 쓴다.
    /// n번째가 없으면(기호 내부 매치 등) 첫 occurrence로 폴백, 그것도 없으면 점프 생략.
    func jumpToMatch(_ jump: SearchJump) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        guard let range = SearchMatchLocator.range(ofOccurrence: jump.ordinal, query: jump.query, in: text)
                ?? SearchMatchLocator.range(ofOccurrence: 0, query: jump.query, in: text) else { return }
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    /// 현재 텍스트의 글자수를 윈도우 하단 상태바에 반영한다.
    private func updateStatusBarCharCount() {
        guard let storage = textView.textStorage else { return }
        let controller = view.window?.windowController as? EditorWindowController
        controller?.updateCharCount(for: storage.string)
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

    /// 툴바 🔍 버튼 → 찾기 바 노출.
    @objc func showFindBar(_ sender: Any?) {
        view.window?.makeFirstResponder(textView)
        let proxy = NSMenuItem()
        proxy.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(proxy)
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
            #selector(changeTextColor), #selector(showColorPanel), #selector(showFindBar)
        ]
        if formatSelectors.contains(aSelector) { return true }
        return super.responds(to: aSelector)
    }
}

// MARK: - NSTextViewDelegate

extension EditorViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let storage = textView.textStorage else { return }
        // 조판은 화면에만 입힌다 — 문서에는 언제나 원본 스타일로 넘긴다.
        // 덕분에 조판을 켠 채 저장해도 파일에 읽기용 서체·배율이 눌러앉지 않는다.
        let content: NSAttributedString = isReadingLayout ? ReaderMetrics.unstyled(storage) : storage
        document?.textDidChange(content)
        updateStatusBarCharCount()
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
