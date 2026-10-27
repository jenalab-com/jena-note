import AppKit

enum AIWorkContextStatus: Equatable {
    case none                                   // not part of a work (no context.json)
    case disabled
    case corrupt
    case active(settingsCount: Int, contextBytes: Int, summariesReady: Int, summariesTotal: Int,
                previousEpisode: Bool, outsideWriting: Bool, budget: AIPromptBudget)
    case generating(done: Int, total: Int)
}

/// One-line, clickable work context status under the document name in the AI panel (spec §7.1).
final class AIWorkContextBar: NSView {
    var onClick: (() -> Void)?
    private(set) var status: AIWorkContextStatus = .none
    private let button = NSButton(title: "", target: nil, action: nil)

    var displayedText: String { button.attributedTitle.string }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.alignment = .left
        button.imagePosition = .noImage
        button.lineBreakMode = .byTruncatingTail
        button.cell?.lineBreakMode = .byTruncatingTail
        button.target = self
        button.action = #selector(clicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        update(.none)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ status: AIWorkContextStatus) {
        self.status = status
        let text = Self.text(for: status)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: Self.color(for: status),
            .paragraphStyle: paragraph
        ])
        button.toolTip = text
        button.setAccessibilityLabel(text)
    }

    @objc private func clicked() { onClick?() }

    // MARK: - Pure formatting

    static func text(for status: AIWorkContextStatus) -> String {
        switch status {
        case .none:
            return L10n.tr("ai.work.none") + " · " + L10n.tr("ai.work.setup")
        case .disabled:
            return L10n.tr("ai.work.disabled")
        case .corrupt:
            return L10n.tr("ai.work.corrupt")
        case .generating(let done, let total):
            return String(format: L10n.tr("ai.work.generating"), done, total)
        case let .active(settingsCount, contextBytes, ready, total, previousEpisode, outsideWriting, budget):
            let summaries = ready >= total
                ? String(format: L10n.tr("ai.work.summaries"), total)
                : String(format: L10n.tr("ai.work.summariesPartial"), ready, total)
            let bytes = formatBytes(contextBytes)
            // `ai.work.active` is "<head> · <summaries> · <previous>". Segments that do not apply
            // (no earlier episodes, no previous episode, outside the writing folder) are dropped, so
            // the format is split on " · " and the applicable parts are joined back.
            let format = L10n.tr("ai.work.active")
            let parts = format.components(separatedBy: " · ")
            guard parts.count == 3 else {
                var text = String(format: format, settingsCount, bytes, summaries, L10n.tr("ai.work.previousEpisode"))
                if budget == .over { text += " · " + L10n.tr("ai.work.overBudget") }
                return text
            }
            var segments = [String(format: parts[0], settingsCount, bytes)]
            if outsideWriting {
                segments.append(L10n.tr("ai.work.outsideWriting"))
            } else {
                if total > 0 { segments.append(String(format: parts[1], summaries)) }
                if previousEpisode { segments.append(String(format: parts[2], L10n.tr("ai.work.previousEpisode"))) }
            }
            if budget == .over { segments.append(L10n.tr("ai.work.overBudget")) }
            return segments.joined(separator: " · ")
        }
    }

    static func color(for status: AIWorkContextStatus) -> NSColor {
        switch status {
        case .corrupt:
            return .systemRed
        case .active(_, _, _, _, _, _, let budget):
            switch budget {
            case .ok: return .secondaryLabelColor
            case .warning: return .systemOrange
            case .over: return .systemRed
            }
        case .none, .disabled, .generating:
            return .secondaryLabelColor
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
