import AppKit

/// ② "지난 화" tab (spec §7.2 ②, §5.3): what the AI remembers of the earlier episodes. One row per
/// earlier episode with its summary state in plain words, "열기" (summary in a new window) and
/// "다시 만들기"/"지금 만들기"; a tool row with "요약 전부 새로 만들기" ↔ "갱신 취소" + progress and the
/// last refresh time; the previous-episode toggle at the bottom. Every config change goes through
/// `controller.mutate`; summary work goes through the controller hooks (the chat panel runs it).
final class AIWorkContextEpisodesView: NSView, AIWorkContextRenderable, NSTableViewDataSource, NSTableViewDelegate {
    private weak var controller: AIWorkContextWindowController?

    /// Opens a summary file as a document; replaced in tests.
    var openDocumentHandler: ((URL) -> Void)?
    /// Asks before replacing a summary the author edited; `completion(true)` regenerates. Replaced in
    /// tests. Default: `ai.work.regenerateConfirm` as a sheet on this view's window (no window → no-op).
    var confirmRegenerate: ((_ file: AIWorkFile, _ completion: @escaping (Bool) -> Void) -> Void)?

    // Test visibility
    /// Episode rows in display order (episode order).
    private(set) var shownRows: [AIWorkContextModel.EpisodeRow] = []
    /// The previous episode (sent in full), if `includePreviousEpisode` is on.
    private(set) var previousEpisodePath: String?
    /// Per row: state label, previous tag (nil when not the previous episode), open and remake buttons.
    private(set) var stateLabels: [NSTextField] = []
    private(set) var previousTags: [NSTextField?] = []
    private(set) var openButtons: [NSButton] = []
    private(set) var remakeButtons: [NSButton] = []

    let hintLabel = NSTextField(wrappingLabelWithString: "")
    let refreshButton = NSButton(title: L10n.tr("ai.work.episodes.refreshAll"), target: nil, action: nil)
    let progressLabel = NSTextField(labelWithString: "")
    let lastRefreshLabel = NSTextField(labelWithString: "")
    let otherGeneratingLabel = NSTextField(labelWithString: L10n.tr("ai.work.episodes.otherGenerating"))
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let includePreviousCheckbox = NSButton(checkboxWithTitle: L10n.tr("ai.work.episodes.includePrevious"),
                                           target: nil, action: nil)
    let tableView = NSTableView()

    private let scrollView = NSScrollView()
    private var cells: [[NSView]] = []
    /// True while this window's refresh run is active (the tool button cancels instead).
    private(set) var isRefreshing = false
    /// Message for the last refused/failed "열기"; cleared by the next render-triggering action.
    private var openError: String?

    private enum Column: String, CaseIterable { case name, state, tag, open, remake }

    init(controller: AIWorkContextWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func build() {
        let header = NSTextField(labelWithString: L10n.tr("ai.work.episodes.header"))
        header.font = .boldSystemFont(ofSize: 13)
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        progressLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.isHidden = true
        lastRefreshLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lastRefreshLabel.textColor = .secondaryLabelColor
        let toolSpacer = NSView()
        toolSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolRow = NSStackView(views: [refreshButton, progressLabel, toolSpacer, lastRefreshLabel])
        toolRow.spacing = 8
        toolRow.alignment = .centerY

        otherGeneratingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        otherGeneratingLabel.textColor = .systemOrange
        otherGeneratingLabel.isHidden = true

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true

        includePreviousCheckbox.target = self
        includePreviousCheckbox.action = #selector(includePreviousClicked(_:))

        buildTable()

        let stack = NSStackView(views: [header, hintLabel, toolRow, otherGeneratingLabel, errorLabel,
                                        scrollView, includePreviousCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in stack.arrangedSubviews where view !== includePreviousCheckbox {
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
        let widths: [Column: CGFloat] = [.name: 120, .state: 200, .tag: 90, .open: 56, .remake: 90]
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.width = widths[column] ?? 60
            tableColumn.resizingMask = column == .name ? .autoresizingMask : []
            tableView.addTableColumn(tableColumn)
        }
        tableView.headerView = nil
        tableView.rowHeight = 26
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
        let progress = controller.maintenanceProgress.map { ($0.done, $0.total) }
        let otherGenerating = controller.store.isGenerating && progress == nil
        render(resolved, store: controller.store, progress: progress, otherGenerating: otherGenerating,
               lastRefresh: AIWorkContextModel.lastRefresh(controller.store.snapshotIndex()))
    }

    func render(_ resolved: AIResolvedWorkContext, store: AIEpisodeSummaryStore, progress: (Int, Int)?,
                otherGenerating: Bool, lastRefresh: Date?) {
        let previous = resolved.previousEpisodes
        if let current = resolved.currentIndex, !previous.isEmpty {
            if resolved.context.config.includePreviousEpisode {
                hintLabel.stringValue = String(format: L10n.tr("ai.work.episodes.hint"),
                                               current + 1, previous.count, previous.count)
            } else {
                hintLabel.stringValue = String(format: L10n.tr("ai.work.episodes.hintNoPrevious"),
                                               current + 1, previous.count)
            }
        } else {
            hintLabel.stringValue = L10n.tr("ai.work.episodes.hintNone")
        }

        // Tool row
        isRefreshing = progress != nil
        if let progress = progress {
            refreshButton.title = L10n.tr("ai.work.cancelRefresh")
            progressLabel.stringValue = "\(progress.0)/\(progress.1)"
            progressLabel.isHidden = false
        } else {
            refreshButton.title = L10n.tr("ai.work.episodes.refreshAll")
            progressLabel.isHidden = true
        }
        refreshButton.isEnabled = isRefreshing || (!otherGenerating && !previous.isEmpty)
        if let lastRefresh = lastRefresh {
            let formatted = DateFormatter.localizedString(from: lastRefresh, dateStyle: .short, timeStyle: .short)
            lastRefreshLabel.stringValue = String(format: L10n.tr("ai.work.episodes.lastRefresh"), formatted)
            lastRefreshLabel.isHidden = false
        } else {
            lastRefreshLabel.isHidden = true
        }
        otherGeneratingLabel.isHidden = !otherGenerating

        let messages = [openError, controller?.lastSaveError].compactMap { $0 }
        errorLabel.stringValue = messages.joined(separator: "\n")
        errorLabel.isHidden = messages.isEmpty

        // List — disabled while any run (this window's or another's) is generating.
        let busy = isRefreshing || otherGenerating || store.isGenerating
        previousEpisodePath = resolved.previousEpisode?.relativePath
        shownRows = AIWorkContextModel.episodeRows(resolved, store: store)
        cells = shownRows.enumerated().map { index, row in
            makeCells(row, index: index, store: store, busy: busy)
        }
        stateLabels = cells.compactMap { ($0[1] as? NSStackView)?.arrangedSubviews.last as? NSTextField }
        previousTags = cells.map { $0[2] as? NSTextField }
        openButtons = cells.compactMap { $0[3] as? NSButton }
        remakeButtons = cells.compactMap { $0[4] as? NSButton }
        tableView.isEnabled = !busy
        scrollView.alphaValue = busy ? 0.6 : 1
        tableView.reloadData()

        includePreviousCheckbox.state = resolved.context.config.includePreviousEpisode ? .on : .off
    }

    private func makeCells(_ row: AIWorkContextModel.EpisodeRow, index: Int, store: AIEpisodeSummaryStore,
                           busy: Bool) -> [NSView] {
        let name = NSTextField(labelWithString: row.file.relativePath)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = row.file.relativePath
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let label = AIWorkContextModel.episodeStateLabel(row.state)
        let marker: NSView
        if label.isManual {
            marker = AIWorkContextSourceRowViews.symbol("lock.fill", color: .secondaryLabelColor)
        } else {
            marker = AIWorkContextSourceRowViews.symbol("circle.fill", color: Self.color(for: label.tone))
            (marker as? NSImageView)?.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        }
        marker.setAccessibilityElement(false)
        let text = AIWorkContextSourceRowViews.small(label.text, color: .labelColor)
        text.lineBreakMode = .byTruncatingTail
        let stateCell = NSStackView(views: [marker, text])
        stateCell.spacing = 4
        stateCell.alignment = .centerY

        let tag: NSView
        if row.file.relativePath == previousEpisodePath {
            let pill = AIWorkContextSourceRowViews.small(L10n.tr("ai.work.episodes.previousTag"))
            pill.wantsLayer = true
            pill.drawsBackground = true
            pill.backgroundColor = NSColor.quaternaryLabelColor
            tag = pill
        } else {
            tag = NSView()
        }

        let open = NSButton(title: L10n.tr("ai.work.open"), target: self, action: #selector(openClicked(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.tag = index
        open.isEnabled = FileManager.default.fileExists(atPath: store.summaryURL(for: row.file, isSetting: false).path)
        open.setAccessibilityLabel(L10n.tr("ai.work.open") + " " + row.file.relativePath)

        let remakeTitle = row.state == .missing ? L10n.tr("ai.work.episodes.makeNow") : L10n.tr("ai.work.episodes.remake")
        let remake = NSButton(title: remakeTitle, target: self, action: #selector(remakeClicked(_:)))
        remake.bezelStyle = .rounded
        remake.controlSize = .small
        remake.tag = index
        remake.isEnabled = !busy
        remake.setAccessibilityLabel(remakeTitle + " " + row.file.relativePath)
        return [name, stateCell, tag, open, remake]
    }

    private static func color(for tone: AIWorkContextModel.EpisodeTone) -> NSColor {
        switch tone {
        case .ready: return .systemGreen
        case .stale: return .systemOrange
        case .missing: return .systemGray
        case .manual: return .secondaryLabelColor
        }
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

    /// "열기" on row `row`.
    func open(row: Int) {
        guard row < shownRows.count, let store = controller?.store else { return }
        openSummary(shownRows[row].file, store: store)
    }

    /// Every user action starts by dropping the last "열기" error (re-rendered by the action itself
    /// or here when it doesn't re-render).
    private func clearOpenError() {
        guard openError != nil else { return }
        openError = nil
        rerender()
    }

    /// Opens the summary in its own window (spec §5.3, §13). Refuses a summary path that leaves the
    /// root or goes through a symlink (any component, including the leaf) — red label, nothing opened.
    /// An already open document for that file is brought to the front instead of opened twice.
    func openSummary(_ file: AIWorkFile, store: AIEpisodeSummaryStore) {
        let url = store.summaryURL(for: file, isSetting: false)
        guard AIWorkContext.isSafeInsideRoot(url, root: store.rootURL) else {
            openError = String(format: L10n.tr("ai.work.errorOutsideRoot"), url.path)
            rerender()
            return
        }
        clearOpenError()
        let target = url.standardizedFileURL
        let open = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }.first {
            $0.fileURL?.standardizedFileURL == target
        }
        if let window = open?.windowControllers.first?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let handler = openDocumentHandler {
            handler(url)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
            guard let self = self, let error = error else { return }
            self.openError = error.localizedDescription
            self.rerender()
        }
    }

    /// "다시 만들기"/"지금 만들기" on row `row`. A summary the author edited asks first (sheet).
    func remake(row: Int) {
        clearOpenError()
        guard row < shownRows.count, let controller = controller, !controller.store.isGenerating else { return }
        let entry = shownRows[row]
        guard case .manuallyEdited = entry.state else {
            controller.onRegenerate?(entry.file, false)
            return
        }
        let file = entry.file
        let ask = confirmRegenerate ?? { [weak self] file, completion in self?.presentRegenerateSheet(for: file, completion) }
        ask(file) { [weak controller] confirmed in
            guard confirmed else { return }
            controller?.onRegenerate?(file, false)
        }
    }

    /// Sheet on this view's window; without a window nothing is asked and nothing happens (never `runModal`).
    private func presentRegenerateSheet(for file: AIWorkFile, _ completion: @escaping (Bool) -> Void) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("ai.work.regenerateConfirm")
        alert.informativeText = file.relativePath
        alert.addButton(withTitle: L10n.tr("ai.work.episodes.remake"))
        alert.addButton(withTitle: L10n.tr("ai.work.cancel"))
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }

    /// The tool button: "요약 전부 새로 만들기" when idle, "갱신 취소" while this window's run is active.
    func refreshOrCancel() {
        clearOpenError()
        guard let controller = controller else { return }
        if isRefreshing {
            controller.onCancelRefresh?()
        } else if !controller.store.isGenerating {
            controller.onRefreshAll?()
        }
    }

    func setIncludePrevious(_ on: Bool) {
        clearOpenError()
        guard let controller = controller, controller.context.config.includePreviousEpisode != on else { return }
        controller.mutate { $0.includePreviousEpisode = on }
    }

    // MARK: - Actions (deferred: a rebuild tears down the clicked control)

    @objc private func openClicked(_ sender: NSButton) {
        let row = sender.tag
        DispatchQueue.main.async { [weak self] in self?.open(row: row) }
    }

    @objc private func remakeClicked(_ sender: NSButton) {
        let row = sender.tag
        DispatchQueue.main.async { [weak self] in self?.remake(row: row) }
    }

    @objc private func refreshClicked() {
        DispatchQueue.main.async { [weak self] in self?.refreshOrCancel() }
    }

    @objc private func includePreviousClicked(_ sender: NSButton) {
        let on = sender.state == .on
        DispatchQueue.main.async { [weak self] in self?.setIncludePrevious(on) }
    }
}
