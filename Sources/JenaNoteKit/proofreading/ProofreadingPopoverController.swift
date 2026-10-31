import AppKit

final class ProofreadingPopoverController: NSViewController {
    private let item: ProofreadingSuggestion
    private let apply: () -> Void
    private let add: () -> Void
    init(item: ProofreadingSuggestion, apply: @escaping () -> Void, add: @escaping () -> Void) {
        self.item = item; self.apply = apply; self.add = add
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    override func loadView() {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for (title, value) in [(L10n.tr("proof.original"), item.original), (L10n.tr("proof.suggestion"), item.replacement)] {
            let label = NSTextField(labelWithString: title); label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(label)
            let text = NSTextField(wrappingLabelWithString: value)
            text.isSelectable = true; text.widthAnchor.constraint(equalToConstant: 300).isActive = true
            stack.addArrangedSubview(text)
        }
        let buttons = NSStackView(views: [NSButton(title: L10n.tr("proof.apply"), target: self, action: #selector(applyClicked(_:))), NSButton(title: L10n.tr("dictionary.add"), target: self, action: #selector(addClicked(_:)))])
        buttons.spacing = 10; stack.addArrangedSubview(buttons)
        stack.setFrameSize(NSSize(width: 324, height: stack.fittingSize.height))
        view = stack; preferredContentSize = stack.fittingSize
    }
    @objc private func applyClicked(_ sender: Any?) { apply() }
    @objc private func addClicked(_ sender: Any?) { add() }
}
