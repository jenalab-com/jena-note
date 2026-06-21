import AppKit

class EditorWindowController: NSWindowController {

    // MARK: - Children

    private(set) var sidebarVC: SidebarViewController!
    private(set) var editorVC: EditorViewController!
    private var splitVC: NSSplitViewController!
    private var lastNotifiedMissingURL: URL?

    // MARK: - Reading Mode State (ADR-0006)

    private(set) var isReadingMode = false
    private var readerVC: ReaderViewController?
    private var formatToolbar: FormatToolbar?
    private var readerToolbar: ReaderToolbar?

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

        window.contentViewController = split

        self.sidebarVC = sidebar
        self.editorVC = editor
        self.splitVC = split

        setupToolbar(for: window)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleExternalContentsChange),
            name: .folderContentsDidChange, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Toolbar

    private func setupToolbar(for window: NSWindow) {
        let toolbar = FormatToolbar(identifier: NSToolbar.Identifier("FormatToolbar"))
        toolbar.target = editorVC
        window.toolbar = toolbar
        formatToolbar = toolbar
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
            super.document = newValue
            updateSidebarSelection()
        }
    }

    // MARK: - Window Title

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        if document == nil {
            window?.title = L10n.tr("untitled")
        }
    }

    // MARK: - Sidebar Toggle

    @objc func toggleSidebar(_ sender: Any?) {
        splitVC.toggleSidebar(sender)
    }

    // MARK: - Reading Mode (ADR-0006)

    @objc func toggleReadingMode(_ sender: Any?) {
        isReadingMode ? exitReadingMode(sender) : enterReadingMode(sender)
    }

    @objc func enterReadingMode(_ sender: Any?) {
        guard !isReadingMode, let doc = document as? MarkdownDocument else { return }
        // 라이브 텍스트 스토리지의 스냅샷을 직접 전달 — 읽기 화면이 최신 미저장
        // 편집본을 조판하되, 문서의 change count 는 건드리지 않는다 (원본 불변).
        let liveContent = editorVC.textView.textStorage.map { NSAttributedString(attributedString: $0) } ?? doc.content
        let reader = ReaderViewController(content: liveContent)
        readerVC = reader
        swapRightPane(to: reader)

        let rToolbar = ReaderToolbar(identifier: NSToolbar.Identifier("ReaderToolbar"))
        rToolbar.target = self
        window?.toolbar = rToolbar
        readerToolbar = rToolbar

        isReadingMode = true

        // 영속화된 page mode 적용은 ReaderViewController.viewDidAppear 로 위임한다.
        // 레이아웃이 끝난(non-zero bounds) AppKit 순서 지점에서 호출돼야
        // pageHeight 가 0-bounds 로 계산되지 않고, scroll→paged 깜빡임도 없다.
    }

    @objc func exitReadingMode(_ sender: Any?) {
        guard isReadingMode else { return }
        swapRightPane(to: editorVC)
        if let f = formatToolbar {
            window?.toolbar = f
        } else if let window = window {
            setupToolbar(for: window)
        }
        editorVC.loadDocumentContent()
        readerVC = nil
        readerToolbar = nil
        isReadingMode = false
    }

    private func swapRightPane(to vc: NSViewController) {
        guard let split = window?.contentViewController as? NSSplitViewController else { return }
        // 우측(인덱스 1) item 교체. 좌측 사이드바는 유지.
        if split.splitViewItems.count > 1 {
            split.removeSplitViewItem(split.splitViewItems[1])
        }
        let item = NSSplitViewItem(viewController: vc)
        item.minimumThickness = 360
        split.addSplitViewItem(item)
    }

    // MARK: - Reader Toolbar Actions

    @objc func changeReaderPageMode(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        let mode: SettingsManager.ReadingPageMode = (seg.selectedSegment == 1) ? .paged : .scroll
        readerVC?.setPageMode(mode)
    }

    @objc func decreaseReaderFont(_ sender: Any?) {
        let cur = SettingsManager.shared.readingFontScale
        readerVC?.setFontScale(cur - 0.1)
    }

    @objc func increaseReaderFont(_ sender: Any?) {
        let cur = SettingsManager.shared.readingFontScale
        readerVC?.setFontScale(cur + 0.1)
    }

    @objc func changeReaderFont(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        let font: SettingsManager.ReadingFont = (seg.selectedSegment == 1) ? .sans : .serif
        readerVC?.setFont(font)
    }

    @objc func changeReaderLineSpacing(_ sender: Any?) {
        guard let seg = sender as? NSSegmentedControl else { return }
        let values: [CGFloat] = [1.2, 1.5, 2.0]
        let v = values[min(max(seg.selectedSegment, 0), values.count - 1)]
        readerVC?.setLineSpacing(v)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        let sels: [Selector] = [
            #selector(toggleReadingMode(_:)), #selector(enterReadingMode(_:)),
            #selector(exitReadingMode(_:)), #selector(changeReaderPageMode(_:)),
            #selector(decreaseReaderFont(_:)), #selector(increaseReaderFont(_:)),
            #selector(changeReaderFont(_:)), #selector(changeReaderLineSpacing(_:))
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
        guard let doc = document as? NSDocument,
              let url = doc.fileURL else { return }

        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            lastNotifiedMissingURL = nil
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
}

// MARK: - File Open from Sidebar (ADR-0004)

extension EditorWindowController: SidebarFileOpener {

    func openFileFromSidebar(at url: URL) {
        guard let currentDoc = document as? MarkdownDocument else {
            // 현재 창에 문서가 없는 비정상 상태 — 그냥 새로 열기
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            return
        }

        // 같은 파일 재클릭은 무시
        if let currentURL = currentDoc.fileURL?.standardizedFileURL,
           currentURL == url.standardizedFileURL {
            return
        }

        // 이미 다른 창에 열려 있으면 그 창으로 이동
        if let existingDoc = NSDocumentController.shared.document(for: url),
           existingDoc !== currentDoc {
            existingDoc.showWindows()
            return
        }

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
            updateSidebarSelection()
            return
        }

        swapDocument(to: targetURL, replacing: doc as? MarkdownDocument)
    }

    private func swapDocument(to url: URL, replacing oldDoc: MarkdownDocument?) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { [weak self] newDoc, alreadyOpen, error in
            guard let self = self else { return }
            guard error == nil, let newDoc = newDoc else { return }

            if alreadyOpen {
                newDoc.showWindows()
                return
            }

            // 기존 윈도우 컨트롤러를 신규 문서로 이관
            if let oldDoc = oldDoc {
                oldDoc.removeWindowController(self)
                // 변경 카운트를 초기화하지 않으면 close 시 또 시트가 뜸 — canClose 이후이므로 이미 통과 상태
                oldDoc.close()
            }
            newDoc.addWindowController(self)

            self.editorVC.loadDocumentContent()
            // 읽기 모드 중 사이드바로 문서를 바꿨다면 읽기 화면 내용도 새 문서로 갱신.
            if self.isReadingMode, let newDoc = self.document as? MarkdownDocument {
                self.readerVC?.updateContent(newDoc.content)
            }
            self.window?.makeKeyAndOrderFront(nil)
            self.synchronizeWindowTitleWithDocumentName()
            self.updateSidebarSelection()
        }
    }
}
