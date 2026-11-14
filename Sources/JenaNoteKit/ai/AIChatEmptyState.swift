import AppKit

/// 대화를 시작하기 전 AI 패널 — 비어 있는 대신 무엇을 할 수 있는지 보여준다.
/// 예시를 누르면 입력창에 채워진다(바로 보내지는 않는다).
final class AIChatEmptyStateView: NSView {
    var onPick: ((String) -> Void)?
    private(set) var exampleButtons: [NSButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .light)) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: L10n.tr("ai.empty.title"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor

        let stack = NSStackView(views: [icon, title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: title)

        for key in ["ai.empty.example1", "ai.empty.example2", "ai.empty.example3"] {
            let button = AIChatExampleButton(title: L10n.tr(key), target: self, action: #selector(picked(_:)))
            exampleButtons.append(button)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let hint = NSTextField(wrappingLabelWithString: L10n.tr("ai.empty.skillHint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.setCustomSpacing(14, after: exampleButtons.last ?? title)
        stack.addArrangedSubview(hint)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func picked(_ sender: NSButton) { onPick?(sender.title) }
}

/// 예시 한 줄 — 옅은 둥근 바탕(사이드바 pill 비율), 마우스를 올리면 조금 진하게.
final class AIChatExampleButton: NSButton {
    private var isHovering = false { didSet { needsDisplay = true } }

    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["exampleHover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["exampleHover": true]))
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func draw(_ dirtyRect: NSRect) {
        (isHovering ? HeaderStyle.onFill : SidebarStyle.trackFill).setFill()
        HeaderStyle.pill(bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        text.draw(in: NSRect(x: 10, y: (bounds.height - size.height) / 2, width: bounds.width - 20, height: size.height))
    }
}
