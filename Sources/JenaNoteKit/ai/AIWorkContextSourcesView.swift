import AppKit

/// ① "참고 자료" tab (spec §7.2 ①, §5.4): where settings come from (mixed folder/file sources with
/// add/remove), a three-segment budget bar with one factual sentence, and the settings-file list
/// (include · path · size · 원문/요약), size-sorted by default. Every change goes through
/// `controller.mutate`, which saves, reloads and re-renders this view, so the bar and the fact line
/// follow each toggle immediately. The app never suggests what to cut (§5.4 step 3).
final class AIWorkContextSourcesView: NSView, AIWorkContextRenderable, NSTableViewDataSource, NSTableViewDelegate {
    private weak var controller: AIWorkContextWindowController?

    var sort: AIWorkContextModel.FileSort = .sizeDescending {
        didSet { sortControl.selectedSegment = sort == .sizeDescending ? 0 : 1 }
    }

    // Test visibility
    private(set) var sourceRowViews: [NSView] = []
    /// One view per shown settings row (the path cell), in display order.
    private(set) var fileRowViews: [NSView] = []
    private(set) var factLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var budgetBar = AIWorkContextBudgetBar()
    /// Settings rows in display order (after `sort`).
    private(set) var shownRows: [AIWorkContextModel.SettingRow] = []

    let emptyLabel = NSTextField(wrappingLabelWithString: L10n.tr("ai.work.sources.empty"))
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let invalidPathsLabel = NSTextField(wrappingLabelWithString: "")
    let filesHeaderLabel = NSTextField(labelWithString: "")
    let sortControl = NSSegmentedControl()
    let tableView = NSTableView()
    let sourcesStack = NSStackView()

    private let scrollView = NSScrollView()
    private var cells: [[NSView]] = []
    private var shownSources: [AIWorkContextModel.SourceRow] = []
    /// Message for the last rejected pick; cleared by the next accepted change.
    private var rejection: String?

    private enum Column: String, CaseIterable { case include, path, size, mode }

    init(controller: AIWorkContextWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func build() {
        let header = NSTextField(labelWithString: L10n.tr("ai.work.sources.header"))
        header.font = .boldSystemFont(ofSize: 13)
        let hint = AIWorkContextSourceRowViews.small(L10n.tr("ai.work.sources.hint"))
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0

        sourcesStack.orientation = .vertical
        sourcesStack.alignment = .leading
        sourcesStack.spacing = 4
        emptyLabel.textColor = .secondaryLabelColor

        let addFolder = NSButton(title: L10n.tr("ai.work.sources.addFolder"), target: self, action: #selector(addFolderClicked))
        let addFile = NSButton(title: L10n.tr("ai.work.sources.addFile"), target: self, action: #selector(addFileClicked))
        for button in [addFolder, addFile] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let buttons = NSStackView(views: [addFolder, addFile])
        buttons.spacing = 8

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true

        factLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        factLabel.textColor = .secondaryLabelColor

        filesHeaderLabel.font = .boldSystemFont(ofSize: 13)
        sortControl.segmentCount = 2
        sortControl.setLabel(L10n.tr("ai.work.sources.sortSize"), forSegment: 0)
        sortControl.setLabel(L10n.tr("ai.work.sources.sortName"), forSegment: 1)
        sortControl.trackingMode = .selectOne
        sortControl.controlSize = .small
        sortControl.selectedSegment = 0
        sortControl.target = self
        sortControl.action = #selector(sortChanged)
        let filesSpacer = NSView()
        filesSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let filesHeader = NSStackView(views: [filesHeaderLabel, filesSpacer, sortControl])
        filesHeader.alignment = .centerY

        invalidPathsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        invalidPathsLabel.wantsLayer = true
        invalidPathsLabel.drawsBackground = true
        invalidPathsLabel.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25)
        invalidPathsLabel.isHidden = true

        buildTable()

        let stack = NSStackView(views: [header, hint, emptyLabel, sourcesStack, buttons, errorLabel,
                                        budgetBar, factLabel, filesHeader, invalidPathsLabel, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: hint)
        stack.setCustomSpacing(16, after: errorLabel)
        stack.setCustomSpacing(16, after: factLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func buildTable() {
        let widths: [Column: CGFloat] = [.include: 24, .path: 220, .size: 64, .mode: 110]
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.width = widths[column] ?? 60
            tableColumn.resizingMask = column == .path ? .autoresizingMask : []
            tableView.addTableColumn(tableColumn)
        }
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Render

    func render(controller: AIWorkContextWindowController) {
        guard let resolved = controller.resolved else { return }
        let payload = controller.payload
            ?? AIWorkContextAssembler(resolved: resolved, store: controller.store)
                .payload(currentFile: resolved.context.rootURL).payload
        render(resolved, payload: payload, store: controller.store, enabled: controller.context.config.enabled)
    }

    func render(_ resolved: AIResolvedWorkContext, payload: AIWorkPayload, store: AIEpisodeSummaryStore, enabled: Bool) {
        // Sources
        shownSources = AIWorkContextModel.sourceRows(resolved)
        sourceRowViews.forEach { $0.removeFromSuperview() }
        sourceRowViews = shownSources.enumerated().map { index, source in
            AIWorkContextSourceRowViews.sourceRow(source, index: index, target: self,
                                                  removeAction: #selector(removeClicked(_:)))
        }
        for row in sourceRowViews {
            sourcesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sourcesStack.widthAnchor).isActive = true
        }
        let empty = shownSources.isEmpty
        emptyLabel.isHidden = !empty
        sourcesStack.isHidden = empty

        let messages = [rejection, controller?.lastSaveError].compactMap { $0 }
        errorLabel.stringValue = messages.joined(separator: "\n")
        errorLabel.isHidden = messages.isEmpty

        // Budget
        let segments = AIWorkContextModel.budgetSegments(payload)
        budgetBar.update(settings: segments.settings, summaries: segments.summaries,
                         previous: segments.previous, limit: AIPrompt.maximumBytes)
        factLabel.stringValue = AIWorkContextModel.budgetFactLine(payload)
        factLabel.textColor = payload.contextByteCount > AIPrompt.maximumBytes ? .systemRed : .secondaryLabelColor
        budgetBar.alphaValue = enabled ? 1 : 0.5

        // Files
        filesHeaderLabel.stringValue = String(format: L10n.tr("ai.work.sources.filesHeader"), resolved.settings.count)
        if let invalid = AIWorkContextModel.invalidPathsText(resolved.context) {
            invalidPathsLabel.stringValue = invalid
            invalidPathsLabel.isHidden = false
        } else {
            invalidPathsLabel.isHidden = true
        }
        shownRows = AIWorkContextModel.sortedSettingRows(AIWorkContextModel.settingRows(resolved), by: sort)
        cells = shownRows.enumerated().map { index, row in
            AIWorkContextSourceRowViews.fileCells(row, index: index, target: self,
                                                  includeAction: #selector(includeClicked(_:)),
                                                  modeAction: #selector(modeChanged(_:)))
        }
        fileRowViews = cells.map { $0[1] }
        tableView.isEnabled = !empty
        scrollView.alphaValue = empty ? 0.5 : 1
        tableView.reloadData()
    }

    private func rerender() {
        guard let controller = controller else { return }
        render(controller: controller)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { cells.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < cells.count, let id = tableColumn?.identifier.rawValue,
              let column = Column(rawValue: id), let index = Column.allCases.firstIndex(of: column)
        else { return nil }
        return cells[row][index]
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: - Changes (internal for tests)

    func toggleInclude(row: Int) {
        guard row < shownRows.count else { return }
        let path = shownRows[row].file.relativePath
        rejection = nil
        controller?.mutate { AIWorkContextModel.toggleIncluded(&$0, path: path) }
    }

    func setSummarized(row: Int, _ summarized: Bool) {
        guard row < shownRows.count, shownRows[row].summarized != summarized else { return }
        let path = shownRows[row].file.relativePath
        rejection = nil
        controller?.mutate { AIWorkContextModel.toggleSummarized(&$0, path: path) }
    }

    func setSort(_ sort: AIWorkContextModel.FileSort) {
        guard sort != self.sort else { return }
        self.sort = sort
        rerender()
    }

    func addSource(url: URL) { addSources([url]) }

    /// Adds every picked URL in one change. A pick containing anything outside the root (or the
    /// root itself) is rejected as a whole: red label, nothing saved.
    func addSources(_ urls: [URL]) {
        guard let controller = controller, !urls.isEmpty else { return }
        let root = controller.context.rootURL
        rejection = nil
        do {
            try controller.mutate { config in
                for url in urls { try AIWorkContextModel.addingSource(url, to: &config, root: root) }
            }
        } catch let error as AIWorkContextValidationError {
            reject(Self.message(for: error))
        } catch {
            reject(error.localizedDescription)
        }
    }

    func removeSource(_ relativePath: String) {
        rejection = nil
        controller?.mutate { AIWorkContextModel.removingSource(relativePath, from: &$0) }
    }

    private func reject(_ message: String) {
        rejection = message
        rerender()
    }

    private static func message(for error: AIWorkContextValidationError) -> String {
        switch error {
        case .settingsOutsideRoot(let path): return String(format: L10n.tr("ai.work.errorOutsideRoot"), path)
        case .settingsIsRoot: return L10n.tr("ai.work.errorSourceIsRoot")
        case .noSettingsSources: return L10n.tr("ai.work.errorNoSettings")
        case .writingFolderOutsideRoot: return String(format: L10n.tr("ai.work.errorOutsideRoot"), "")
        }
    }

    // MARK: - Actions

    // Actions that rebuild the table tear down the clicked control, so the change runs on the next
    // main-loop turn, after AppKit has finished with the sender.
    @objc private func includeClicked(_ sender: NSButton) {
        let row = sender.tag
        DispatchQueue.main.async { [weak self] in self?.toggleInclude(row: row) }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let row = sender.tag
        let summarized = sender.selectedSegment == 1
        DispatchQueue.main.async { [weak self] in self?.setSummarized(row: row, summarized) }
    }

    @objc private func sortChanged() { setSort(sortControl.selectedSegment == 1 ? .name : .sizeDescending) }

    @objc private func removeClicked(_ sender: NSButton) {
        guard sender.tag < shownSources.count else { return }
        let path = shownSources[sender.tag].relativePath
        DispatchQueue.main.async { [weak self] in self?.removeSource(path) }
    }

    @objc private func addFolderClicked() {
        guard let root = controller?.context.rootURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK { addSources(panel.urls) }
    }

    @objc private func addFileClicked() {
        guard let root = controller?.context.rootURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = root
        if panel.runModal() == .OK { addSources(panel.urls) }
    }
}
