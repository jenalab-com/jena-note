import AppKit
import ImageIO

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
    private var emptyStateView: NSView!
    private var addButton: NSButton!
    private var sortButton: NSButton!

    /// 폴더 / 이미지 탭 전환
    private var tabControl: NSSegmentedControl!
    /// 이미지 탭의 폴더+이미지 트리
    private var imageScrollView: NSScrollView!
    private var imageOutlineView: NSOutlineView!
    private var imageEmptyLabel: NSTextField!

    private var roots: [SidebarNode] = []
    /// 펼침 상태 보존용 (URL 경로 기준)
    private var expandedPaths: Set<String> = []

    /// 이미지 탭 트리의 루트 노드들 (폴더 + 이미지 파일, 이미지가 든 폴더만)
    private var imageRoots: [SidebarNode] = []
    /// 썸네일 캐시 (경로 기준)
    private var thumbnailCache: [String: NSImage] = [:]

    private enum Tab: Int { case folders = 0, images = 1 }
    private var selectedTab: Tab = .folders

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

    // 사이드바에서 연 파일 (강조 표시용)
    var currentFileURL: URL?

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        container.wantsLayer = true

        setupHeader(in: container)
        setupTab(in: container)
        setupSearchField(in: container)
        setupOutline(in: container)
        setupImageList(in: container)
        setupEmptyState(in: container)

        view = container
        updateTabVisibility()
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

        sortButton = NSButton(frame: .zero)
        sortButton.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: L10n.tr("sidebar.sort.tooltip"))
        sortButton.isBordered = false
        sortButton.bezelStyle = .inline
        sortButton.target = self
        sortButton.action = #selector(showSortMenu(_:))
        sortButton.toolTip = L10n.tr("sidebar.sort.tooltip")
        sortButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(sortButton)

        searchSpinner = NSProgressIndicator()
        searchSpinner.style = .spinning
        searchSpinner.controlSize = .small
        searchSpinner.isDisplayedWhenStopped = false
        searchSpinner.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(searchSpinner)

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
            addButton.heightAnchor.constraint(equalToConstant: 22),

            sortButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),
            sortButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            sortButton.widthAnchor.constraint(equalToConstant: 22),
            sortButton.heightAnchor.constraint(equalToConstant: 22),

            searchSpinner.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -4),
            searchSpinner.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            searchSpinner.widthAnchor.constraint(equalToConstant: 16),
            searchSpinner.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func setupTab(in container: NSView) {
        tabControl = NSSegmentedControl(labels: [L10n.tr("sidebar.tab.folders"), L10n.tr("sidebar.tab.images")],
                                        trackingMode: .selectOne, target: self, action: #selector(tabChanged(_:)))
        tabControl.segmentStyle = .automatic
        tabControl.selectedSegment = 0
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabControl)

        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 2),
            tabControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            tabControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            tabControl.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func setupSearchField(in container: NSView) {
        searchField = NSSearchField()
        searchField.placeholderString = L10n.tr("sidebar.search.placeholder")
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8)
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
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func setupImageList(in container: NSView) {
        imageScrollView = NSScrollView()
        imageScrollView.hasVerticalScroller = true
        imageScrollView.hasHorizontalScroller = false
        imageScrollView.borderType = .noBorder
        imageScrollView.drawsBackground = false
        imageScrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageScrollView)

        imageOutlineView = ImagePreviewOutlineView()
        imageOutlineView.headerView = nil
        imageOutlineView.indentationPerLevel = 14
        imageOutlineView.rowSizeStyle = .default
        imageOutlineView.style = .sourceList
        imageOutlineView.allowsMultipleSelection = false
        imageOutlineView.autoresizesOutlineColumn = false
        imageOutlineView.usesAutomaticRowHeights = false
        imageOutlineView.rowHeight = 24
        imageOutlineView.target = self
        imageOutlineView.action = #selector(imageOutlineRowClicked(_:))
        imageOutlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("image"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        imageOutlineView.addTableColumn(column)
        imageOutlineView.outlineTableColumn = column
        imageOutlineView.dataSource = self
        imageOutlineView.delegate = self

        imageScrollView.documentView = imageOutlineView

        imageEmptyLabel = NSTextField(labelWithString: L10n.tr("sidebar.images.empty"))
        imageEmptyLabel.font = NSFont.systemFont(ofSize: 12)
        imageEmptyLabel.textColor = NSColor.secondaryLabelColor
        imageEmptyLabel.alignment = .center
        imageEmptyLabel.lineBreakMode = .byWordWrapping
        imageEmptyLabel.maximumNumberOfLines = 0
        imageEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageEmptyLabel)

        NSLayoutConstraint.activate([
            imageScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            imageScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            imageEmptyLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 60),
            imageEmptyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            imageEmptyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
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
            emptyStateView.topAnchor.constraint(equalTo: searchField.bottomAnchor),
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
        // 검색 결과 모드에서는 트리 UI를 건드리지 않는다 — FSEvents 갱신은
        // 검색 종료(exitSearch) 시 reloadTree가 최신 상태로 재구성한다.
        if isSearching { return }
        captureExpansionState()
        // reloadData()는 스크롤을 맨 위로 되돌리므로, 보던 위치를 저장했다가 복원한다
        // (외부 파일 변경으로 갱신될 때 스크롤이 튀지 않도록).
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
        highlightCurrentFile()

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
                // 안에 .md가 하나라도 있으면 표시
                let children = scanDirectory(entry)
                if !children.isEmpty {
                    let node = SidebarNode(url: entry, isDirectory: true, isRoot: false, modificationDate: modDate)
                    node.children = children
                    subdirs.append(node)
                }
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
        guard selectedTab == .folders else {
            scrollView.isHidden = true
            emptyStateView.isHidden = true
            return
        }
        let isEmpty = roots.isEmpty && !isSearching
        emptyStateView.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    // MARK: - Tab Switching

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectedTab = Tab(rawValue: sender.selectedSegment) ?? .folders
        if selectedTab == .images {
            reloadImageTree()
        }
        updateTabVisibility()
    }

    private func updateTabVisibility() {
        let showImages = selectedTab == .images
        imageScrollView.isHidden = !showImages
        imageEmptyLabel.isHidden = !showImages || !isImageTreeEmpty
        if showImages {
            scrollView.isHidden = true
            emptyStateView.isHidden = true
        } else {
            updateEmptyState()
        }
    }

    // MARK: - Image Scanning

    private func reloadImageTree() {
        let savedOrigin = imageScrollView.contentView.bounds.origin
        imageRoots = store.folders.map { url -> SidebarNode in
            let accessible = store.isAccessible(url)
            let node = SidebarNode(url: url, isDirectory: true, isRoot: true, isMissing: !accessible)
            node.children = accessible ? scanImageTree(url) : []
            return node
        }
        imageOutlineView.reloadData()
        for root in imageRoots { imageOutlineView.expandItem(root) }
        if selectedTab == .images {
            imageEmptyLabel.isHidden = !isImageTreeEmpty
        }
        imageScrollView.contentView.scroll(to: savedOrigin)
        imageScrollView.reflectScrolledClipView(imageScrollView.contentView)
    }

    /// 모든 루트의 트리에 이미지가 하나도 없으면 true.
    private var isImageTreeEmpty: Bool {
        imageRoots.allSatisfy { ($0.children?.isEmpty ?? true) }
    }

    /// 폴더를 재귀 스캔해 이미지 파일과 (이미지를 포함한) 하위 폴더만 트리로 구성한다.
    private func scanImageTree(_ url: URL) -> [SidebarNode] {
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
                let children = scanImageTree(entry)
                if !children.isEmpty {
                    let node = SidebarNode(url: entry, isDirectory: true, isRoot: false, modificationDate: modDate)
                    node.children = children
                    subdirs.append(node)
                }
            } else if sidebarImageExtensions.contains(entry.pathExtension.lowercased()) {
                files.append(SidebarNode(url: entry, isDirectory: false, isRoot: false, modificationDate: modDate))
            }
        }

        sortNodes(&subdirs)
        sortNodes(&files)
        return subdirs + files
    }

    /// 캐시된 썸네일을 반환하거나 새로 다운샘플링한다.
    private func thumbnail(for url: URL) -> NSImage? {
        let key = url.path
        if let cached = thumbnailCache[key] { return cached }
        guard let img = SidebarViewController.downsampledImage(at: url, maxPixel: 72) else { return nil }
        thumbnailCache[key] = img
        return img
    }

    /// ImageIO로 최대 변 maxPixel 이하 썸네일을 만든다 (메모리 절약).
    static func downsampledImage(at url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    @objc private func imageOutlineRowClicked(_ sender: Any?) {
        let row = imageOutlineView.clickedRow
        guard row >= 0, let node = imageOutlineView.item(atRow: row) as? SidebarNode else { return }
        // 폴더는 펼침/접기만. 이미지는 드래그로 본문에 삽입(클릭 동작 없음 — 미리보기는 hover 팝업).
        guard node.isDirectory else { return }
        if imageOutlineView.isItemExpanded(node) {
            imageOutlineView.collapseItem(node)
        } else {
            imageOutlineView.expandItem(node)
        }
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
        if selectedTab == .images { reloadImageTree() }
    }

    @objc private func handleContentsChange() {
        reloadTree()
        if selectedTab == .images { reloadImageTree() }
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
            let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            opener.openFileFromSidebar(at: parent.fileURL,
                                       jumpingTo: SearchJump(query: query, ordinal: hit.ordinalInFile))
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

    // MARK: - 전체 검색 (Full-Text Search)

    /// ⇧⌘F — 폴더 탭으로 전환하고 검색 필드에 포커스.
    func focusSearchField() {
        if selectedTab != .folders {
            tabControl.selectedSegment = Tab.folders.rawValue
            tabChanged(tabControl)
        }
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
        if selectedTab != .folders {
            tabControl.selectedSegment = Tab.folders.rawValue
            tabChanged(tabControl)
        }
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
        reloadTree()
    }

    // MARK: - Public API

    func setCurrentFileURL(_ url: URL?) {
        currentFileURL = url
        highlightCurrentFile()
    }
}

// MARK: - DataSource

extension SidebarViewController: NSOutlineViewDataSource {

    /// 폴더 탭과 이미지 탭이 같은 dataSource를 공유 — outline 인스턴스로 루트를 가른다.
    private func roots(for outlineView: NSOutlineView) -> [SidebarNode] {
        outlineView === imageOutlineView ? imageRoots : roots
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if outlineView !== imageOutlineView, let results = searchResults {
            if item == nil { return (searchNotice != nil ? 1 : 0) + results.count }
            if let result = item as? FileSearchResult { return result.hits.count }
            return 0
        }
        if item == nil { return roots(for: outlineView).count }
        guard let node = item as? SidebarNode else { return 0 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if outlineView !== imageOutlineView, let results = searchResults {
            if item == nil {
                if let notice = searchNotice {
                    return index == 0 ? notice : results[index - 1]
                }
                return results[index]
            }
            if let result = item as? FileSearchResult { return result.hits[index] }
        }
        if item == nil { return roots(for: outlineView)[index] }
        guard let node = item as? SidebarNode, let children = node.children else { return SidebarNode(url: URL(fileURLWithPath: "/"), isDirectory: false, isRoot: false) }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let result = item as? FileSearchResult { return !result.hits.isEmpty }
        if item is FileSearchHit || item is SearchNotice { return false }
        guard let node = item as? SidebarNode else { return false }
        return node.isDirectory && !(node.children?.isEmpty ?? true)
    }

    /// 이미지 노드를 본문으로 드래그할 수 있도록 파일 URL을 pasteboard에 싣는다 (드롭 삽입과 연동).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard outlineView === imageOutlineView,
              let node = item as? SidebarNode, !node.isDirectory else { return nil }
        return node.url as NSURL
    }
}

// MARK: - Delegate

extension SidebarViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let notice = item as? SearchNotice {
            let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell: NSTableCellView = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
            cell.textField?.stringValue = notice.text
            cell.textField?.font = NSFont.systemFont(ofSize: 11)
            cell.textField?.textColor = NSColor.secondaryLabelColor
            cell.imageView?.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
            return cell
        }
        if let result = item as? FileSearchResult {
            let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell: NSTableCellView = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
            cell.textField?.stringValue = "\(result.fileURL.lastPathComponent) (\(result.hits.count))"
            cell.textField?.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            cell.textField?.textColor = NSColor.labelColor
            cell.imageView?.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            return cell
        }
        if let hit = item as? FileSearchHit {
            let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell: NSTableCellView = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
            let snippet = FileSearcher.makeSnippet(lineText: hit.lineText, matchRange: hit.matchRangeInLine)
            let attr = NSMutableAttributedString(
                string: snippet.text,
                attributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: NSColor.secondaryLabelColor])
            attr.addAttributes([.font: NSFont.boldSystemFont(ofSize: 12),
                                .foregroundColor: NSColor.labelColor],
                               range: snippet.highlight)
            cell.textField?.attributedStringValue = attr
            cell.imageView?.image = nil
            return cell
        }
        guard let node = item as? SidebarNode else { return nil }

        // 이미지 탭 트리: 폴더 아이콘 / 작은 썸네일 + 파일명
        if outlineView === imageOutlineView {
            let identifier = NSUserInterfaceItemIdentifier("ImageTreeCell")
            let cell: NSTableCellView = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
            cell.textField?.stringValue = displayName(for: node)
            if node.isDirectory {
                cell.imageView?.image = icon(for: node)
            } else {
                cell.imageView?.image = thumbnail(for: node.url)
                    ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            }
            cell.textField?.textColor = node.isMissing ? NSColor.systemOrange : NSColor.labelColor
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell: NSTableCellView = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
        cell.textField?.font = NSFont.systemFont(ofSize: 13)
        cell.textField?.stringValue = displayName(for: node)
        cell.imageView?.image = icon(for: node)
        cell.textField?.textColor = node.isMissing ? NSColor.systemOrange : NSColor.labelColor
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return !(item is SearchNotice)
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

// MARK: - Search Field Delegate

extension SidebarViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        scheduleSearch()
    }
}
