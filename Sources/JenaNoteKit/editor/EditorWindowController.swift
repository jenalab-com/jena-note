import AppKit

class EditorWindowController: NSWindowController {

    // MARK: - Children

    private(set) var sidebarVC: SidebarViewController!
    private(set) var editorVC: EditorViewController!
    private var splitVC: NSSplitViewController!
    private let statusBar = StatusBarView()
    private var lastNotifiedMissingURL: URL?
    private var readerCountWork: DispatchWorkItem?
    private(set) var aiChatVC: AIChatViewController?
    var proofreadingController: AIProofreadingController?
    var proofreadingService = AISelectionProofreader()
    private(set) var isAIActive = false
    private var previousMinimumSize: NSSize?
    private(set) var sourcePreview: MarkdownSourceViewController?
    private(set) var isShowingSource = false
    private var sourceReturnSelection = NSRange(location: 0, length: 0)
    private var sourceReturnOffset = 0
    private var aiPanelWidth = AIChatViewController.defaultPanelWidth

    /// 검색 결과 클릭으로 문서를 여는 중일 때, 스왑 완료 후 실행할 점프.
    private var pendingSearchJump: SearchJump?
    /// Opens a file for a sidebar swap. Replaceable in tests to control completion order.
    var documentOpener: (URL, @escaping (NSDocument?, Bool, Error?) -> Void) -> Void = { url, completion in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false, completionHandler: completion)
    }
    /// The latest sidebar swap request. Cloud-backed files can take seconds to read, so earlier
    /// requests may complete after later ones; only the latest is applied.
    private var pendingSwap: (id: Int, url: URL)?
    private var swapCounter = 0

    // MARK: - Unified document layout

    /// 페이지 보기에서는 페이지 편집기, 스크롤 보기에서는 연속 편집기를 사용한다.
    private(set) var readerVC: ReaderViewController?
    private var readerToolbar: ReaderToolbar?
    private var bookmarkPopover: NSPopover?

    /// 지금 읽던 자리를 쥐고 있는 화면 — 페이징이면 리더 오버레이, 스크롤이면 에디터.
    private var positionProvider: ReadingPositionProviding? {
        guard !isShowingSource else { return nil }
        return readerVC ?? editorVC
    }

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 360)
        window.titlebarAppearsTransparent = false
        window.center()

        self.init(window: window)

        let sidebar = SidebarViewController()
        let editor = EditorViewController()

        let split = NSSplitViewController()
        split.splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        if #available(macOS 11.0, *) {
            sidebarItem.titlebarSeparatorStyle = .automatic
        }

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 360

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(editorItem)

        self.sidebarVC = sidebar
        self.editorVC = editor
        editor.hostWindowController = self
        self.splitVC = split

        setupContentLayout(window: window, split: split)
        setupToolbar(for: window)
        editorVC.setReadingLayout(true)
        editorVC.onPositionChanged = { [weak self] offset in
            self?.saveReadingProgress(offset: offset)
            self?.updateBookmarkButtonState()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(workIndexChanged),
                                                name: AIWorkIndexStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(aiWindowWillClose),
                                                name: NSWindow.willCloseNotification, object: window)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleExternalContentsChange),
            name: .folderContentsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDocumentReloadedFromDisk(_:)),
            name: .documentDidReloadFromDisk, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleReaderContentChanged(_:)),
            name: .documentReaderContentChanged, object: nil
        )
    }

    deinit {
        proofreadingController?.cancel()
        readerCountWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Content Layout (윈도우 하단 상태바)

    /// split 뷰(위) + 상태바(아래 고정)를 컨테이너에 형제로 담아 윈도우 콘텐츠로 둔다.
    /// jena-image 의 검증된 패턴 — `addChild(split)` 로 split VC 를 컨테이너 VC 의 자식으로
    /// 등록해야 사이드바-타이틀바 통합이 유지된다. (이 등록을 빠뜨리면 통합이 깨진다.)
    private func setupContentLayout(window: NSWindow, split: NSSplitViewController) {
        let container = NSView()

        split.view.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(split.view)
        container.addSubview(statusBar)

        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: container.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.barHeight),
        ])

        let containerVC = NSViewController()
        containerVC.view = container
        containerVC.addChild(split)
        window.contentViewController = containerVC
    }

    /// 텍스트로부터 글자수를 계산해 상태바를 갱신한다.
    func updateCharCount(for text: String) {
        let counts = TextMetrics.counts(for: text)
        let noSpaces = TextMetrics.formatted(counts.noSpaces)
        let withSpaces = TextMetrics.formatted(counts.withSpaces)
        statusBar.setCharCountText(String(format: L10n.tr("status.charCount"), noSpaces, withSpaces))
    }

    // MARK: - Toolbar

    private func setupToolbar(for window: NSWindow) {
        let toolbar = ReaderToolbar(identifier: NSToolbar.Identifier("UnifiedToolbar"))
        toolbar.target = self
        toolbar.formatTarget = editorVC
        window.toolbar = toolbar
        readerToolbar = toolbar
    }

    // MARK: - Document → View 연결

    override func windowDidLoad() {
        super.windowDidLoad()
        editorVC.loadDocumentContent()
        updateSidebarSelection()
    }

    override var document: AnyObject? {
        get { super.document }
        set {
            if super.document !== newValue { proofreadingController?.cancel() }
            if let old = super.document as? MarkdownDocument, isAIActive {
                _ = AIConversationStore.shared.conversation(for: old)
            }
            if super.document != nil { positionProvider?.flushPositionChange() }
            super.document = newValue
            sourcePreview?.setDocument(newValue as? MarkdownDocument)
            if isShowingSource {
                sourceReturnSelection = NSRange(location: 0, length: 0)
                sourceReturnOffset = 0
                if let doc = newValue as? MarkdownDocument, let url = doc.fileURL,
                   let anchor = ReadingProgressStore.shared.anchor(for: url) {
                    sourceReturnOffset = anchor.resolve(in: doc.content.string)
                }
            }
            if let doc = newValue as? MarkdownDocument, editorVC != nil {
                editorVC.loadContent(of: doc)
                if let reader = readerVC { reader.updateContent(doc.content) }
                else if !isAIActive && !isShowingSource { applyReadingPageMode(SettingsManager.shared.readingPageMode) }
                restoreReadingProgress()
                updateCharCount(for: doc.content.string)
            }
            updateSidebarSelection()
            aiChatVC?.switchDocument()
            AIWorkIndexStore.prepareDocument((newValue as? MarkdownDocument)?.fileURL)
            workIndexChanged()
        }
    }

    @objc private func workIndexChanged() {
        guard let url = (document as? MarkdownDocument)?.fileURL,
              let context = AIWorkContext.locate(from: url), context.config.enabled else {
            statusBar.setWorkStatus("")
            return
        }
        statusBar.setWorkStatus(AIWorkIndexStore.shared(for: context.rootURL).statusText)
    }

    // MARK: - Window Title

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        if document == nil {
            window?.title = L10n.tr("untitled")
        }
    }

    @objc func showMarkdownSource(_ sender: Any?) {
        if isShowingSource { hideMarkdownSource(); return }
        guard let doc = document as? MarkdownDocument else { return }
        readerVC?.finishComposition()
        sourceReturnSelection = documentSelection
        sourceReturnOffset = positionProvider?.currentCharacterOffset ?? 0
        positionProvider?.flushPositionChange()
        if sourcePreview == nil { sourcePreview = MarkdownSourceViewController() }
        sourcePreview?.show(document: doc)
        isShowingSource = true
        swapRightPane(to: sourcePreview!)
        readerToolbar?.setSourceActive(true)
        window?.makeFirstResponder(sourcePreview?.textView)
    }

    private func hideMarkdownSource() {
        guard isShowingSource else { return }
        isShowingSource = false
        sourcePreview?.suspend()
        swapRightPane(to: readerVC ?? editorVC)
        readerToolbar?.setSourceActive(false)
        positionProvider?.restore(to: sourceReturnOffset)
        if let doc = document as? MarkdownDocument, sourceReturnSelection.length > 0,
           NSMaxRange(sourceReturnSelection) <= doc.content.length {
            selectDocumentRange(sourceReturnSelection)
        } else {
            window?.makeFirstResponder((readerVC?.visiblePageTextViews.first as NSTextView?) ?? editorVC.textView)
        }
        editorVC.updateToolbarState()
    }

    func refreshSourcePreview() { sourcePreview?.scheduleRefresh() }

    // MARK: - AI chat

    @objc func toggleAI(_ sender: Any?) {
        if isShowingSource { hideMarkdownSource() }
        if isAIActive {
            aiChatVC?.suspend()
            if let chat = aiChatVC {
                aiPanelWidth = min(max(chat.view.bounds.width, AIChatViewController.minimumPanelWidth),
                                   AIChatViewController.maximumPanelWidth)
            }
            if let item = splitVC.splitViewItems.first(where: { $0.viewController === aiChatVC }) {
                splitVC.removeSplitViewItem(item)
            }
            aiChatVC = nil
            isAIActive = false
            if let size = previousMinimumSize { window?.minSize = size }
            readerToolbar?.setAIActive(false)
            applyReadingPageMode(SettingsManager.shared.readingPageMode)
            readerToolbar?.updatePageModeSelection(SettingsManager.shared.readingPageMode)
            return
        }
        let selection = readerVC?.selectedTextRange ?? editorVC.textView.selectedRange()
        isAIActive = true
        removePagedReader()
        if NSMaxRange(selection) <= editorVC.textView.string.utf16.count {
            editorVC.textView.setSelectedRange(selection)
        }
        readerToolbar?.setAIActive(true)
        let chat = AIChatViewController()
        chat.currentDocument = { [weak self] in self?.document as? MarkdownDocument }
        chat.currentSelection = { [weak self] in
            guard let self = self, !self.isShowingSource else { return NSRange(location: 0, length: 0) }
            return self.editorVC.textView.selectedRange()
        }
        chat.applyEdit = { [weak self] snapshot, text in
            guard let self = self, let doc = self.document as? MarkdownDocument,
                  snapshot.canApply(to: doc), !self.editorVC.textView.hasMarkedText() else {
                throw AIError(message: L10n.tr("ai.editConflict"))
            }
            let (range, replacement) = try snapshot.replacement(text)
            guard range.length > 0 || replacement.length > 0 else { return }
            self.editorVC.textView.breakUndoCoalescing()
            doc.undoManager?.beginUndoGrouping()
            doc.replaceReaderContent(in: range, with: replacement)
            doc.undoManager?.setActionName(L10n.tr("ai.edit"))
            doc.undoManager?.endUndoGrouping()
            self.editorVC.textView.setSelectedRange(NSRange(location: range.location, length: replacement.length))
            self.editorVC.textView.scrollRangeToVisible(NSRange(location: range.location, length: replacement.length))
        }
        aiChatVC = chat
        let item = NSSplitViewItem(viewController: chat)
        item.minimumThickness = AIChatViewController.minimumPanelWidth
        item.maximumThickness = AIChatViewController.maximumPanelWidth
        item.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        chat.view.setFrameSize(NSSize(width: aiPanelWidth, height: splitVC.splitView.bounds.height))
        previousMinimumSize = window?.minSize
        window?.minSize = NSSize(width: 900, height: 560)
        if let window = window {
            var frame = window.frame
            frame.size.width = max(frame.width, 1100)
            frame.size.height = max(frame.height, 640)
            window.setFrame(frame, display: true)
        }
        splitVC.addSplitViewItem(item)
        splitVC.view.layoutSubtreeIfNeeded()
        let divider = splitVC.splitViewItems.count - 2
        splitVC.splitView.setPosition(splitVC.splitView.bounds.width - aiPanelWidth - splitVC.splitView.dividerThickness,
                                     ofDividerAt: divider)
        chat.switchDocument()
    }

    @objc private func aiWindowWillClose() {
        proofreadingController?.cancel()
        sourcePreview?.suspend()
        positionProvider?.flushPositionChange()
        bookmarkPopover?.performClose(nil)
        aiChatVC?.suspend()
        if let doc = document as? MarkdownDocument, isAIActive {
            _ = AIConversationStore.shared.conversation(for: doc)
        }
    }

    // MARK: - Sidebar Toggle

    @objc func toggleSidebar(_ sender: Any?) {
        splitVC.toggleSidebar(sender)
    }

    /// 편집 > 파일에서 찾기 (⇧⌘F) — 사이드바를 펼치고 검색 필드에 포커스.
    @objc func findInFiles(_ sender: Any?) {
        if let sidebarItem = splitVC.splitViewItems.first, sidebarItem.isCollapsed {
            sidebarItem.animator().isCollapsed = false
        }
        sidebarVC.focusSearchField()
    }

    // MARK: - 조판 전환 (스크롤 ↔ 페이징)

    /// 페이지·스크롤 보기 사이에서 편집 화면을 바꾼다.
    /// 읽던 자리는 넘겨받는 쪽이 이어받는다.
    func applyReadingPageMode(_ mode: SettingsManager.ReadingPageMode) {
        guard !isShowingSource else { return }
        let selection = documentSelection
        SettingsManager.shared.readingPageMode = mode
        readerToolbar?.updatePageModeSelection(mode)
        if mode == .paged { installPagedReader() } else { removePagedReader() }
        if selection.length > 0, let doc = document as? MarkdownDocument, NSMaxRange(selection) <= doc.content.length {
            selectDocumentRange(selection)
        }
    }

    private func installPagedReader() {
        guard !isAIActive, readerVC == nil else { return }
        let offset = editorVC.currentCharacterOffset
        editorVC.flushPositionChange()

        // 리더는 자기 조판을 입히므로 조판을 벗긴 원본을 넘긴다 (이중 조판 방지).
        let live = editorVC.textView.textStorage.map { ReaderMetrics.unstyled($0) }
            ?? (document as? MarkdownDocument)?.content
            ?? NSAttributedString()
        let reader = ReaderViewController(content: live)
        reader.formattingTarget = editorVC
        reader.onPositionChanged = { [weak self] offset in
            self?.saveReadingProgress(offset: offset)
            self?.updateBookmarkButtonState()
        }
        reader.onContentEdit = { [weak self, weak reader] range, replacement in
            (self?.document as? MarkdownDocument)?.replaceReaderContent(
                in: range, with: replacement, origin: reader)
        }
        reader.documentUndoManager = { [weak self] in
            (self?.document as? MarkdownDocument)?.undoManager
        }
        readerVC = reader
        swapRightPane(to: reader)
        // Programmatic split replacement may not deliver viewDidAppear immediately.
        reader.setPageMode(.paged)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleReaderPageChanged(_:)),
            name: .readerPageChanged, object: reader)
        reader.setWidthMode(editorVC.readingWidthMode)
        reader.restore(to: offset)
    }

    private func removePagedReader() {
        guard let reader = readerVC else { return }
        reader.finishComposition()
        let offset = reader.currentCharacterOffset
        reader.flushPositionChange()
        NotificationCenter.default.removeObserver(self, name: .readerPageChanged, object: reader)
        readerVC = nil
        swapRightPane(to: editorVC)
        // 페이징 동안 에디터 뷰는 윈도우에서 분리돼 있었다. 그 사이 사이드바로 문서가
        // 바뀌었다면 에디터에는 옛 문서가 남아 있으므로 다시 싣는다. 이때 문서를 직접
        // 넘기는 이유는 `editorVC.document` 가 window 를 타고 오기 때문 — 방금 붙인
        // 참에 그 타이밍에 기대면 같은 버그가 되돌아온다.
        if let doc = document as? MarkdownDocument {
            editorVC.loadContent(of: doc)
        }
        editorVC.restore(to: offset)
    }

    /// 문서가 Undo를 소유하므로 페이지 이동·모드 전환 후에도 같은 이력을 쓴다.
    @objc private func handleReaderContentChanged(_ note: Notification) {
        guard let doc = document as? MarkdownDocument,
              (note.object as? MarkdownDocument) === doc,
              let range = (note.userInfo?["range"] as? NSValue)?.rangeValue,
              let replacement = note.userInfo?["replacement"] as? NSAttributedString else { return }
        if let reader = readerVC {
            if (note.userInfo?["origin"] as AnyObject?) !== reader {
                reader.applyDocumentEdit(in: range, replacement: replacement)
            }
        } else {
            editorVC.loadContent(of: doc)
        }
        if let url = doc.fileURL {
            BookmarkStore.shared.adjustForEdit(in: range, replacementLength: replacement.length,
                                               text: doc.content.string, for: url)
        }
        updateBookmarkButtonState()
        if isShowingSource {
            sourceReturnOffset = ReadingAnchor.offsetAfterEdit(sourceReturnOffset, range: range, replacementLength: replacement.length)
            sourceReturnSelection = NSRange(location: min(sourceReturnSelection.location, doc.content.length), length: 0)
        }
        refreshSourcePreview()
        // Counting a whole novel is unrelated to the typing-critical path.
        readerCountWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak doc] in
            guard let self = self, let doc = doc,
                  (self.document as? MarkdownDocument) === doc else { return }
            self.updateCharCount(for: doc.content.string)
        }
        readerCountWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: - 책갈피 (ADR-0008)

    /// 지금 보이는 화면에 책갈피가 있으면 해제, 없으면 현재 위치에 추가한다 (⌘D).
    @objc func toggleBookmark(_ sender: Any?) {
        guard let reader = positionProvider,
              let url = (document as? MarkdownDocument)?.fileURL else { return }
        if !BookmarkStore.shared.removeBookmarks(in: reader.visibleCharacterRange, for: url) {
            let anchor = ReadingAnchor.make(offset: reader.currentCharacterOffset, in: reader.contentString)
            BookmarkStore.shared.add(anchor, for: url)
        }
        updateBookmarkButtonState()
    }

    @objc func showBookmarkList(_ sender: Any?) {
        guard let reader = positionProvider,
              let url = (document as? MarkdownDocument)?.fileURL else { return }
        guard let anchorView = (sender as? NSView) ?? readerToolbar?.bookmarkAnchorView else { return }

        let text = reader.contentString
        let listVC = BookmarkListViewController(anchors: BookmarkStore.shared.bookmarks(for: url),
                                                contentString: text)
        listVC.onSelect = { [weak self] anchor in
            self?.bookmarkPopover?.performClose(nil)
            self?.positionProvider?.restore(to: anchor.resolve(in: text))
            self?.updateBookmarkButtonState()
        }
        listVC.onDelete = { [weak self] anchor in
            BookmarkStore.shared.removeBookmark(atOffset: anchor.characterOffset, for: url)
            self?.updateBookmarkButtonState()
        }

        let popover = NSPopover()
        popover.contentViewController = listVC
        popover.contentSize = listVC.preferredSize
        popover.behavior = .transient
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        bookmarkPopover = popover
    }

    /// 현재 화면에 책갈피가 있는지를 툴바 아이콘에 반영한다.
    private func updateBookmarkButtonState() {
        guard let reader = positionProvider, let toolbar = readerToolbar else { return }
        guard let url = (document as? MarkdownDocument)?.fileURL else {
            toolbar.updateBookmarkState(active: false)
            return
        }
        let visible = reader.visibleCharacterRange
        let active = BookmarkStore.shared.bookmarks(for: url)
            .contains { NSLocationInRange($0.characterOffset, visible) }
        toolbar.updateBookmarkState(active: active)
    }

    @objc private func handleReaderPageChanged(_ note: Notification) {
        updateBookmarkButtonState()
    }

    // MARK: - 이어읽기 (ADR-0008)

    /// 읽던 위치를 문서별로 저장한다. 표시 설정과 무관하도록 문자 오프셋 + 문맥 스니펫만 남긴다.
    private func saveReadingProgress(offset: Int) {
        guard let reader = positionProvider,
              let url = (document as? MarkdownDocument)?.fileURL else { return }
        let anchor = ReadingAnchor.make(offset: offset, in: reader.contentString)
        ReadingProgressStore.shared.setAnchorOrClear(anchor, for: url)
    }

    /// 저장돼 있던 위치를 현재 문서에서 되찾아 지금 화면에 적용한다.
    /// 문서가 그새 편집됐으면 문맥 스니펫으로 재동기화된다.
    private func restoreReadingProgress() {
        guard let reader = positionProvider,
              let url = (document as? MarkdownDocument)?.fileURL,
              let anchor = ReadingProgressStore.shared.anchor(for: url) else { return }
        reader.restore(to: anchor.resolve(in: reader.contentString))
    }

    private func swapRightPane(to vc: NSViewController) {
        // 컨테이너로 감싸 contentViewController 캐스팅이 불가하므로 splitVC 를 직접 참조한다.
        guard let split = splitVC else { return }
        // 우측(인덱스 1) item 교체. 좌측 사이드바는 유지.
        if split.splitViewItems.count > 1 {
            split.removeSplitViewItem(split.splitViewItems[1])
        }
        let item = NSSplitViewItem(viewController: vc)
        item.minimumThickness = 360
        split.insertSplitViewItem(item, at: 1)
    }

    // MARK: - Reader Toolbar Actions

    // 조판 설정은 SettingsManager 가 단일 원본이고, 지금 화면을 쥔 쪽만 다시 그린다.
    // 페이징이면 리더가, 스크롤이면 에디터가 조판을 다시 입는다.

    @objc func changeReaderPageMode(_ sender: Any?) {
        guard !isAIActive else { readerToolbar?.setAIActive(true); return }
        guard let seg = sender as? NSSegmentedControl else { return }
        applyReadingPageMode((seg.selectedSegment == 1) ? .paged : .scroll)
    }

    @objc func changeDocumentPaperSize(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let size = DocumentPaperSize(rawValue: raw) else { return }
        DocumentPaperSize.selected = size
    }

    @objc func changeReaderWidth(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        let mode: ReaderMetrics.WidthMode = (seg.selectedSegment == 0) ? .mobile : .book
        readerVC?.setWidthMode(mode)
        editorVC.readingWidthMode = mode
    }

    @objc func decreaseReaderFont(_ sender: Any?) {
        setReadingFontScale(SettingsManager.shared.readingFontScale - 0.1)
    }

    @objc func increaseReaderFont(_ sender: Any?) {
        setReadingFontScale(SettingsManager.shared.readingFontScale + 0.1)
    }

    private func setReadingFontScale(_ value: CGFloat) {
        let clamped = min(max(value, 0.8), 2.0)
        SettingsManager.shared.readingFontScale = clamped
        readerVC?.setFontScale(clamped)
        editorVC.refreshReadingLayout()
    }

    /// 서체 선택 — 팝업 항목에 실린 `ReadingFont.rawValue` 로 되짚는다.
    /// 목록이 설치 상황에 따라 달라지므로 선택 인덱스는 신뢰할 수 없다.
    @objc func changeReaderFont(_ sender: Any?) {
        guard let popup = sender as? NSPopUpButton,
              let raw = popup.selectedItem?.representedObject as? String,
              let font = SettingsManager.ReadingFont(rawValue: raw) else { return }
        SettingsManager.shared.readingFont = font
        readerVC?.setFont(font)
        editorVC.refreshReadingLayout()
    }

    @objc func changeReaderWeight(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        let weights = SettingsManager.ReadingWeight.allCases
        let w = weights[min(max(seg.selectedSegment, 0), weights.count - 1)]
        SettingsManager.shared.readingWeight = w
        readerVC?.setWeight(w)
        editorVC.refreshReadingLayout()
    }

    @objc func changeReaderLineSpacing(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        let values: [CGFloat] = [1.2, 1.5, 2.0]
        let v = values[min(max(seg.selectedSegment, 0), values.count - 1)]
        SettingsManager.shared.readingLineSpacing = v
        readerVC?.setLineSpacing(v)
        editorVC.refreshReadingLayout()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        let sels: [Selector] = [
            #selector(changeReaderPageMode(_:)),
            #selector(changeReaderWidth(_:)),
            #selector(decreaseReaderFont(_:)), #selector(increaseReaderFont(_:)),
            #selector(changeReaderFont(_:)), #selector(changeReaderWeight(_:)),
            #selector(changeReaderLineSpacing(_:))
        ]
        if sels.contains(aSelector) { return true }
        return super.responds(to: aSelector)
    }

    // MARK: - Sidebar Selection Sync

    func updateSidebarSelection() {
        let url = (document as? NSDocument)?.fileURL
        sidebarVC?.setCurrentFileURL(url)
    }

    // MARK: - External Change Detection

    @objc private func handleExternalContentsChange() {
        guard let doc = document as? MarkdownDocument,
              let url = doc.fileURL else { return }

        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            lastNotifiedMissingURL = nil
            // 외부(다른 앱·에이전트)가 파일을 고쳐 쓴 경우 — 미저장 편집이 없으면
            // 조용히 다시 읽는다. 리로드되면 .documentDidReloadFromDisk 로 뷰가 따라온다.
            doc.reloadFromDiskIfClean()
            return
        }
        // 동일 URL에 대해 중복 알림 방지
        if lastNotifiedMissingURL == url { return }
        lastNotifiedMissingURL = url
        presentMissingFileAlert(for: doc, url: url)
    }

    private func presentMissingFileAlert(for doc: NSDocument, url: URL) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("external.deleted.title")
        alert.informativeText = url.lastPathComponent
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("external.deleted.saveAs"))
        alert.addButton(withTitle: L10n.tr("external.deleted.close"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                doc.saveAs(nil)
            }
            // 사용자가 닫기를 선택해도 작업 보존 — 자동으로 close하지 않음
        }
    }

    /// 문서가 디스크에서 다시 읽힌 뒤(수동 되돌리기·외부 변경 자동 리로드)
    /// 현재 모드에 맞는 화면과 글자수를 새 content 로 맞춘다.
    @objc private func handleDocumentReloadedFromDisk(_ note: Notification) {
        guard let doc = document as? MarkdownDocument,
              (note.object as? MarkdownDocument) === doc else { return }
        if readerVC != nil {
            // 같은 문서의 리로드이므로 읽던 페이지는 유지한다(범위 밖이면 클램프).
            readerVC?.updateContent(doc.content, resetPage: false)
        } else {
            editorVC.loadDocumentContent()
        }
        updateCharCount(for: doc.content.string)
        refreshSourcePreview()
    }
}

// MARK: - File Open from Sidebar (ADR-0004)

extension EditorWindowController: SidebarFileOpener {

    func openFileFromSidebar(at url: URL, jumpingTo jump: SearchJump? = nil) {
        guard let currentDoc = document as? MarkdownDocument else {
            // 현재 창에 문서가 없는 비정상 상태 — 그냥 새로 열기
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            return
        }

        // 같은 파일 클릭: 스왑 없이 점프만 (일반 클릭이면 무시 — 기존 동작 유지)
        if let currentURL = currentDoc.fileURL?.standardizedFileURL,
           currentURL == url.standardizedFileURL {
            if let jump = jump {
                jumpToMatch(jump)
            }
            return
        }

        // 이미 다른 창에 열려 있으면 그 창으로 이동 (점프는 생략 — 허용 가능한 엣지)
        if let existingDoc = NSDocumentController.shared.document(for: url),
           existingDoc !== currentDoc {
            existingDoc.showWindows()
            return
        }

        pendingSearchJump = jump

        // 미저장 변경 시 저장 확인
        currentDoc.canClose(withDelegate: self,
                            shouldClose: #selector(document(_:shouldClose:contextInfo:)),
                            contextInfo: bridgeURL(url))
    }

    private func bridgeURL(_ url: URL) -> UnsafeMutableRawPointer {
        // URL을 Unmanaged로 안전하게 전달
        return UnsafeMutableRawPointer(Unmanaged.passRetained(url as NSURL).toOpaque())
    }

    private func unbridgeURL(_ ptr: UnsafeMutableRawPointer) -> URL {
        let nsurl = Unmanaged<NSURL>.fromOpaque(ptr).takeRetainedValue()
        return nsurl as URL
    }

    @objc func document(_ doc: NSDocument,
                        shouldClose: Bool,
                        contextInfo: UnsafeMutableRawPointer?) {
        guard let ptr = contextInfo else { return }
        let targetURL = unbridgeURL(ptr)

        if !shouldClose {
            // 사용자 "취소" — 사이드바 선택 복원
            pendingSearchJump = nil
            updateSidebarSelection()
            return
        }

        swapDocument(to: targetURL, replacing: doc as? MarkdownDocument)
    }

    private func swapDocument(to url: URL, replacing oldDoc: MarkdownDocument?) {
        // 문서가 바뀌기 전에 저장 — 콜백 안에서는 self.document 가 이미 새 문서라
        // 이전 문서의 위치가 새 문서 키에 얹히게 된다.
        positionProvider?.flushPositionChange()
        swapCounter += 1
        let request = (id: swapCounter, url: url.standardizedFileURL)
        pendingSwap = request
        documentOpener(url) { [weak self] newDoc, alreadyOpen, error in
            guard let self = self else { return }
            // 클라우드 드라이브에서 읽는 사이 다른 파일을 눌렀다면 이 결과는 버린다.
            // 늦게 도착한 문서를 그대로 붙이면 창 하나가 두 문서에 매달리고, 이미 닫은
            // 이전 문서를 다시 닫게 된다. 최신 요청이 같은 파일이면 그쪽이 이 문서를 받는다.
            guard self.pendingSwap?.id == request.id else {
                if let newDoc, !alreadyOpen, newDoc.windowControllers.isEmpty,
                   newDoc.fileURL?.standardizedFileURL != self.pendingSwap?.url {
                    newDoc.close()
                }
                return
            }
            self.pendingSwap = nil
            guard error == nil, let newDoc = newDoc else {
                self.pendingSearchJump = nil
                self.updateSidebarSelection()
                if let error, (error as NSError).code != NSUserCancelledError { self.presentOpenFailure(error, url: url) }
                return
            }

            if alreadyOpen && !newDoc.windowControllers.isEmpty {
                newDoc.showWindows()
                self.updateSidebarSelection()
                return
            }

            // 기존 윈도우 컨트롤러를 신규 문서로 이관. 닫을 대상은 지금 이 창이 보여주는 문서다.
            let shown = self.document as? MarkdownDocument
            if let current = shown ?? oldDoc, current !== newDoc {
                current.removeWindowController(self)
                // 변경 카운트를 초기화하지 않으면 close 시 또 시트가 뜸 — canClose 이후이므로 이미 통과 상태
                current.close()
            }
            newDoc.addWindowController(self)

            self.editorVC.loadDocumentContent()
            if let jump = self.pendingSearchJump {
                self.pendingSearchJump = nil
                self.jumpToMatch(jump)
            }
            // 읽기 모드 중 사이드바로 문서를 바꿨다면 읽기 화면 내용도 새 문서로 갱신.
            // (에디터 뷰는 윈도우에서 분리돼 있어 loadDocumentContent 가 조용히
            //  건너뛰므로, 글자수도 여기서 직접 새 문서 기준으로 맞춘다.)
            if let newDoc = self.document as? MarkdownDocument {
                self.updateCharCount(for: newDoc.content.string)
            }
            self.window?.makeKeyAndOrderFront(nil)
            self.synchronizeWindowTitleWithDocumentName()
            self.updateSidebarSelection()
        }
    }
}

extension EditorWindowController {
    /// 사이드바에서 연 파일을 읽지 못했을 때(클라우드 내려받기 실패·인코딩 오류 등) 알린다.
    func presentOpenFailure(_ error: Error, url: URL) {
        let alert = NSAlert(error: error)
        alert.messageText = String(format: L10n.tr("open.failed"), url.lastPathComponent)
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

// MARK: - Menu Validation

extension EditorWindowController: NSMenuItemValidation {

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(proofreadSelection(_:)):
            return canProofreadSelection
        case #selector(manageEndnotes(_:)):
            guard let doc = document as? MarkdownDocument else { return false }
            return !isShowingSource && doc.fileType != "public.plain-text" && doc.fileURL?.pathExtension.lowercased() != "txt"
        case #selector(showMarkdownSource(_:)):
            menuItem.state = isShowingSource ? .on : .off
            return document is MarkdownDocument
        case #selector(toggleBookmark(_:)), #selector(showBookmarkList(_:)):
            // 책갈피 위치를 매어 둘 파일이 필요하다(저장 안 된 새 문서 제외).
            return !isShowingSource && (document as? MarkdownDocument)?.fileURL != nil
        default:
            return true
        }
    }
}
