import AppKit

/// Compact composer footer. Unknown quotas stay unknown, never a synthetic 0%.
final class AIChatOptionsView: NSStackView {
    let usageStatusLabel = NSTextField(labelWithString: "")
    let usageStatusBar = NSStackView()
    let usageReloadButton = NSButton()
    private var countdownTimer: Timer?
    let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let usagePopover = NSPopover()
    private let usageButton = NSButton()
    private let usageLabel = NSTextField(wrappingLabelWithString: "")
    private let sessionLabel = NSTextField(labelWithString: "")
    private var refreshButton: NSButton!
    private var provider: AIProvider = .claude
    private var identity = ""
    private var client: AIMetadataClient?
    private var generation = UUID()
    private var metadata = AIMetadata()
    private var isRefreshing = false
    private var usageError = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        usageStatusLabel.font = .systemFont(ofSize: 10)
        usageStatusLabel.textColor = .secondaryLabelColor
        usageStatusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        usageStatusLabel.lineBreakMode = .byTruncatingTail
        usageStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usageReloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L10n.tr("ai.refreshUsage"))
        usageReloadButton.isBordered = false
        usageReloadButton.controlSize = .small
        usageReloadButton.target = self
        usageReloadButton.action = #selector(refresh)
        usageReloadButton.toolTip = L10n.tr("ai.refreshUsage")
        usageReloadButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        usageReloadButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        usageStatusBar.distribution = .fill
        usageStatusBar.orientation = .horizontal
        usageStatusBar.alignment = .centerY
        usageStatusBar.spacing = 4
        usageStatusBar.addArrangedSubview(usageStatusLabel)
        usageStatusBar.addArrangedSubview(usageReloadButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        usageStatusBar.addArrangedSubview(spacer)
        orientation = .horizontal
        distribution = .fill
        alignment = .centerY
        spacing = 4
        modelPicker.font = .systemFont(ofSize: 11)
        modelPicker.controlSize = .small
        modelPicker.isBordered = false
        modelPicker.target = self
        modelPicker.action = #selector(modelChanged)
        (modelPicker.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        modelPicker.setAccessibilityLabel(L10n.tr("ai.model"))
        modelPicker.toolTip = L10n.tr("ai.modelHint")
        modelPicker.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        modelPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        usageButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: L10n.tr("ai.accountUsage"))
        usageButton.isBordered = false
        usageButton.target = self
        usageButton.action = #selector(showUsage)
        usageButton.toolTip = L10n.tr("ai.accountUsage")
        usageButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        addArrangedSubview(usageButton)
        addArrangedSubview(modelPicker)
        refreshButton = NSButton(title: L10n.tr("ai.refreshUsage"), target: self, action: #selector(refresh))
        refreshButton.controlSize = .small
        refreshButton.font = .systemFont(ofSize: 11)
        for text in [sessionLabel, usageLabel] {
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
        }
        let details = NSStackView(views: [sessionLabel, usageLabel, refreshButton])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 10
        details.translatesAutoresizingMaskIntoConstraints = false
        let content = NSViewController()
        content.view = NSView()
        content.view.addSubview(details)
        NSLayoutConstraint.activate([
            details.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 14),
            details.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -14),
            details.topAnchor.constraint(equalTo: content.view.topAnchor, constant: 14),
            details.bottomAnchor.constraint(equalTo: content.view.bottomAnchor, constant: -14),
            usageLabel.widthAnchor.constraint(equalToConstant: 250)
        ])
        usagePopover.contentViewController = content
        usagePopover.behavior = .transient
    }

    func install(modeControl: NSView, actionButton: NSView) {
        insertArrangedSubview(modeControl, at: 0)
        addArrangedSubview(actionButton)
    }

    @objc private func showUsage() {
        if let content = usagePopover.contentViewController {
            content.view.layoutSubtreeIfNeeded()
            usagePopover.contentSize = NSSize(width: 278, height: max(120, content.view.fittingSize.height))
        }
        usagePopover.show(relativeTo: usageButton.bounds, of: usageButton, preferredEdge: .maxY)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { client?.cancel(); countdownTimer?.invalidate() }

    var selectedModel: String { AISettings.model(for: provider) }

    func configure(provider: AIProvider, tokens: Int?) {
        if countdownTimer == nil {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.updateUsage()
            }
        }
        sessionLabel.toolTip = L10n.tr("ai.conversationTokensHint")
        sessionLabel.stringValue = L10n.tr("ai.conversationTokens") + ": " + (tokens.map { "\($0)" } ?? "—")
        let key = provider.rawValue + ":" + (AISettings.executable(for: provider)?.path ?? "")
        guard identity != key else { return }
        self.provider = provider
        modelPicker.toolTip = provider.title + " · " + L10n.tr("ai.modelHint")
        identity = key
        metadata = AIMetadata()
        updateModels()
        refresh()
    }

    func setBusy(_ busy: Bool) { modelPicker.isEnabled = !busy }

    @objc func refresh() {
        client?.cancel()
        let token = UUID()
        generation = token
        isRefreshing = true
        usageError = false
        updateUsage()
        let client = AIMetadataClient()
        self.client = client
        client.load(provider: provider) { [weak self] result in
            guard let self = self, self.generation == token else { return }
            self.client = nil
            self.isRefreshing = false
            switch result {
            case .success(let metadata): self.metadata = metadata
            case .failure: self.metadata = AIMetadata(); self.usageError = true
            }
            self.updateModels()
            self.updateUsage()
        }
    }

    func suspend() { countdownTimer?.invalidate(); countdownTimer = nil; usagePopover.close(); generation = UUID(); client?.cancel(); client = nil; identity = "" }

    private func updateModels() {
        let current = AISettings.model(for: provider)
        var ids = metadata.models.map(\.id)
        if ids.isEmpty {
            switch provider {
            case .claude: ids = ["opus", "sonnet", "haiku"]
            case .gemini: ids = ["gemini-3-pro-preview", "gemini-3-flash-preview", "gemini-2.5-pro", "gemini-2.5-flash"]
            case .codex, .grok: break
            }
        }
        if !current.isEmpty, !ids.contains(current) { ids.append(current) }
        modelPicker.removeAllItems()
        for (title, value) in [(L10n.tr("ai.defaultModel"), "")] + ids.map({ ($0, $0) }) {
            modelPicker.addItem(withTitle: title)
            modelPicker.lastItem?.representedObject = value
        }
        if let item = modelPicker.itemArray.first(where: { ($0.representedObject as? String) == current }) {
            modelPicker.select(item)
        }
        modelPicker.menu?.addItem(.separator())
        modelPicker.addItem(withTitle: L10n.tr("ai.composer.customModel"))
        modelPicker.toolTip = provider.title + " · " + (current.isEmpty ? L10n.tr("ai.defaultModel") : current)
    }

    private func updateUsage() {
        refreshButton.isEnabled = !isRefreshing
        usageReloadButton.isEnabled = !isRefreshing
        if isRefreshing {
            usageLabel.stringValue = L10n.tr("ai.loadingUsage")
            usageStatusLabel.stringValue = usageLabel.stringValue
            return
        }
        if metadata.usageAvailable {
            usageLabel.stringValue = L10n.tr("ai.accountUsage") + ": " + metadata.quotas.map(\.summary).joined(separator: " · ")
            usageStatusLabel.stringValue = metadata.quotas.map { $0.compactSummary() }.joined(separator: " · ")
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            usageLabel.toolTip = metadata.quotas.map { quota in
                quota.summary + (quota.resetsAt.map { " · " + L10n.tr("ai.resetsAt") + " " + formatter.string(from: $0) } ?? "")
            }.joined(separator: "\n")
        } else {
            usageLabel.stringValue = L10n.tr(usageError ? "ai.metadataUnavailable" : "ai.quotaUnavailable")
            usageStatusLabel.stringValue = usageLabel.stringValue
            usageLabel.toolTip = provider == .gemini ? L10n.tr("ai.geminiQuotaHint") : L10n.tr("ai.quotaHint")
        }
        usageStatusLabel.toolTip = usageLabel.toolTip
    }

    @objc private func modelChanged() {
        if let model = modelPicker.selectedItem?.representedObject as? String {
            AISettings.setModel(model, for: provider)
            updateModels()
            return
        }
        updateModels()
        guard let window else { return }
        let selectedProvider = provider
        let alert = NSAlert()
        alert.messageText = L10n.tr("ai.composer.customModel")
        alert.informativeText = L10n.tr("ai.modelHint")
        alert.addButton(withTitle: L10n.tr("ai.composer.apply"))
        alert.addButton(withTitle: L10n.tr("ai.work.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = AISettings.model(for: selectedProvider)
        field.setAccessibilityLabel(L10n.tr("ai.model"))
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.provider == selectedProvider else { return }
            AISettings.setModel(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), for: selectedProvider)
            self.updateModels()
        }
        alert.window.makeFirstResponder(field)
    }
}
