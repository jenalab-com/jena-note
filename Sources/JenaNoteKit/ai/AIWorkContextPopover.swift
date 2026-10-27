import AppKit

/// Work context popover (spec §7.2), opened from the AI panel's work context bar when a work is set.
///
/// Layout, top to bottom: header (title · "include work context" switch · "change settings…") →
/// budget bar (settings / summaries / previous episode against `AIPrompt.maximumBytes`) → settings
/// files (include checkbox · path · size · summarize switch) → earlier-episode summaries (path ·
/// state · open · regenerate, "refresh all" above) → "include previous episode" switch.
///
/// The lists are plain `NSStackView` rows inside a height-capped scroll view rather than an
/// `NSTableView`: a work has at most a few dozen settings/episodes and rows hold mixed controls.
///
/// Every toggle is saved to `context.json` immediately and then reported through `onChange`; the
/// parent re-resolves the work and hands the fresh result back through `reload(_:)`.
final class AIWorkContextPopoverController: NSViewController {
    struct SettingRow: Equatable {
        let file: AIWorkFile
        var included: Bool
        var summarized: Bool
        let unreadable: Bool
    }

    struct EpisodeRow: Equatable {
        let file: AIWorkFile
        let state: AISummaryState
    }

    /// Called after `context.json` was saved or a summary run finished → parent refreshes and reloads.
    var onChange: (() -> Void)?
    var onOpenSheet: (() -> Void)?
    /// Popover width; the parent sets it to the panel width.
    var preferredWidth: CGFloat = 340

    private(set) var resolved: AIResolvedWorkContext
    private let store: AIEpisodeSummaryStore
    private let provider: AIProvider
    private let model: String?

    private let stack = NSStackView()
    private var settingRowsShown: [SettingRow] = []
    private var episodeRowsShown: [EpisodeRow] = []
    /// Last save/generation error; survives rebuilds until the next action.
    private var errorMessage: String?

    private static let listMaxHeight: CGFloat = 180

    init(resolved: AIResolvedWorkContext, store: AIEpisodeSummaryStore, provider: AIProvider, model: String?) {
        self.resolved = resolved
        self.store = store
        self.provider = provider
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        rebuild()
    }

    /// Replaces the shown work with a freshly resolved one (after a save or a summary run).
    func reload(_ resolved: AIResolvedWorkContext) {
        self.resolved = resolved
        if isViewLoaded { rebuild() }
    }

    // MARK: - Pure logic

    /// Every settings file the sources yield — included, excluded and unreadable — in natural path order.
    static func settingRows(_ resolved: AIResolvedWorkContext) -> [SettingRow] {
        let config = resolved.context.config
        let excluded = Set(config.excludedSettings)
        let summarized = Set(config.summarizedSettings)
        let unreadable = Set(resolved.unreadable.map(\.relativePath))
        let all = AIWorkContextResolver.naturalSort(resolved.settings + resolved.unreadable + resolved.excludedSettings)
        return all.map { file in
            SettingRow(file: file, included: !excluded.contains(file.relativePath),
                       summarized: summarized.contains(file.relativePath),
                       unreadable: unreadable.contains(file.relativePath))
        }
    }

    static func episodeRows(_ resolved: AIResolvedWorkContext, store: AIEpisodeSummaryStore) -> [EpisodeRow] {
        resolved.previousEpisodes.map { EpisodeRow(file: $0, state: store.state(of: $0, isSetting: false)) }
    }

    static func stateText(_ state: AISummaryState) -> String {
        switch state {
        case .ready: return L10n.tr("ai.work.stateReady")
        case .missing: return L10n.tr("ai.work.stateMissing")
        case .stale: return L10n.tr("ai.work.stateStale")
        case .manuallyEdited(let sourceChanged):
            return L10n.tr(sourceChanged ? "ai.work.stateManualSourceChanged" : "ai.work.stateManual")
        }
    }

    /// Unchecking a settings file adds it to `excludedSettings`; checking it again removes it.
    static func toggleIncluded(_ config: inout AIWorkContextConfig, path: String) {
        if let index = config.excludedSettings.firstIndex(of: path) {
            config.excludedSettings.remove(at: index)
        } else {
            config.excludedSettings.append(path)
        }
    }

    static func toggleSummarized(_ config: inout AIWorkContextConfig, path: String) {
        if let index = config.summarizedSettings.firstIndex(of: path) {
            config.summarizedSettings.remove(at: index)
        } else {
            config.summarizedSettings.append(path)
        }
    }

    /// UTF-8 bytes per budget segment; the three add up to `payload.contextByteCount`.
    static func budgetSegments(_ payload: AIWorkPayload) -> (settings: Int, summaries: Int, previous: Int) {
        (payload.settings.reduce(0) { $0 + $1.text.utf8.count },
         payload.previousSummaries.reduce(0) { $0 + $1.summary.utf8.count },
         payload.previousEpisode?.text.utf8.count ?? 0)
    }

    // MARK: - Actions

    /// Opens the episode summary `.txt` in its own window, or brings it forward if already open.
    func openSummary(_ file: AIWorkFile) {
        let url = store.summaryURL(for: file, isSetting: false)
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let open = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }.first {
            $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == target
        }
        if let window = open?.windowControllers.first?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
            guard let self = self, let error = error else { return }
            self.errorMessage = error.localizedDescription
            self.rebuild()
        }
    }

    private func mutateConfig(_ change: (inout AIWorkContextConfig) -> Void) {
        var context = resolved.context
        change(&context.config)
        do {
            try context.save()
            errorMessage = nil
        } catch {
            errorMessage = String(format: L10n.tr("ai.work.saveFailed"), error.localizedDescription)
            rebuild() // controls snap back to the saved state
            return
        }
        notifyChanged()
    }

    private func notifyChanged() {
        if let onChange = onChange { onChange() } else { rebuild() }
    }

    @objc private func enabledToggled(_ sender: NSSwitch) {
        let on = sender.state == .on
        mutateConfig { $0.enabled = on }
    }

    @objc private func previousToggled(_ sender: NSSwitch) {
        let on = sender.state == .on
        mutateConfig { $0.includePreviousEpisode = on }
    }

    @objc private func includeToggled(_ sender: NSButton) {
        guard settingRowsShown.indices.contains(sender.tag) else { return }
        let path = settingRowsShown[sender.tag].file.relativePath
        mutateConfig { Self.toggleIncluded(&$0, path: path) }
    }

    @objc private func summarizeToggled(_ sender: NSSwitch) {
        guard settingRowsShown.indices.contains(sender.tag) else { return }
        let path = settingRowsShown[sender.tag].file.relativePath
        mutateConfig { Self.toggleSummarized(&$0, path: path) }
    }

    @objc private func changeSettingsClicked(_ sender: Any?) { onOpenSheet?() }

    @objc private func openClicked(_ sender: NSButton) {
        guard episodeRowsShown.indices.contains(sender.tag) else { return }
        openSummary(episodeRowsShown[sender.tag].file)
    }

    @objc private func regenerateClicked(_ sender: NSButton) {
        guard episodeRowsShown.indices.contains(sender.tag), !store.isGenerating else { return }
        let row = episodeRowsShown[sender.tag]
        if case .manuallyEdited = row.state {
            let alert = NSAlert()
            alert.messageText = L10n.tr("ai.work.regenerateConfirm")
            alert.addButton(withTitle: L10n.tr("ai.work.regenerate"))
            alert.addButton(withTitle: L10n.tr("ai.work.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        errorMessage = nil
        store.regenerate(row.file, isSetting: false, provider: provider, model: model) { [weak self] result in
            self?.generationFinished(result)
        }
        rebuild() // isGenerating → lists disabled
    }

    @objc private func refreshAllClicked(_ sender: Any?) {
        guard !store.isGenerating else { return }
        errorMessage = nil
        // "모두 갱신" regenerates only missing/stale summaries (spec §7.2, §6.3): `prepare` skips
        // ready and manually edited ones, so hand-edited summaries are never overwritten here —
        // "다시 생성" on a row is the explicit way to replace one. Summarized settings are included.
        let summarized = AIWorkContextAssembler(resolved: resolved, store: store).summarizedSettings
        store.prepare(episodes: resolved.previousEpisodes, settings: summarized, provider: provider, model: model,
                      progress: { [weak self] _, _ in self?.rebuild() },
                      completion: { [weak self] result in self?.generationFinished(result) })
        rebuild()
    }

    private func generationFinished(_ result: Result<Int, Error>) {
        if case .failure(let error) = result {
            if let failure = error as? AISummaryGenerationError {
                errorMessage = String(format: L10n.tr("ai.work.summaryFailed"), failure.file.relativePath,
                                      failure.underlying.localizedDescription)
            } else {
                errorMessage = error.localizedDescription
            }
        }
        notifyChanged()
    }

    // MARK: - Building

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let generating = store.isGenerating
        let config = resolved.context.config
        let contentWidth = preferredWidth - stack.edgeInsets.left - stack.edgeInsets.right

        // 1. Header
        let title = NSTextField(labelWithString: config.title)
        title.font = .boldSystemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let change = NSButton(title: L10n.tr("ai.work.changeSettings"), target: self,
                              action: #selector(changeSettingsClicked(_:)))
        change.bezelStyle = .rounded
        change.controlSize = .small
        add(row([title, spacer(), change]), width: contentWidth)
        add(switchRow(L10n.tr("ai.work.include"), on: config.enabled, action: #selector(enabledToggled(_:))),
            width: contentWidth)

        // 2. Budget
        let payload = AIWorkContextAssembler(resolved: resolved, store: store)
            .payload(currentFile: resolved.context.rootURL).payload
        let segments = Self.budgetSegments(payload)
        let bar = AIWorkBudgetBarView(segments: segments, maximum: AIPrompt.maximumBytes)
        let budget = small(String(format: L10n.tr("ai.work.budget"),
                                  AIWorkContextBar.formatBytes(payload.contextByteCount),
                                  AIWorkContextBar.formatBytes(AIPrompt.maximumBytes)))
        budget.setContentCompressionResistancePriority(.required, for: .horizontal)
        add(row([bar, budget]), width: contentWidth)

        if generating {
            let label = small(L10n.tr("ai.work.generatingElsewhere"))
            label.textColor = .systemOrange
            add(label, width: contentWidth)
        }

        // 3. Settings files
        add(section(L10n.tr("ai.work.settingsSection")), width: contentWidth)
        settingRowsShown = Self.settingRows(resolved)
        let settingViews = settingRowsShown.enumerated().map { settingRowView($1, tag: $0, enabled: !generating) }
        if !settingViews.isEmpty { add(list(settingViews), width: contentWidth) }

        // 4. Earlier episode summaries
        episodeRowsShown = Self.episodeRows(resolved, store: store)
        let refresh = NSButton(title: L10n.tr("ai.work.refreshAll"), target: self,
                               action: #selector(refreshAllClicked(_:)))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        refresh.isEnabled = !generating && !episodeRowsShown.isEmpty
        add(row([section(L10n.tr("ai.work.summariesSection")), spacer(), refresh]), width: contentWidth)
        let episodeViews = episodeRowsShown.enumerated().map { episodeRowView($1, tag: $0, enabled: !generating) }
        if !episodeViews.isEmpty { add(list(episodeViews), width: contentWidth) }

        // 5. Previous episode
        add(switchRow(L10n.tr("ai.work.includePrevious"), on: config.includePreviousEpisode,
                      action: #selector(previousToggled(_:))), width: contentWidth)

        if let message = errorMessage {
            let label = NSTextField(wrappingLabelWithString: message)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .systemRed
            label.preferredMaxLayoutWidth = contentWidth
            add(label, width: contentWidth)
        }

        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: preferredWidth, height: stack.fittingSize.height)
    }

    private func settingRowView(_ item: SettingRow, tag: Int, enabled: Bool) -> NSView {
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(includeToggled(_:)))
        check.tag = tag
        check.state = item.included ? .on : .off
        check.isEnabled = enabled && !item.unreadable
        check.setAccessibilityLabel(item.file.relativePath)

        var views: [NSView] = [check]
        if item.unreadable, let image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                                accessibilityDescription: L10n.tr("ai.work.unreadable")) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .systemOrange
            icon.toolTip = L10n.tr("ai.work.unreadable")
            views.append(icon)
        }
        let path = pathLabel(item.file.relativePath)
        let size = small(AIWorkContextBar.formatBytes(item.file.byteCount))
        if item.unreadable {
            path.textColor = .tertiaryLabelColor
            size.textColor = .tertiaryLabelColor
        }
        views += [path, spacer(), size]

        let toggle = NSSwitch()
        toggle.controlSize = .mini
        toggle.tag = tag
        toggle.state = item.summarized ? .on : .off
        toggle.target = self
        toggle.action = #selector(summarizeToggled(_:))
        toggle.isEnabled = enabled && item.included && !item.unreadable
        toggle.setAccessibilityLabel(L10n.tr("ai.work.summarize") + " " + item.file.relativePath)
        views += [small(L10n.tr("ai.work.summarize")), toggle]

        let row = self.row(views)
        row.toolTip = item.unreadable ? L10n.tr("ai.work.unreadable") : item.file.relativePath
        return row
    }

    private func episodeRowView(_ item: EpisodeRow, tag: Int, enabled: Bool) -> NSView {
        let state = small(Self.stateText(item.state))
        switch item.state {
        case .missing, .stale: state.textColor = .systemOrange
        case .ready, .manuallyEdited: break
        }
        let open = NSButton(title: L10n.tr("ai.work.open"), target: self, action: #selector(openClicked(_:)))
        open.tag = tag
        open.bezelStyle = .rounded
        open.controlSize = .mini
        open.isEnabled = enabled && FileManager.default.fileExists(atPath: store.summaryURL(for: item.file, isSetting: false).path)
        let regenerate = NSButton(title: L10n.tr("ai.work.regenerate"), target: self,
                                  action: #selector(regenerateClicked(_:)))
        regenerate.tag = tag
        regenerate.bezelStyle = .rounded
        regenerate.controlSize = .mini
        regenerate.isEnabled = enabled
        let row = self.row([pathLabel(item.file.relativePath), spacer(), state, open, regenerate])
        row.toolTip = item.file.relativePath
        return row
    }

    // MARK: - View helpers

    private func add(_ view: NSView, width: CGFloat) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func switchRow(_ title: String, on: Bool, action: Selector) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        toggle.target = self
        toggle.action = action
        toggle.setAccessibilityLabel(title)
        return row([NSTextField(labelWithString: title), spacer(), toggle])
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func small(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func pathLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// Rows in a vertical stack, scrolled once taller than `listMaxHeight`.
    private func list(_ rows: [NSView]) -> NSView {
        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        rows.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        let document = AIWorkFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        let height = min(content.fittingSize.height, Self.listMaxHeight)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }
}

private final class AIWorkFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Three-segment budget bar: settings (blue), summaries (teal), previous episode (gray),
/// each proportional to `maximum` over the full width.
final class AIWorkBudgetBarView: NSView {
    private let parts: [(bytes: Int, view: NSView)]
    private let maximum: Int

    init(segments: (settings: Int, summaries: Int, previous: Int), maximum: Int) {
        self.maximum = max(maximum, 1)
        parts = [(segments.settings, NSColor.systemBlue), (segments.summaries, .systemTeal),
                 (segments.previous, .systemGray)].map { bytes, color in
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = color.cgColor
            return (bytes, view)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        parts.forEach { addSubview($0.view) }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 6).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for part in parts {
            let width = min(bounds.width * CGFloat(part.bytes) / CGFloat(maximum), bounds.width - x)
            part.view.frame = NSRect(x: x, y: 0, width: max(width, 0), height: bounds.height)
            x += max(width, 0)
        }
    }
}
