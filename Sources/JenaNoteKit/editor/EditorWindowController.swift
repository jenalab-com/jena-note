import AppKit

class EditorWindowController: NSWindowController {

    // MARK: - Children

    private(set) var sidebarVC: SidebarViewController!
    private(set) var editorVC: EditorViewController!
    private var splitVC: NSSplitViewController!
    private var lastNotifiedMissingURL: URL?

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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
            self.window?.makeKeyAndOrderFront(nil)
            self.synchronizeWindowTitleWithDocumentName()
            self.updateSidebarSelection()
        }
    }
}
