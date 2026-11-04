import AppKit

/// 헤더의 문서 내 찾기 입력창. 글자를 치면 바로 찾고 Enter로 일치를 오간다.
final class DocumentFindField: NSSearchField, NSSearchFieldDelegate {
    static let width: CGFloat = 180

    var onQueryChange: ((String) -> Void)?
    var onMove: ((_ forward: Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let countLabel = NSTextField(labelWithString: "")
    private var lastQuery = ""

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 26))
        placeholderString = L10n.tr("toolbar.find")
        toolTip = L10n.tr("toolbar.find")
        sendsSearchStringImmediately = true
        sendsWholeSearchString = false
        delegate = self
        target = self
        action = #selector(queryChanged)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    func showCount(current: Int?, total: Int) {
        countLabel.stringValue = stringValue.isEmpty ? "" : "\(current.map { $0 + 1 } ?? 0)/\(total)"
    }

    func reset() {
        stringValue = ""
        queryChanged()
    }

    func controlTextDidChange(_ note: Notification) { queryChanged() }

    @objc private func queryChanged() {
        guard stringValue != lastQuery else { return }
        lastQuery = stringValue
        onQueryChange?(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onMove?(NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}
