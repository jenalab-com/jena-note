import AppKit

enum AIWorkContextStatus: Equatable {
    case unavailable(reason: UnavailableReason)
    case disabled
    case corrupt
    case active(settingsCount: Int, summariesReady: Int, summariesTotal: Int,
                outsideWriting: Bool, contextBytes: Int, budget: AIPromptBudget)
    case generating(done: Int, total: Int)

    enum UnavailableReason: Equatable { case notInWork, unsavedDocument }
}

/// Everything the row shows for one status (spec §7.1), kept pure so it can be tested without a view.
struct AIWorkContextBarAppearance: Equatable {
    let dotColor: NSColor
    let text: String
    /// Numbers appended to the sentence in the secondary color.
    let detail: String?
    let buttonTitle: String
    let buttonEnabled: Bool
    /// nil = no fill (white row); warning rows use a pale yellow.
    let background: NSColor?
    let tooltip: String?
}

/// Clickable work context row under the document name in the AI panel (spec §7.1):
/// status dot · sentence (+ secondary numbers) · small button. The whole row acts like the button.
final class AIWorkContextBar: NSView {
    var onPrimaryAction: (() -> Void)?
    private(set) var status: AIWorkContextStatus = .unavailable(reason: .notInWork)
    private(set) var currentAppearance: AIWorkContextBarAppearance

    let button = NSButton(title: "", target: nil, action: nil)
    private let dot = NSView()
    private let textLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    var displayedText: String {
        [textLabel.stringValue, detailLabel.stringValue].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    override init(frame frameRect: NSRect) {
        currentAppearance = Self.appearance(for: .unavailable(reason: .notInWork))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        textLabel.font = .systemFont(ofSize: 12)
        textLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(10), for: .horizontal)

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.target = self
        button.action = #selector(performPrimaryAction)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let texts = NSStackView(views: [textLabel, detailLabel])
        texts.orientation = .horizontal
        texts.spacing = 6
        texts.alignment = .firstBaseline
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [dot, texts, button])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(performPrimaryAction)))
        apply(currentAppearance)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(currentAppearance)
    }

    func update(_ status: AIWorkContextStatus) {
        self.status = status
        currentAppearance = Self.appearance(for: status)
        apply(currentAppearance)
    }

    private func apply(_ appearance: AIWorkContextBarAppearance) {
        textLabel.stringValue = appearance.text
        detailLabel.stringValue = appearance.detail ?? ""
        detailLabel.isHidden = appearance.detail == nil
        button.title = appearance.buttonTitle
        button.isEnabled = appearance.buttonEnabled
        button.toolTip = appearance.tooltip
        toolTip = appearance.tooltip
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = appearance.dotColor.cgColor
            layer?.backgroundColor = (appearance.background ?? NSColor.controlBackgroundColor).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        setAccessibilityLabel(displayedText)
    }

    @objc private func performPrimaryAction() {
        // Row clicks honour the button's enabled state (e.g. unsaved document).
        guard currentAppearance.buttonEnabled else { return }
        onPrimaryAction?()
    }

    // MARK: - Pure formatting

    static func appearance(for status: AIWorkContextStatus) -> AIWorkContextBarAppearance {
        let settingsButton = L10n.tr("ai.work.row.settingsButton")
        switch status {
        case .unavailable(.notInWork):
            return AIWorkContextBarAppearance(dotColor: .systemGray, text: L10n.tr("ai.work.row.off"), detail: nil,
                                              buttonTitle: settingsButton, buttonEnabled: true,
                                              background: nil, tooltip: nil)
        case .unavailable(.unsavedDocument):
            return AIWorkContextBarAppearance(dotColor: .systemGray, text: L10n.tr("ai.work.row.off"), detail: nil,
                                              buttonTitle: settingsButton, buttonEnabled: false,
                                              background: nil, tooltip: L10n.tr("ai.work.row.saveFirst"))
        case .disabled:
            return AIWorkContextBarAppearance(dotColor: .systemGray, text: L10n.tr("ai.work.row.disabled"), detail: nil,
                                              buttonTitle: L10n.tr("ai.work.row.enableButton"), buttonEnabled: true,
                                              background: nil, tooltip: nil)
        case .corrupt:
            return AIWorkContextBarAppearance(dotColor: .systemRed, text: L10n.tr("ai.work.row.corrupt"), detail: nil,
                                              buttonTitle: L10n.tr("ai.work.row.resetButton"), buttonEnabled: true,
                                              background: nil, tooltip: nil)
        case let .generating(done, total):
            return AIWorkContextBarAppearance(
                dotColor: .systemBlue, text: String(format: L10n.tr("ai.work.row.generating"), done, total), detail: nil,
                buttonTitle: L10n.tr("ai.work.row.cancelButton"), buttonEnabled: true, background: nil, tooltip: nil)
        case let .active(settingsCount, ready, total, outsideWriting, contextBytes, budget):
            let pale = NSColor.systemYellow.withAlphaComponent(0.15)
            let used = formatBytes(contextBytes)
            let limit = formatBytes(AIPrompt.maximumBytes)
            switch budget {
            case .over:
                return AIWorkContextBarAppearance(
                    dotColor: .systemOrange, text: L10n.tr("ai.work.row.overLimit"),
                    detail: String(format: L10n.tr("ai.work.budget"), used, limit),
                    buttonTitle: settingsButton, buttonEnabled: true, background: pale, tooltip: nil)
            case .warning:
                return AIWorkContextBarAppearance(
                    dotColor: .systemOrange, text: L10n.tr("ai.work.row.on"),
                    detail: String(format: L10n.tr("ai.work.row.nearLimit"), used, limit),
                    buttonTitle: settingsButton, buttonEnabled: true, background: pale, tooltip: nil)
            case .ok:
                let episodes: String
                if outsideWriting || total == 0 {
                    episodes = L10n.tr("ai.work.row.noEpisodes")
                } else if ready >= total {
                    episodes = String(format: L10n.tr("ai.work.row.episodes"), total)
                } else {
                    episodes = String(format: L10n.tr("ai.work.row.episodesPartial"), ready, total)
                }
                let detail = String(format: L10n.tr("ai.work.row.settings"), settingsCount) + " · " + episodes
                return AIWorkContextBarAppearance(
                    dotColor: .systemGreen, text: L10n.tr("ai.work.row.on"), detail: detail,
                    buttonTitle: settingsButton, buttonEnabled: true, background: nil, tooltip: nil)
            }
        }
    }

    /// 1000-based. Under 1 MB: whole kilobytes, rounded ("182KB", 999 → "1KB"); otherwise one decimal ("1.2MB").
    static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1fMB", Double(bytes) / 1_000_000)
        }
        return "\(Int((Double(bytes) / 1000).rounded()))KB"
    }
}
