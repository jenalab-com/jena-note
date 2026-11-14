import AppKit

/// Compact composer footer. Unknown quotas stay unknown, never a synthetic 0%.
final class AIChatOptionsView: NSStackView {
    let usageStatusLabel = NSTextField(labelWithString: "")
    /// 아래 줄의 세션 한도 막대
    let sessionBar = AIQuotaBarView()
    /// 모델 선택 오른쪽 — 마지막 요청이 모델 컨텍스트를 얼마나 채웠는지
    let contextPie = AIContextPieView()
    /// 사용량 창 안의 한도별 막대 목록
    private let quotaRows = NSStackView()
    let usageStatusBar = NSStackView()
    let usageReloadButton = NSButton()
    private var countdownTimer: Timer?
    let modelPicker: NSPopUpButton = JenaPopUpButton(frame: .zero, pullsDown: false)
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
        sessionBar.isHidden = true
        usageStatusBar.addArrangedSubview(sessionBar)
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
        modelPicker.target = self
        modelPicker.action = #selector(modelChanged)
        (modelPicker.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        modelPicker.setAccessibilityLabel(L10n.tr("ai.model"))
        modelPicker.toolTip = L10n.tr("ai.modelHint")
        // 남는 폭으로 늘어나지 않게 — 빈자리는 보내기 버튼 앞 spacer 가 먹는다.
        modelPicker.setContentHuggingPriority(.defaultHigh, for: .horizontal)
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
        addArrangedSubview(contextPie)
        refreshButton = NSButton(title: L10n.tr("ai.refreshUsage"), target: self, action: #selector(refresh))
        refreshButton.controlSize = .small
        refreshButton.font = .systemFont(ofSize: 11)
        for text in [sessionLabel, usageLabel] {
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
        }
        quotaRows.orientation = .vertical
        quotaRows.alignment = .leading
        quotaRows.spacing = 8
        let details = NSStackView(views: [sessionLabel, usageLabel, quotaRows, refreshButton])
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        addArrangedSubview(spacer)
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

    /// 컨텍스트 파이 — 아직 요청 전이거나 크기를 모르는 AI 면 숨긴다.
    func setContext(_ usage: AIContextUsage?) {
        contextPie.usage = usage
        contextPie.isHidden = usage == nil
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
            case .codex, .grok, .local: break
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
        updateQuotaGraphs()
        if metadata.usageAvailable {
            usageLabel.stringValue = L10n.tr("ai.accountUsage")
            // 아래 줄: 세션 한도 막대 + "9% · 4h 12m". 세션 한도가 없으면 첫 한도를 쓴다.
            let primary = metadata.quotas.first { $0.title.hasPrefix(L10n.tr("ai.quotaSession")) } ?? metadata.quotas.first
            usageStatusLabel.stringValue = primary.map {
                String(format: "%.0f%%", $0.usedPercent) + " · " + ($0.modelName ?? $0.resetCountdown())
            } ?? ""
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
        sessionBar.toolTip = usageLabel.toolTip
    }

    /// 한도 그래프 — 아래 줄에는 세션 한도 하나, 사용량 창에는 모든 한도를 막대로.
    private func updateQuotaGraphs() {
        quotaRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let quotas = (!isRefreshing && metadata.usageAvailable) ? metadata.quotas : []
        let primary = quotas.first { $0.title.hasPrefix(L10n.tr("ai.quotaSession")) } ?? quotas.first
        sessionBar.isHidden = primary == nil
        sessionBar.label = primary.map { $0.title.hasPrefix(L10n.tr("ai.quotaSession")) ? L10n.tr("ai.quotaSessionShort") : ($0.modelName ?? $0.title) } ?? ""
        sessionBar.fraction = (primary?.usedPercent ?? 0) / 100
        for quota in quotas {
            let title = NSTextField(labelWithString: quota.title)
            title.font = .systemFont(ofSize: 11, weight: .medium)
            let bar = AIQuotaBarView()
            bar.trackWidth = 160
            bar.fraction = quota.usedPercent / 100
            let value = NSTextField(labelWithString: String(format: "%.0f%%", quota.usedPercent)
                + (quota.resetsAt == nil ? "" : " · " + L10n.tr("ai.resetsAt") + " " + quota.resetCountdown()))
            value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            value.textColor = .secondaryLabelColor
            let line = NSStackView(views: [bar, value])
            line.spacing = 8
            let row = NSStackView(views: [title, line])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 3
            quotaRows.addArrangedSubview(row)
        }
        quotaRows.isHidden = quotas.isEmpty
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

/// 한도 사용률 막대 — 가는 트랙 위에 사용한 만큼 채운다. 80% 넘으면 주황, 95% 넘으면 빨강.
final class AIQuotaBarView: NSView {
    /// 막대 앞에 붙는 짧은 이름 (아래 줄에서만, 예: "세션")
    var label = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var fraction: Double = 0 { didSet { needsDisplay = true; setAccessibilityValue(String(format: "%.0f%%", fraction * 100)) } }
    var trackWidth: CGFloat = 48 { didSet { invalidateIntrinsicContentSize() } }
    private let barHeight: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
    }
    private var labelWidth: CGFloat { label.isEmpty ? 0 : ceil((label as NSString).size(withAttributes: labelAttributes).width) + 5 }

    override var intrinsicContentSize: NSSize { NSSize(width: labelWidth + trackWidth, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        if !label.isEmpty {
            let size = (label as NSString).size(withAttributes: labelAttributes)
            (label as NSString).draw(at: NSPoint(x: 0, y: (bounds.height - size.height) / 2), withAttributes: labelAttributes)
        }
        let track = NSRect(x: labelWidth, y: (bounds.height - barHeight) / 2, width: trackWidth, height: barHeight)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        let clamped = max(0, min(1, fraction))
        guard clamped > 0 else { return }
        var fill = track
        fill.size.width = max(barHeight, track.width * clamped)
        let color: NSColor = clamped >= 0.95 ? .systemRed : clamped >= 0.8 ? .systemOrange : .labelColor
        color.withAlphaComponent(clamped >= 0.8 ? 1 : 0.7).setFill()
        NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }
}

/// 컨텍스트 사용률 파이 — 원 테두리 안을 사용한 만큼 부채꼴로 채운다. 80% 넘으면 주황, 95% 넘으면 빨강.
final class AIContextPieView: NSView {
    var usage: AIContextUsage? {
        didSet {
            needsDisplay = true
            guard let usage else { toolTip = nil; return }
            let percent = String(format: "%.0f%%", usage.fraction * 100)
            toolTip = L10n.tr("ai.context") + " " + percent + " · "
                + AIContextUsage.compact(usage.used) + " / " + AIContextUsage.compact(usage.window) + "\n" + L10n.tr("ai.contextHint")
            setAccessibilityValue(percent)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(L10n.tr("ai.context"))
        isHidden = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height) - 2
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        NSColor.tertiaryLabelColor.setStroke()
        ring.lineWidth = 1
        ring.stroke()
        guard let usage, usage.fraction > 0 else { return }
        let fraction = usage.fraction
        let color: NSColor = fraction >= 0.95 ? .systemRed : fraction >= 0.8 ? .systemOrange : .secondaryLabelColor
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let wedge = NSBezierPath()
        wedge.move(to: center)
        // 12시 방향에서 시계 방향으로 채운다.
        wedge.appendArc(withCenter: center, radius: side / 2 - 2, startAngle: 90,
                        endAngle: 90 - CGFloat(fraction) * 360, clockwise: true)
        wedge.close()
        color.setFill()
        wedge.fill()
    }
}
