import AppKit

/// Compact composer footer. Unknown quotas stay unknown, never a synthetic 0%.
final class AIChatOptionsView: NSStackView, NSComboBoxDelegate {
    let modelPicker = NSComboBox()
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
        orientation = .vertical
        alignment = .leading
        spacing = 5
        let label = NSTextField(labelWithString: L10n.tr("ai.model"))
        label.font = .systemFont(ofSize: 11)
        modelPicker.font = .systemFont(ofSize: 11)
        modelPicker.controlSize = .small
        modelPicker.isEditable = true
        modelPicker.completes = false
        modelPicker.delegate = self
        modelPicker.setAccessibilityLabel(L10n.tr("ai.model"))
        modelPicker.toolTip = L10n.tr("ai.modelHint")
        modelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton = NSButton(title: L10n.tr("ai.refreshUsage"), target: self, action: #selector(refresh))
        refreshButton.controlSize = .small
        refreshButton.font = .systemFont(ofSize: 11)
        let row = NSStackView(views: [label, modelPicker, refreshButton])
        row.orientation = .horizontal
        row.spacing = 5
        addArrangedSubview(row)
        for text in [sessionLabel, usageLabel] {
            text.font = .systemFont(ofSize: 10)
            text.textColor = .secondaryLabelColor
            addArrangedSubview(text)
        }
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        usageLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { client?.cancel() }

    var selectedModel: String {
        let value = modelPicker.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == L10n.tr("ai.defaultModel") ? "" : value
    }

    func configure(provider: AIProvider, tokens: Int?) {
        sessionLabel.toolTip = L10n.tr("ai.conversationTokensHint")
        sessionLabel.stringValue = L10n.tr("ai.conversationTokens") + ": " + (tokens.map { "\($0)" } ?? "—")
        let key = provider.rawValue + ":" + (AISettings.executable(for: provider)?.path ?? "")
        guard identity != key else { return }
        self.provider = provider
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

    func suspend() { generation = UUID(); client?.cancel(); client = nil; identity = "" }

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
        modelPicker.addItems(withObjectValues: [L10n.tr("ai.defaultModel")] + ids)
        modelPicker.stringValue = current.isEmpty ? L10n.tr("ai.defaultModel") : current
    }

    private func updateUsage() {
        refreshButton.isEnabled = !isRefreshing
        if isRefreshing { usageLabel.stringValue = L10n.tr("ai.loadingUsage"); return }
        if metadata.usageAvailable {
            usageLabel.stringValue = L10n.tr("ai.accountUsage") + ": " + metadata.quotas.map(\.summary).joined(separator: " · ")
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            usageLabel.toolTip = metadata.quotas.map { quota in
                quota.summary + (quota.resetsAt.map { " · " + L10n.tr("ai.resetsAt") + " " + formatter.string(from: $0) } ?? "")
            }.joined(separator: "\n")
        } else {
            usageLabel.stringValue = L10n.tr(usageError ? "ai.metadataUnavailable" : "ai.quotaUnavailable")
            usageLabel.toolTip = provider == .gemini ? L10n.tr("ai.geminiQuotaHint") : L10n.tr("ai.quotaHint")
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The field editor can lag the selection notification.
        if let value = modelPicker.objectValueOfSelectedItem as? String { modelPicker.stringValue = value }
        AISettings.setModel(selectedModel, for: provider)
    }
    func controlTextDidChange(_ notification: Notification) { AISettings.setModel(selectedModel, for: provider) }
}
