import AppKit

// MARK: - File-Open Protocol (loose coupling)

/// 검색 결과 클릭 시 문서 안에서 이동할 위치 — 검색어의 파일 내 n번째 occurrence.
struct SearchJump {
    let query: String
    let ordinal: Int
}

/// 사이드바가 윈도우 컨트롤러에 "이 파일을 열어라"고 요청할 때 사용한다.
protocol SidebarFileOpener: AnyObject {
    func openFileFromSidebar(at url: URL, jumpingTo jump: SearchJump?)
}

/// 사이드바에서 인식하는 이미지 파일 확장자.
let sidebarImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]

// MARK: - Tree Node

final class SidebarNode {
    let url: URL
    let isDirectory: Bool
    let isRoot: Bool          // 사용자가 등록한 최상위 폴더
    var isMissing: Bool       // 디스크에서 접근 불가
    var modificationDate: Date // 날짜순 정렬용 수정일
    var children: [SidebarNode]?

    init(url: URL, isDirectory: Bool, isRoot: Bool, isMissing: Bool = false, modificationDate: Date = .distantPast) {
        self.url = url
        self.isDirectory = isDirectory
        self.isRoot = isRoot
        self.isMissing = isMissing
        self.modificationDate = modificationDate
    }
}

/// 검색 결과 모드에서 목록 맨 위에 표시하는 안내 행 (결과 없음 / 일부만 표시).
final class SearchNotice {
    let text: String
    init(_ text: String) { self.text = text }
}

// MARK: - SidebarViewController

final class SidebarViewController: NSViewController {

    // MARK: Properties

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var headerView: NSView!
    private var headerTopConstraint: NSLayoutConstraint?
    private var emptyStateView: NSView!
    private var addButton: NSButton!
    private var sortButton: NSButton!
    private var sectionView: NSView!
    private var sectionLabel: NSTextField!
    private var pendingRowClick: DispatchWorkItem?
    private var contextNode: SidebarNode?
    private var newDocumentButton: NSButton!
    private var newFolderButton: NSButton!

    private var roots: [SidebarNode] = []
    /// 펼침 상태 보존용 (URL 경로 기준)
    private var expandedPaths: Set<String> = []

    private let store = FolderBookmarksStore.shared
    private let watcher = FolderWatcher.shared

    // MARK: 전체 검색 상태
    private var searchField: NSSearchField!
    private var searchSpinner: NSProgressIndicator!
    private let fileSearcher = FileSearcher()
    private var searchDebounce: DispatchWorkItem?
    /// nil = 트리 모드, non-nil = 검색 결과 모드
    private var searchResults: [FileSearchResult]?
    private var searchNotice: SearchNotice?
    private var isSearching: Bool { searchResults != nil }
    /// 현재 표시 중인 결과가 계산된 검색어 — 클릭 점프의 ordinal이 이 검색어 기준이라,
    /// 디바운스 중 필드 텍스트가 바뀌어도 클릭은 이 값을 써야 ordinal이 어긋나지 않는다.
    private var lastSearchQuery = ""

    // 사이드바에서 연 파일 (강조 표시용)
    var currentFileURL: URL?

    // MARK: - View Lifecycle

    override func loadView() {
        let container = SidebarBackgroundView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))

        setupHeader(in: container)
        setupSearchField(in: container)
        setupSection(in: container)
        setupOutline(in: container)
        setupEmptyState(in: container)

        view = container
        updateCreationButtons()
        updateSectionLabel()
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

    /// 상단 브랜드 헤더 — 블랙 로고 마크 + 앱 이름 + 폴더 등록(원형 +) 버튼.
    private func setupHeader(in container: NSView) {
        headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerView)

        let logo = SidebarLogoView()
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.setAccessibilityElement(false)
        headerView.addSubview(logo)

        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "JenaNote"
        let title = NSTextField(labelWithString: appName)
        title.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        title.textColor = SidebarStyle.text
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(title)

        addButton = SidebarIconButton(symbol: "plus", tooltip: L10n.tr("sidebar.add.tooltip"),
                                      target: self, action: #selector(showAddFolderPanel(_:)))
        (addButton as? SidebarIconButton)?.circled = true
        headerView.addSubview(addButton)

        let hairline = SidebarHairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(hairline)

        let top = headerView.topAnchor.constraint(equalTo: container.topAnchor)
        headerTopConstraint = top
        NSLayoutConstraint.activate([
            top,
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 56),

            logo.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            logo.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 26),
            logo.heightAnchor.constraint(equalToConstant: 26),

            title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -8),

            addButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),
            addButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),

            hairline.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            hairline.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            hairline.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func setupSearchField(in container: NSView) {
        searchField = NSSearchField()
        searchField.placeholderString = L10n.tr("sidebar.search.placeholder")
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.controlSize = .large
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        ])
    }

    /// 섹션 머리 — "폴더 3" 라벨 + 오른쪽 도구(검색 진행, 정렬, 새 문서, 새 폴더).
    private func setupSection(in container: NSView) {
        sectionView = NSView()
        sectionView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sectionView)

        sectionLabel = NSTextField(labelWithString: "")
        sectionLabel.lineBreakMode = .byTruncatingTail
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        sectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sectionView.addSubview(sectionLabel)

        newFolderButton = SidebarIconButton(symbol: "folder.badge.plus", tooltip: L10n.tr("sidebar.create.folder"),
                                            target: self, action: #selector(createFolder(_:)))
        newDocumentButton = SidebarIconButton(symbol: "square.and.pencil", tooltip: L10n.tr("sidebar.create.document"),
                                              target: self, action: #selector(createDocument(_:)))
        sortButton = SidebarIconButton(symbol: "arrow.up.arrow.down", tooltip: L10n.tr("sidebar.sort.tooltip"),
                                       target: self, action: #selector(showSortMenu(_:)))

        searchSpinner = NSProgressIndicator()
        searchSpinner.style = .spinning
        searchSpinner.controlSize = .small
        searchSpinner.isDisplayedWhenStopped = false
        searchSpinner.translatesAutoresizingMaskIntoConstraints = false

        for view in [newFolderButton!, newDocumentButton!, sortButton!, searchSpinner!] as [NSView] {
            sectionView.addSubview(view)
        }

        var constraints: [NSLayoutConstraint] = [
            sectionView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 16),
            sectionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sectionView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sectionView.heightAnchor.constraint(equalToConstant: 24),

            sectionLabel.leadingAnchor.constraint(equalTo: sectionView.leadingAnchor, constant: 20),
            sectionLabel.centerYAnchor.constraint(equalTo: sectionView.centerYAnchor),
            sectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: searchSpinner.leadingAnchor, constant: -6),

            searchSpinner.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -4),
            searchSpinner.centerYAnchor.constraint(equalTo: sectionView.centerYAnchor),
            searchSpinner.widthAnchor.constraint(equalToConstant: 14),
            searchSpinner.heightAnchor.constraint(equalToConstant: 14)
        ]
        var trailing = sectionView.trailingAnchor
        var gap: CGFloat = -14
        for button in [newFolderButton!, newDocumentButton!, sortButton!] {
            constraints += [
                button.trailingAnchor.constraint(equalTo: trailing, constant: gap),
                button.centerYAnchor.constraint(equalTo: sectionView.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24)
            ]
            trailing = button.leadingAnchor
            gap = -2
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// 섹션 라벨: "폴더" + 등록된 최상위 폴더 수.
    private func updateSectionLabel() {
        guard let sectionLabel = sectionLabel else { return }
        let name = L10n.tr("sidebar.title")
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: SidebarStyle.secondaryText
        ])
        let count = store.folders.count
        if count > 0 {
            text.append(NSAttributedString(string: "  \(count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]))
        }
        sectionLabel.attributedStringValue = text
    }

    private func setupOutline(in container: NSView) {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let tree = SidebarOutlineView()
        tree.configureSidebarAppearance()
        outlineView = tree
        outlineView.target = self
        outlineView.action = #selector(outlineRowClicked(_:))
        outlineView.doubleAction = #selector(renameDoubleClicked(_:))
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
            scrollView.topAnchor.constraint(equalTo: sectionView.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func setupEmptyState(in container: NSView) {
        emptyStateView = NSView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyStateView)

        let icon = NSImageView()
        icon.image = SidebarStyle.symbol("folder", size: 26, weight: .light)
        icon.contentTintColor = NSColor.tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(icon)

        let message = NSTextField(labelWithString: L10n.tr("sidebar.empty.message"))
        message.font = NSFont.systemFont(ofSize: 12)
        message.textColor = SidebarStyle.secondaryText
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        message.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(message)

        let button = SidebarPillButton(title: L10n.tr("sidebar.empty.button"),
                                       target: self, action: #selector(showAddFolderPanel(_:)))
        emptyStateView.addSubview(button)

        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: sectionView.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            emptyStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            emptyStateView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            icon.topAnchor.constraint(equalTo: emptyStateView.topAnchor, constant: 48),
            icon.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),

            message.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            message.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor),

            button.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 14),
            button.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor)
        ])

        emptyStateView.isHidden = true
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for (key, action) in [
            ("sidebar.action.rename", #selector(contextRename(_:))),
            ("sidebar.action.delete", #selector(contextDelete(_:))),
            ("menu.file.new", #selector(contextCreateDocument(_:))),
            ("sidebar.action.newFolder", #selector(contextCreateFolder(_:)))
        ] {
            let item = menu.addItem(withTitle: L10n.tr(key), action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(withTitle: L10n.tr("sidebar.context.remove"),
                     action: #selector(contextRemoveFolder(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr("sidebar.context.reveal"),
                     action: #selector(contextRevealInFinder(_:)),
                     keyEquivalent: "")
        return menu
    }

    // MARK: - Tree Construction

    private func reloadTree(capture: Bool = true) {
        // 검색 결과 모드에서는 트리 UI를 건드리지 않는다 — FSEvents 갱신은
        // 검색 종료(exitSearch) 시 reloadTree가 최신 상태로 재구성한다.
        if isSearching { return }
        // exitSearch 경로(capture: false)에서는 현재 행이 방금까지 검색 행이었어
        // captureExpansionState가 펼침 상태를 지워버린다 — 진입 시 찍어둔 스냅샷을 그대로 쓴다.
        if capture { captureExpansionState() }
        // reloadData()는 스크롤을 맨 위로 되돌리므로, 보던 위치를 저장했다가 복원한다
        // (외부 파일 변경으로 갱신될 때 스크롤이 튀지 않도록).
        let selectedURL = outlineView.selectedRow >= 0
            ? (outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode)?.url : nil
        let savedOrigin = scrollView.contentView.bounds.origin

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
        if let selectedURL = selectedURL, let row = findRow(forURL: selectedURL) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            highlightCurrentFile()
        }
        updateCreationButtons()
        updateSectionLabel()

        scrollView.contentView.scroll(to: savedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scanDirectory(_ url: URL) -> [SidebarNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: url,
                                                       includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles]) else { return [] }
        var subdirs: [SidebarNode] = []
        var files: [SidebarNode] = []

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let modDate = values?.contentModificationDate ?? .distantPast
            if isDir {
                let node = SidebarNode(url: entry, isDirectory: true, isRoot: false, modificationDate: modDate)
                node.children = scanDirectory(entry)
                subdirs.append(node)
            } else if entry.pathExtension.lowercased() == "md" {
                files.append(SidebarNode(url: entry, isDirectory: false, isRoot: false, modificationDate: modDate))
            }
        }

        // 폴더 먼저, 파일 나중 — 각 그룹 안에서 설정대로 정렬
        sortNodes(&subdirs)
        sortNodes(&files)
        return subdirs + files
    }

    /// 현재 설정(기준·방향)에 따라 노드 배열을 제자리 정렬한다.
    private func sortNodes(_ nodes: inout [SidebarNode]) {
        let key = SettingsManager.shared.sidebarSortKey
        let ascending = SettingsManager.shared.sidebarSortOrder == .ascending

        nodes.sort { a, b in
            let order: ComparisonResult
            switch key {
            case .name:
                order = a.url.lastPathComponent.localizedCaseInsensitiveCompare(b.url.lastPathComponent)
            case .date:
                if a.modificationDate == b.modificationDate {
                    order = .orderedSame
                } else {
                    order = a.modificationDate < b.modificationDate ? .orderedAscending : .orderedDescending
                }
            }
            switch order {
            case .orderedAscending:  return ascending
            case .orderedDescending: return !ascending
            case .orderedSame:
                // 동률이면 이름 오름차순으로 안정적 정렬
                return a.url.lastPathComponent.localizedCaseInsensitiveCompare(b.url.lastPathComponent) == .orderedAscending
            }
        }
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
        let isEmpty = roots.isEmpty && !isSearching
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

    private var creationDirectory: URL? {
        guard let outline = outlineView, outline.selectedRow >= 0,
              let node = outline.item(atRow: outline.selectedRow) as? SidebarNode,
              !node.isMissing else { return nil }
        let url = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        return store.isAccessible(url) ? url : nil
    }

    private func updateCreationButtons() {
        let enabled = creationDirectory != nil
        newDocumentButton?.isEnabled = enabled
        newFolderButton?.isEnabled = enabled
    }

    @objc private func createDocument(_ sender: Any?) { showCreationSheet(isDirectory: false) }
    @objc private func createFolder(_ sender: Any?) { showCreationSheet(isDirectory: true) }

    private func showCreationSheet(isDirectory: Bool, parentURL: URL? = nil) {
        guard let parent = parentURL ?? creationDirectory, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr(isDirectory ? "sidebar.create.folder" : "sidebar.create.document")
        alert.informativeText = parent.path
        let name = NSTextField(string: L10n.tr(isDirectory ? "sidebar.create.folderName" : "sidebar.create.documentName"))
        name.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        name.setAccessibilityLabel(alert.messageText)
        alert.accessoryView = name
        alert.addButton(withTitle: L10n.tr("sidebar.create.confirm"))
        alert.addButton(withTitle: L10n.tr("confirm.cancel"))
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            do {
                let url = try SidebarItemCreation.create(named: name.stringValue, in: parent, isDirectory: isDirectory)
                self.searchField.stringValue = ""
                self.exitSearch()
                self.reloadTree()
                // 새 항목의 조상 폴더를 펼쳐 빈 폴더도 즉시 선택할 수 있게 한다.
                var row = 0
                while row < self.outlineView.numberOfRows {
                    if let node = self.outlineView.item(atRow: row) as? SidebarNode, node.isDirectory,
                       url.path.hasPrefix(node.url.path + "/") {
                        self.outlineView.expandItem(node)
                    }
                    row += 1
                }
                if let row = self.findRow(forURL: url) {
                    self.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.outlineView.scrollRowToVisible(row)
                }
                if !isDirectory, let opener = window.windowController as? SidebarFileOpener {
                    opener.openFileFromSidebar(at: url, jumpingTo: nil)
                }
            } catch {
                self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
        }
    }

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

    // MARK: Sort

    @objc private func showSortMenu(_ sender: NSButton) {
        let menu = makeSortMenu()
        let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    private func makeSortMenu() -> NSMenu {
        let settings = SettingsManager.shared
        let menu = NSMenu()

        let byName = NSMenuItem(title: L10n.tr("sidebar.sort.name"),
                                action: #selector(selectSortByName(_:)), keyEquivalent: "")
        byName.target = self
        byName.state = settings.sidebarSortKey == .name ? .on : .off
        menu.addItem(byName)

        let byDate = NSMenuItem(title: L10n.tr("sidebar.sort.date"),
                                action: #selector(selectSortByDate(_:)), keyEquivalent: "")
        byDate.target = self
        byDate.state = settings.sidebarSortKey == .date ? .on : .off
        menu.addItem(byDate)

        menu.addItem(.separator())

        let asc = NSMenuItem(title: L10n.tr("sidebar.sort.asc"),
                             action: #selector(selectSortAscending(_:)), keyEquivalent: "")
        asc.target = self
        asc.state = settings.sidebarSortOrder == .ascending ? .on : .off
        menu.addItem(asc)

        let desc = NSMenuItem(title: L10n.tr("sidebar.sort.desc"),
                              action: #selector(selectSortDescending(_:)), keyEquivalent: "")
        desc.target = self
        desc.state = settings.sidebarSortOrder == .descending ? .on : .off
        menu.addItem(desc)

        return menu
    }

    @objc private func selectSortByName(_ sender: Any?) { applySort(key: .name) }
    @objc private func selectSortByDate(_ sender: Any?) { applySort(key: .date) }
    @objc private func selectSortAscending(_ sender: Any?) { applySort(order: .ascending) }
    @objc private func selectSortDescending(_ sender: Any?) { applySort(order: .descending) }

    private func applySort(key: SettingsManager.SidebarSortKey? = nil,
                           order: SettingsManager.SidebarSortOrder? = nil) {
        let settings = SettingsManager.shared
        if let key = key { settings.sidebarSortKey = key }
        if let order = order { settings.sidebarSortOrder = order }
        reloadTree()
    }

    @objc private func outlineRowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        pendingRowClick?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.activateSidebarItem(item) }
        pendingRowClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    private func activateSidebarItem(_ item: Any?) {
        // 검색 결과 모드
        if item is SearchNotice { return }
        if let result = item as? FileSearchResult {
            if outlineView.isItemExpanded(result) {
                outlineView.collapseItem(result)
            } else {
                outlineView.expandItem(result)
            }
            return
        }
        if let hit = item as? FileSearchHit {
            guard let parent = outlineView.parent(forItem: hit) as? FileSearchResult,
                  let opener = view.window?.windowController as? SidebarFileOpener else { return }
            opener.openFileFromSidebar(at: parent.fileURL,
                                       jumpingTo: SearchJump(query: lastSearchQuery, ordinal: hit.ordinalInFile))
            return
        }

        // 트리 모드
        guard let node = item as? SidebarNode else { return }

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
            opener.openFileFromSidebar(at: node.url, jumpingTo: nil)
        }
    }

    @objc private func contextCreateDocument(_ sender: Any?) {
        guard let node = clickedNode(), node.isDirectory else { return }
        showCreationSheet(isDirectory: false, parentURL: node.url)
    }

    @objc private func contextCreateFolder(_ sender: Any?) {
        guard let node = clickedNode(), node.isDirectory else { return }
        showCreationSheet(isDirectory: true, parentURL: node.url)
    }

    @objc private func contextRename(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        showRenameSheet(node)
    }

    @objc private func renameDoubleClicked(_ sender: NSOutlineView) {
        pendingRowClick?.cancel()
        guard sender.clickedRow >= 0,
              let node = sender.item(atRow: sender.clickedRow) as? SidebarNode else { return }
        showRenameSheet(node)
    }

    private func showRenameSheet(_ node: SidebarNode) {
        guard !node.isMissing, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("sidebar.action.rename")
        alert.informativeText = node.url.path
        let name = NSTextField(string: node.url.lastPathComponent)
        name.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        name.setAccessibilityLabel(alert.messageText)
        alert.accessoryView = name
        alert.addButton(withTitle: L10n.tr("sidebar.action.rename"))
        alert.addButton(withTitle: L10n.tr("confirm.cancel"))
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            do {
                let destination = try SidebarItemOperations.rename(node.url, to: name.stringValue)
                for document in NSDocumentController.shared.documents {
                    guard let url = document.fileURL,
                          let moved = SidebarItemOperations.relocatedURL(url, from: node.url, to: destination) else { continue }
                    document.fileURL = moved
                    for controller in document.windowControllers {
                        controller.synchronizeWindowTitleWithDocumentName()
                        (controller as? EditorWindowController)?.updateSidebarSelection()
                    }
                }
                self.store.relocateFolders(from: node.url, to: destination)
                self.expandedPaths = Set(self.expandedPaths.map {
                    SidebarItemOperations.relocatedURL(URL(fileURLWithPath: $0), from: node.url, to: destination)?.path ?? $0
                })
                self.reloadTree(capture: false)
                self.selectCreatedOrRenamedItem(destination)
            } catch {
                self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
        }
    }

    private func selectCreatedOrRenamedItem(_ url: URL) {
        let outline = outlineView!
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? SidebarNode, node.url.standardizedFileURL == url.standardizedFileURL {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                break
            }
        }
    }

    @objc private func contextDelete(_ sender: Any?) {
        guard let node = clickedNode(), let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("sidebar.action.delete")
        alert.informativeText = node.url.path + "\n" + L10n.tr("sidebar.action.deleteInfo")
        alert.addButton(withTitle: L10n.tr("sidebar.action.delete"))
        alert.addButton(withTitle: L10n.tr("confirm.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let documents = NSDocumentController.shared.documents.filter {
                guard let url = $0.fileURL else { return false }
                return SidebarItemOperations.relocatedURL(url, from: node.url, to: node.url) != nil
            }
            let check = SidebarDocumentCloseCheck(documents: documents) { [weak self] allowed in
                guard allowed, let self = self else { return }
                do {
                    try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                    for document in documents { document.close() }
                    self.store.removeFolders(inside: node.url)
                    self.reloadTree()
                } catch {
                    self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
                }
            }
            check.start()
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
        return contextNode
    }

    // MARK: - 전체 검색 (Full-Text Search)

    /// ⇧⌘F — 검색 필드에 포커스.
    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    private func scheduleSearch() {
        searchDebounce?.cancel()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            exitSearch()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.performSearch(query: query) }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func performSearch(query: String) {
        // 트리 → 검색으로 처음 진입하는 순간(아직 트리 행이 표시된 상태)에
        // 펼침 상태를 스냅샷해 둔다 — 검색 종료 시 reloadTree(capture: false)가 복원한다.
        // 결과 모드에서의 재검색(키 입력 연타)에서는 이미 검색 행이라 캡처하지 않는다.
        if !isSearching { captureExpansionState() }
        guard !store.folders.isEmpty else {
            searchResults = []
            searchNotice = SearchNotice(L10n.tr("sidebar.empty.message"))
            outlineView.reloadData()
            updateEmptyState()
            return
        }
        searchSpinner.startAnimation(nil)
        fileSearcher.search(query: query, in: store.folders) { [weak self] results, truncated in
            guard let self = self else { return }
            self.searchSpinner.stopAnimation(nil)
            // 결과 도착 시점에 검색어가 이미 지워졌으면 무시
            let current = self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !current.isEmpty else { return }
            // 클릭 점프는 이 결과가 계산된 검색어(query)로 ordinal을 맞춰야 한다 — 필드의
            // 현재 텍스트(current)가 아니라, 실제 검색에 쓴 query를 저장한다.
            self.lastSearchQuery = query
            self.searchResults = results
            if results.isEmpty {
                self.searchNotice = SearchNotice(L10n.tr("sidebar.search.noResults"))
            } else if truncated {
                self.searchNotice = SearchNotice(L10n.tr("sidebar.search.truncated"))
            } else {
                self.searchNotice = nil
            }
            self.outlineView.reloadData()
            for result in results { self.outlineView.expandItem(result) }
            self.updateEmptyState()
        }
    }

    /// 검색어 삭제/Esc → 트리 모드 복귀 (펼침 상태는 reloadTree가 복원).
    private func exitSearch() {
        searchDebounce?.cancel()
        fileSearcher.cancel()
        searchSpinner.stopAnimation(nil)
        guard isSearching else { return }
        searchResults = nil
        searchNotice = nil
        lastSearchQuery = ""
        reloadTree(capture: false)
    }

    // MARK: - Public API

    /// 사이드바는 창 맨 위(신호등 줄)까지 바탕을 깔고, 내용은 헤더 줄 아래부터 시작한다.
    func alignContentTop(to guide: NSLayoutGuide) {
        _ = view
        headerTopConstraint?.isActive = false
        let top = headerView.topAnchor.constraint(equalTo: guide.topAnchor)
        top.isActive = true
        headerTopConstraint = top
    }

    func setCurrentFileURL(_ url: URL?) {
        currentFileURL = url
        highlightCurrentFile()
    }
}

// MARK: - DataSource

extension SidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let results = searchResults {
            if item == nil { return (searchNotice != nil ? 1 : 0) + results.count }
            if let result = item as? FileSearchResult { return result.hits.count }
            return 0
        }
        if item == nil { return roots.count }
        guard let node = item as? SidebarNode else { return 0 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let results = searchResults {
            if item == nil {
                if let notice = searchNotice {
                    return index == 0 ? notice : results[index - 1]
                }
                return results[index]
            }
            if let result = item as? FileSearchResult { return result.hits[index] }
        }
        if item == nil { return roots[index] }
        guard let node = item as? SidebarNode, let children = node.children else { return SidebarNode(url: URL(fileURLWithPath: "/"), isDirectory: false, isRoot: false) }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let result = item as? FileSearchResult { return !result.hits.isEmpty }
        if item is FileSearchHit || item is SearchNotice { return false }
        guard let node = item as? SidebarNode else { return false }
        return node.isDirectory && !(node.children?.isEmpty ?? true)
    }
}

// MARK: - Delegate

extension SidebarViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView)
            ?? SidebarCellView(identifier: identifier)

        if let notice = item as? SearchNotice {
            cell.configure(text: notice.text, font: NSFont.systemFont(ofSize: 11),
                           textColor: SidebarStyle.secondaryText,
                           icon: SidebarStyle.symbol("info.circle", size: 12))
            return cell
        }
        if let result = item as? FileSearchResult {
            cell.configure(text: "\(result.fileURL.lastPathComponent)  \(result.hits.count)",
                           font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                           textColor: SidebarStyle.text,
                           icon: SidebarStyle.symbol("doc.text", size: 13))
            configureChevron(cell, for: item, in: outlineView)
            return cell
        }
        if let hit = item as? FileSearchHit {
            let snippet = FileSearcher.makeSnippet(lineText: hit.lineText, matchRange: hit.matchRangeInLine)
            let attr = NSMutableAttributedString(
                string: snippet.text,
                attributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: SidebarStyle.secondaryText])
            attr.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                .foregroundColor: SidebarStyle.text],
                               range: snippet.highlight)
            cell.configure(attributed: attr, icon: nil)
            return cell
        }
        guard let node = item as? SidebarNode else { return nil }

        let textColor = node.isMissing ? NSColor.systemOrange : SidebarStyle.text
        // 등록된 최상위 폴더는 한 단계 굵게 — 트리의 뼈대가 먼저 읽히도록
        let font = NSFont.systemFont(ofSize: 13, weight: node.isRoot ? .semibold : .regular)
        cell.configure(text: displayName(for: node), font: font, textColor: textColor,
                       icon: icon(for: node),
                       iconColor: node.isMissing ? NSColor.systemOrange : SidebarStyle.icon)
        configureChevron(cell, for: item, in: outlineView)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SidebarRowView()
        row.level = max(0, outlineView.level(forItem: item))
        return row
    }

    func outlineViewItemDidExpand(_ notification: Notification) { refreshChevron(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { refreshChevron(notification) }

    private func refreshChevron(_ notification: Notification) {
        guard let outline = notification.object as? NSOutlineView,
              let item = notification.userInfo?["NSObject"] else { return }
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else { return }
        configureChevron(cell, for: item, in: outline)
    }

    private func configureChevron(_ cell: SidebarCellView, for item: Any, in outline: NSOutlineView) {
        guard outline.isExpandable(item) else { cell.setChevron(nil); return }
        cell.setChevron(outline.isItemExpanded(item))
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return !(item is SearchNotice)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateCreationButtons()
        // 실제 파일 열기는 click action에서 처리한다.
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
            return SidebarStyle.symbol("exclamationmark.triangle", size: 13)
        }
        if node.isDirectory {
            return SidebarStyle.symbol("folder", size: 13)
        }
        return SidebarStyle.symbol("doc.text", size: 13)
    }
}

// MARK: - Menu Delegate

extension SidebarViewController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        pendingRowClick?.cancel()
        let outline = outlineView!
        let row = outline.clickedRow
        contextNode = row >= 0 ? outline.item(atRow: row) as? SidebarNode : nil
        let node = contextNode

        for item in menu.items {
            switch item.action {
            case #selector(contextRemoveFolder(_:)):
                item.isHidden = !(node?.isRoot == true)
            case #selector(contextCreateDocument(_:)), #selector(contextCreateFolder(_:)):
                item.isHidden = node?.isDirectory != true || node?.isMissing == true
            case #selector(contextRename(_:)), #selector(contextDelete(_:)):
                item.isHidden = node == nil || node?.isMissing == true
            case #selector(contextRevealInFinder(_:)):
                item.isHidden = (node == nil)
            default:
                break
            }
        }
    }
}

// MARK: - Search Field Delegate

extension SidebarViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        scheduleSearch()
    }
}
