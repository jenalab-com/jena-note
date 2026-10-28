import AppKit

/// A tab view the window re-renders after every reload (Tasks 4/5 plug their views in here).
protocol AIWorkContextRenderable: AnyObject {
    func render(controller: AIWorkContextWindowController)
}

/// The work context window (spec §7.2): one per work root, left sidebar with three tabs, every
/// change saved to `context.json` immediately through `mutate`. Closing the window commits a
/// pending title edit and saves a valid first-setup context (spec §5.1 step 5), and keeps the
/// instance in the registry so the next open reuses it.
final class AIWorkContextWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int, CaseIterable { case sources, episodes, folders }

    // MARK: - Registry

    private static var controllers: [String: AIWorkContextWindowController] = [:]

    private static func key(for rootURL: URL) -> String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// One per root. Returns the existing controller if there is one (the caller calls `showWindow`).
    static func shared(for rootURL: URL, store: AIEpisodeSummaryStore) -> AIWorkContextWindowController {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = key(for: rootURL)
        if let existing = controllers[key] { return existing }
        let context = (try? AIWorkContext.load(rootURL: rootURL)) ?? AIWorkContext(
            rootURL: rootURL,
            config: AIWorkContextConfig(title: rootURL.lastPathComponent, settingsSources: [],
                                        writingFolder: "", enabled: false),
            invalidPaths: [])
        let controller = AIWorkContextWindowController(context: context, store: store, provisional: false)
        controllers[key] = controller
        return controller
    }

    /// First setup (no `context.json` yet): opens with a provisional context built from the
    /// suggestion. Nothing is written until the first `mutate` that yields a valid config, or until
    /// the window closes with the suggestion already valid (`windowWillClose`).
    static func forFirstSetup(fileURL: URL, store: AIEpisodeSummaryStore) -> AIWorkContextWindowController {
        dispatchPrecondition(condition: .onQueue(.main))
        let suggestion = AIWorkContextSuggestion.make(for: fileURL)
        let root = suggestion.rootURL
        if let existing = controllers[key(for: root)] {
            existing.currentFile = fileURL
            return existing
        }
        let configURL = root.appendingPathComponent(AIWorkContext.folderName)
            .appendingPathComponent(AIWorkContext.fileName)
        if FileManager.default.fileExists(atPath: configURL.path) {
            let controller = shared(for: root, store: store)
            controller.currentFile = fileURL
            return controller
        }
        let draft = AIWorkContextModel.foldersDraft(suggestionFor: fileURL)
        var config = AIWorkContextModel.applying(
            draft, to: AIWorkContextConfig(title: draft.title, settingsSources: [], writingFolder: "", enabled: false))
        // The suggested `설정`/`settings` folder is pre-listed as a source (spec §5.1 step 4).
        if let settings = suggestion.settingsSourceURL {
            try? AIWorkContextModel.addingSource(settings, to: &config, root: root)
        }
        let context = withInvalidPaths(AIWorkContext(rootURL: root, config: config, invalidPaths: []))
        let controller = AIWorkContextWindowController(context: context, store: store, provisional: true)
        controller.currentFile = fileURL
        controller.select(.folders)
        controllers[key(for: root)] = controller
        return controller
    }

    /// The registered controller for `rootURL`, if any; never creates one.
    static func existing(for rootURL: URL) -> AIWorkContextWindowController? {
        controllers[key(for: rootURL)]
    }

    static func resetRegistryForTesting() {
        for controller in controllers.values { controller.window?.orderOut(nil) }
        controllers.removeAll()
    }

    // MARK: - State

    private(set) var context: AIWorkContext
    private(set) var resolved: AIResolvedWorkContext?
    private(set) var store: AIEpisodeSummaryStore { didSet { observeStore() } }
    /// Re-renders the tabs when any request (this window's or another's) changes the store's generation state.
    private var storeObserver: AIStoreObserverToken?
    /// True while the context only lives in memory (first setup, nothing saved yet). Summary
    /// actions (episodes tab) are disabled meanwhile.
    private(set) var isProvisional: Bool
    /// Last save failure, shown in the folders tab until the next successful save.
    private(set) var lastSaveError: String?
    private(set) var selectedTab: Tab = .sources

    /// Base file for `resolve`; the chat panel updates it when the document changes.
    var currentFile: URL? { didSet { refreshResolved(); renderTabs() } }
    /// Called after `context.json` was written.
    var onChange: (() -> Void)?
    var onRegenerate: ((AIWorkFile, Bool) -> Void)?
    var onRefreshAll: (() -> Void)?
    var onCancelRefresh: (() -> Void)?
    /// The chat panel that set the hooks above, so a closing panel clears only hooks it still owns.
    var hooksOwner: ObjectIdentifier?
    /// Summary maintenance progress, pushed in by the chat panel.
    var maintenanceProgress: (done: Int, total: Int)? { didSet { renderTabs() } }
    /// Progress of a chat panel's send flow preparing summaries for this work (spec §5.2), so the
    /// episodes tab shows it as such instead of "another request is generating".
    var sendProgress: (done: Int, total: Int)? { didSet { renderTabs() } }

    var payload: AIWorkPayload? {
        guard let currentFile = currentFile, let resolved = resolved else { return nil }
        return AIWorkContextAssembler(resolved: resolved, store: store).payload(currentFile: currentFile).payload
    }

    /// Tab slots, re-rendered through `AIWorkContextRenderable` after every reload.
    var sourcesView: NSView? { didSet { if selectedTab == .sources { select(.sources) }; renderTabs() } }
    var episodesView: NSView? { didSet { if selectedTab == .episodes { select(.episodes) }; renderTabs() } }
    private(set) var foldersView: AIWorkContextFoldersView!

    private var sidebarRows: [Tab: SidebarRow] = [:]
    private let container = NSView()

    private init(context: AIWorkContext, store: AIEpisodeSummaryStore, provisional: Bool) {
        self.context = context
        self.store = store
        self.isProvisional = provisional
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
        observeStore()
        sourcesView = AIWorkContextSourcesView(controller: self)
        episodesView = AIWorkIndexView(controller: self)
        foldersView = AIWorkContextFoldersView(controller: self)
        buildUI()
        window.center()
        refreshResolved()
        select(.sources)
        renderTabs()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let titles: [Tab: String] = [.sources: L10n.tr("ai.work.tab.sources"),
                                     .episodes: L10n.tr("ai.work.tab.episodes"),
                                     .folders: L10n.tr("ai.work.tab.folders")]
        for tab in Tab.allCases {
            let row = SidebarRow(title: titles[tab] ?? "") { [weak self] in self?.select(tab) }
            sidebarRows[tab] = row
            sidebar.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16).isActive = true
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false

        let bottomDivider = NSBox()
        bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: L10n.tr("ai.work.close"), target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.translatesAutoresizingMaskIntoConstraints = false

        [sidebar, divider, container, bottomDivider, close].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 150),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            container.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),

            bottomDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -10),

            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    @objc private func closeWindow() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        commitPendingChanges()
    }

    /// Runs when the window closes (spec §5.1 step 5 "창을 닫으면 … 저장"): ends a pending title edit
    /// (saved through `mutate`), then saves a provisional context that is already valid (≥1 source,
    /// writing folder inside the root) — e.g. first setup where the suggestion needed no change.
    /// An invalid provisional context stays unsaved.
    func commitPendingChanges() {
        foldersView?.commitPendingTitle()
        window?.makeFirstResponder(nil)
        if isProvisional { commit(context) }
    }

    private func view(for tab: Tab) -> NSView? {
        switch tab {
        case .sources: return sourcesView
        case .episodes: return episodesView
        case .folders: return foldersView
        }
    }

    func select(_ tab: Tab) {
        selectedTab = tab
        for (rowTab, row) in sidebarRows { row.isSelected = rowTab == tab }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let view = view(for: tab) else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Reload / mutate

    /// Re-reads `context.json` (unless provisional), resolves against `currentFile` and re-renders every tab.
    func reload() {
        if !isProvisional, let disk = try? AIWorkContext.load(rootURL: context.rootURL) {
            context = disk
        }
        refreshResolved()
        renderTabs()
    }

    /// The single path for every change (Review Focus 4): re-load the disk config (so edits made
    /// elsewhere are kept), apply `change`, save, reload, notify. A corrupt disk file is ignored and
    /// overwritten with the in-memory config. A provisional context is saved only once the result
    /// is valid (root, writing folder and at least one source); until then it stays in memory.
    func mutate(_ change: (inout AIWorkContextConfig) throws -> Void) rethrows {
        var base = context
        if FileManager.default.fileExists(atPath: context.configURL.path),
           let disk = try? AIWorkContext.load(rootURL: context.rootURL) {
            base = disk
        }
        var config = base.config
        try change(&config)
        let updated = Self.withInvalidPaths(AIWorkContext(rootURL: context.rootURL, config: config, invalidPaths: []))
        commit(updated)
    }

    /// True when `newRoot` is a different root that already has a work context of its own
    /// (a `context.json` on disk or another registered window). `changeRoot` refuses such roots.
    func rootHasOtherContext(_ newRoot: URL) -> Bool {
        let newKey = Self.key(for: newRoot)
        guard newKey != Self.key(for: context.rootURL) else { return false }
        if let other = Self.controllers[newKey], other !== self { return true }
        let url = newRoot.appendingPathComponent(AIWorkContext.folderName)
            .appendingPathComponent(AIWorkContext.fileName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Moves the work to `newRoot`. Refuses (returns false, nothing touched) when the new root
    /// already has a work context of its own or the writing folder would fall outside it.
    /// Otherwise the current config is re-loaded from disk (corrupt → in-memory), every relative
    /// path is re-based onto the new root (entries that end up outside it are kept as absolute
    /// paths, which `load` reports in `invalidPaths`), saved there, the registry/store move, and
    /// the old root's `context.json` is removed so `locate` (nearest wins) stops finding it.
    @discardableResult
    func changeRoot(to newRoot: URL) -> Bool {
        guard !rootHasOtherContext(newRoot) else { return false }
        let oldRoot = context.rootURL
        var base = context
        if !isProvisional, FileManager.default.fileExists(atPath: context.configURL.path),
           let disk = try? AIWorkContext.load(rootURL: oldRoot) {
            base = disk
        }
        let writing = base.writingFolderURL ?? oldRoot
        guard let writingRelative = AIWorkContext.relativePath(of: writing, to: newRoot) else { return false }
        var config = base.config
        config.settingsSources = config.settingsSources.map { Self.rebase($0, from: oldRoot, to: newRoot) }
        config.excludedSettings = config.excludedSettings.map { Self.rebase($0, from: oldRoot, to: newRoot) }
        config.summarizedSettings = config.summarizedSettings.map { Self.rebase($0, from: oldRoot, to: newRoot) }
        config.writingFolder = writingRelative
        let updated = Self.withInvalidPaths(AIWorkContext(rootURL: newRoot, config: config, invalidPaths: []))
        let wasSaved = !isProvisional
        if wasSaved {
            do {
                try updated.save()
                let indexStore = AIWorkIndexStore.shared(for: updated.rootURL)
                if updated.config.enabled { indexStore.schedule(context: updated) } else { indexStore.cancel() }
                lastSaveError = nil
            } catch {
                lastSaveError = String(format: L10n.tr("ai.work.saveFailed"), error.localizedDescription)
                renderTabs()
                return false
            }
        }
        let oldKey = Self.key(for: oldRoot)
        let newKey = Self.key(for: newRoot)
        if oldKey != newKey {
            AIWorkIndexStore.shared(for: oldRoot).cancel()
            Self.controllers[oldKey] = nil
            Self.controllers[newKey] = self
            store = AIEpisodeSummaryStore.shared(for: newRoot)
        }
        guard wasSaved else {
            commit(updated)   // provisional: written only once valid
            return true
        }
        context = updated
        if oldKey != newKey {
            let oldURL = oldRoot.appendingPathComponent(AIWorkContext.folderName)
                .appendingPathComponent(AIWorkContext.fileName)
            if AIWorkContext.isSafeInsideRoot(oldURL, root: oldRoot) {
                try? FileManager.default.removeItem(at: oldURL)
            }
        }
        reload()
        onChange?()
        return true
    }

    private func commit(_ updated: AIWorkContext) {
        context = updated
        let valid = AIWorkContext.validate(rootURL: updated.rootURL, settingsSources: updated.settingsSourceURLs,
                                           writingFolder: updated.writingFolderURL ?? updated.rootURL)
        let writingOK = updated.writingFolderURL != nil && !valid.contains(.writingFolderOutsideRoot)
        let canSave = writingOK && (!isProvisional || (valid.isEmpty && !updated.config.settingsSources.isEmpty))
        guard canSave else {
            refreshResolved()
            renderTabs()
            return
        }
        do {
            try updated.save()
            let indexStore = AIWorkIndexStore.shared(for: updated.rootURL)
            if updated.config.enabled { indexStore.schedule(context: updated) } else { indexStore.cancel() }
            isProvisional = false
            lastSaveError = nil
        } catch {
            lastSaveError = String(format: L10n.tr("ai.work.saveFailed"), error.localizedDescription)
            refreshResolved()
            renderTabs()
            return
        }
        reload()
        onChange?()
    }

    private func refreshResolved() {
        resolved = AIWorkContextResolver.resolve(context, currentFile: currentFile ?? context.rootURL)
    }

    private func observeStore() {
        storeObserver = store.addGenerationObserver { [weak self] in self?.renderTabs() }
    }

    private func renderTabs() {
        window?.title = String(format: L10n.tr("ai.work.window.title"), context.config.title)
        foldersView?.render(AIWorkContextModel.foldersDraft(from: context), enabled: context.config.enabled)
        for view in [sourcesView, episodesView] {
            (view as? AIWorkContextRenderable)?.render(controller: self)
        }
    }

    // MARK: - Helpers

    private static func rebase(_ path: String, from oldRoot: URL, to newRoot: URL) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path != ".", !path.hasPrefix("/"), !path.hasPrefix("~"), !parts.contains("..") else {
            return path
        }
        let absolute = parts.reduce(oldRoot) { $0.appendingPathComponent(String($1)) }
        if let rel = AIWorkContext.relativePath(of: absolute, to: newRoot), !rel.isEmpty { return rel }
        return absolute.path
    }

    /// `invalidPaths` for an in-memory context, matching what `load` would report.
    private static func withInvalidPaths(_ context: AIWorkContext) -> AIWorkContext {
        var result = context
        var invalid = context.config.settingsSources.filter { path in
            var single = context
            single.config.settingsSources = [path]
            return single.settingsSourceURLs.isEmpty
        }
        if context.writingFolderURL == nil { invalid.append(context.config.writingFolder) }
        result.invalidPaths = invalid
        return result
    }
}

// MARK: - Sidebar row

private final class SidebarRow: NSView {
    private let label: NSTextField
    private let action: () -> Void

    var isSelected = false {
        didSet {
            layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor
                : NSColor.clear.cgColor
            label.font = isSelected ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        }
    }

    init(title: String, action: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
