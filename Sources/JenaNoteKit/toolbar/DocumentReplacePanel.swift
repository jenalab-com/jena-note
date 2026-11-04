import AppKit

/// 입력창의 실행 취소가 입력창이 아니라 문서로 가야 바꾸기를 되돌릴 수 있다.
private final class DocumentReplaceField: NSSearchField, NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? { window?.undoManager }
}

/// 헤더 검색창이 아래로 펼쳐진 부분. 위쪽은 헤더에 붙고 아래쪽 모서리만 둥글다.
final class DocumentReplacePanel: NSView, NSSearchFieldDelegate {
    static let padding: CGFloat = 8
    /// 세로 여백을 좁혀 박스가 본문 첫 줄에 닿지 않게 한다.
    private static let verticalPadding: CGFloat = 4

    var onReplace: ((String) -> Void)?
    var onReplaceAll: ((String) -> Void)?
    var onClose: (() -> Void)?

    let field: NSSearchField = DocumentReplaceField()
    private lazy var replaceButton = NSButton(title: L10n.tr("find.replace"), target: self, action: #selector(replace))
    private lazy var replaceAllButton = NSButton(title: L10n.tr("find.replaceAll"), target: self, action: #selector(replaceAll))

    /// 입력창은 헤더 검색창과 같은 크기로 맞춘다. 헤더의 컨트롤 크기는 OS마다 다르다.
    init(matching findField: NSSearchField) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.15
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        field.controlSize = findField.controlSize
        field.font = findField.font
        field.placeholderString = L10n.tr("find.replacePlaceholder")
        field.toolTip = L10n.tr("find.replacePlaceholder")
        field.delegate = self
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.image =
            NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        field.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [field, replaceButton, replaceAllButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: findField.frame.width),
            field.heightAnchor.constraint(equalToConstant: findField.frame.height),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override var wantsUpdateLayer: Bool { true }

    /// 어두운 화면으로 바뀌어도 색이 따라오도록 여기서 칠한다.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    func focus() { window?.makeFirstResponder(field) }

    func setHasMatches(_ hasMatches: Bool) {
        replaceButton.isEnabled = hasMatches
        replaceAllButton.isEnabled = hasMatches
    }

    /// 조합 중인 한글은 아직 입력창 값에 확정되지 않았다.
    private var replacementText: String {
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
            editor.unmarkText()
            editor.inputContext?.discardMarkedText()
        }
        return field.stringValue
    }

    @objc private func replace() { onReplace?(replacementText) }
    @objc private func replaceAll() { onReplaceAll?(replacementText) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if replaceButton.isEnabled { replace() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
