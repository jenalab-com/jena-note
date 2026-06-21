import AppKit

// MARK: - File-Open Protocol (loose coupling)

/// 사이드바가 윈도우 컨트롤러에 "이 파일을 열어라"고 요청할 때 사용한다.
@objc protocol SidebarFileOpener: AnyObject {
    func openFileFromSidebar(at url: URL)
}

// MARK: - Tree Node

final class SidebarNode {
    let url: URL
    let isDirectory: Bool
    let isRoot: Bool          // 사용자가 등록한 최상위 폴더
    var isMissing: Bool       // 디스크에서 접근 불가
    var children: [SidebarNode]?

    init(url: URL, isDirectory: Bool, isRoot: Bool, isMissing: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.isRoot = isRoot
        self.isMissing = isMissing
    }
}

// MARK: - SidebarViewController

final class SidebarViewController: NSViewController {

    // MARK: Properties

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var headerView: NSView!
    private var emptyStateView: NSView!
    private var addButton: NSButton!

    private var roots: [SidebarNode] = []
    /// 펼침 상태 보존용 (URL 경로 기준)
    private var expandedPaths: Set<String> = []

    private let store = FolderBookmarksStore.shared
    private let watcher = FolderWatcher.shared

    // 사이드바에서 연 파일 (강조 표시용)
    var currentFileURL: URL?

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        container.wantsLayer = true

        setupHeader(in: container)
        setupOutline(in: container)
        setupEmptyState(in: container)

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBookmarksChange),
            name: .folderBookmarksDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleContentsChange),
            name: .folderContentsDidChange, object: nil
        )

        reloadTree()
        startWatching()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupHeader(in container: NSView) {
        headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerView)

        let title = NSTextField(labelWithString: L10n.tr("sidebar.title"))
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = NSColor.secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(title)

        addButton = NSButton(frame: .zero)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.tr("sidebar.add.tooltip"))
        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.target = self
        addButton.action = #selector(showAddFolderPanel(_:))
        addButton.toolTip = L10n.tr("sidebar.add.tooltip")
        addButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(addButton)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: container.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 32),

            title.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            addButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 22),
            addButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    private func setupOutline(in container: NSView) {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 14
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.usesAutomaticRowHeights = false
        outlineView.rowHeight = 22
        outlineView.target = self
        outlineView.action = #selector(outlineRowClicked(_:))
        outlineView.menu = makeContextMenu()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func setupEmptyState(in container: NSView) {
        emptyStateView = NSView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyStateView)

        let message = NSTextField(labelWithString: L10n.tr("sidebar.empty.message"))
        message.font = NSFont.systemFont(ofSize: 12)
        message.textColor = NSColor.secondaryLabelColor
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        message.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(message)

        let button = NSButton(title: L10n.tr("sidebar.empty.button"), target: self, action: #selector(showAddFolderPanel(_:)))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(button)

        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            emptyStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            emptyStateView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            message.topAnchor.constraint(equalTo: emptyStateView.topAnchor, constant: 60),
            message.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor),

            button.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 12),
            button.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor)
        ])

        emptyStateView.isHidden = true
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: L10n.tr("sidebar.context.remove"),
                     action: #selector(contextRemoveFolder(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr("sidebar.context.reveal"),
                     action: #selector(contextRevealInFinder(_:)),
                     keyEquivalent: "")
        return menu
    }

    // MARK: - Tree Construction

    private func reloadTree() {
        captureExpansionState()

        roots = store.folders.map { url -> SidebarNode in
            let accessible = store.isAccessible(url)
            let node = SidebarNode(url: url, isDirectory: true, isRoot: true, isMissing: !accessible)
            if accessible {
                node.children = scanDirectory(url)
            } else {
                node.children = []
            }
            return node
        }

        outlineView.reloadData()
        restoreExpansionState()
        updateEmptyState()
        highlightCurrentFile()
    }

    private func scanDirectory(_ url: URL) -> [SidebarNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else { return [] }
        var subdirs: [SidebarNode] = []
        var files: [SidebarNode] = []

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                // 안에 .md가 하나라도 있으면 표시
                let children = scanDirectory(entry)
                if !children.isEmpty {
                    let node = SidebarNode(url: entry, isDirectory: true, isRoot: false)
                    node.children = children
                    subdirs.append(node)
                }
            } else if entry.pathExtension.lowercased() == "md" {
                files.append(SidebarNode(url: entry, isDirectory: false, isRoot: false))
            }
        }

        subdirs.sort { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
        files.sort { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
        return subdirs + files
    }

    private func captureExpansionState() {
        expandedPaths.removeAll()
        for row in 0..<outlineView.numberOfRows {
            if outlineView.isItemExpanded(outlineView.item(atRow: row)),
               let node = outlineView.item(atRow: row) as? SidebarNode {
                expandedPaths.insert(node.url.path)
            }
        }
    }

    private func restoreExpansionState() {
        // 새로 등록된 루트는 기본적으로 펼친다
        var toExpand: [SidebarNode] = []
        for root in roots {
            if expandedPaths.contains(root.url.path) || expandedPaths.isEmpty {
                toExpand.append(root)
            }
        }
        for node in toExpand {
            outlineView.expandItem(node)
        }
        // 깊은 노드 펼침 복원
        expandAllMatching(from: roots)
    }

    private func expandAllMatching(from nodes: [SidebarNode]) {
        for node in nodes {
            if expandedPaths.contains(node.url.path) {
                outlineView.expandItem(node)
            }
            if let children = node.children {
                expandAllMatching(from: children)
            }
        }
    }

    private func updateEmptyState() {
        let isEmpty = roots.isEmpty
        emptyStateView.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    private func highlightCurrentFile() {
        guard let url = currentFileURL else {
            outlineView.deselectAll(nil)
            return
        }
        if let row = findRow(forURL: url) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    private func findRow(forURL url: URL) -> Int? {
        let target = url.standardizedFileURL.path
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? SidebarNode,
               node.url.standardizedFileURL.path == target {
                return row
            }
        }
        return nil
    }

    // MARK: - Watching

    private func startWatching() {
        let paths = store.folders.map { $0.path }
        watcher.restart(with: paths)
    }

    // MARK: - Notifications

    @objc private func handleBookmarksChange() {
        startWatching()
        reloadTree()
    }

    @objc private func handleContentsChange() {
        reloadTree()
    }

    // MARK: - Actions

    @objc func showAddFolderPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L10n.tr("sidebar.openPanel.title")
        panel.prompt = L10n.tr("sidebar.openPanel.prompt")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.store.addFolder(url)
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            let response = panel.runModal()
            completion(response)
        }
    }

    @objc private func outlineRowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode else { return }

        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
            return
        }

        // 파일 클릭 → 윈도우 컨트롤러에 위임
        if let opener = view.window?.windowController as? SidebarFileOpener {
            opener.openFileFromSidebar(at: node.url)
        }
    }

    @objc private func contextRemoveFolder(_ sender: Any?) {
        guard let node = clickedNode(), node.isRoot else { return }
        store.removeFolder(node.url)
    }

    @objc private func contextRevealInFinder(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    private func clickedNode() -> SidebarNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SidebarNode
    }

    // MARK: - Public API

    func setCurrentFileURL(_ url: URL?) {
        currentFileURL = url
        highlightCurrentFile()
    }
}

// MARK: - DataSource

extension SidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return roots.count }
        guard let node = item as? SidebarNode else { return 0 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return roots[index] }
        guard let node = item as? SidebarNode, let children = node.children else { return SidebarNode(url: URL(fileURLWithPath: "/"), isDirectory: false, isRoot: false) }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return node.isDirectory && !(node.children?.isEmpty ?? true)
    }
}

// MARK: - Delegate

extension SidebarViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell: NSTableCellView = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = displayName(for: node)
        cell.imageView?.image = icon(for: node)
        cell.textField?.textColor = node.isMissing ? NSColor.systemOrange : NSColor.labelColor
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // 강조만 — 실제 파일 열기는 click action에서 처리 (키보드 네비게이션 시 의도 없는 swap 방지)
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = imageView
        cell.addSubview(imageView)

        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = textField
        cell.addSubview(textField)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func displayName(for node: SidebarNode) -> String {
        var name = node.url.lastPathComponent
        if node.isRoot && node.isMissing {
            name += " — " + L10n.tr("sidebar.missing")
        }
        return name
    }

    private func icon(for node: SidebarNode) -> NSImage? {
        if node.isMissing {
            return NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
        if node.isDirectory {
            return NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        }
        return NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
    }
}

// MARK: - Menu Delegate

extension SidebarViewController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = outlineView.clickedRow
        let node = (row >= 0) ? outlineView.item(atRow: row) as? SidebarNode : nil

        for item in menu.items {
            switch item.action {
            case #selector(contextRemoveFolder(_:)):
                item.isHidden = !(node?.isRoot == true)
            case #selector(contextRevealInFinder(_:)):
                item.isHidden = (node == nil)
            default:
                break
            }
        }
    }
}
