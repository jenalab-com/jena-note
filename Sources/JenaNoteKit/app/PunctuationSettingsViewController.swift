import AppKit

/// 부호 설정 탭. 작가마다 쓰는 부호와 진입 방식이 달라 값을 전부 작가에게 맡긴다.
final class PunctuationSettingsViewController: NSViewController, NSTextFieldDelegate {
    private struct Row {
        let kind: PunctuationKind
        let opening = NSTextField()
        let closing = NSTextField()
        let spaces = NSPopUpButton()
        let trigger = NSTextField()
    }

    private let rows = PunctuationKind.allCases.map { Row(kind: $0) }
    private let triggersCheckbox = NSButton(checkboxWithTitle: L10n.tr("punctuation.triggersEnabled"), target: nil, action: nil)
    private let returnCheckbox = NSButton(checkboxWithTitle: L10n.tr("punctuation.closesOnReturn"), target: nil, action: nil)
    private let shiftPopup = NSPopUpButton()

    override func loadView() {
        view = NSView()
        let settings = SettingsManager.shared
        let header = [L10n.tr("punctuation.opening"), L10n.tr("punctuation.closing"),
                      L10n.tr("punctuation.leadingSpaces"), L10n.tr("punctuation.trigger")]
            .map { NSTextField(labelWithString: $0) }
        var gridRows: [[NSView]] = [[NSGridCell.emptyContentView] + header]
        for row in rows {
            let style = settings.punctuationStyle(for: row.kind)
            configure(row.opening, value: style.opening, label: "\(row.kind.menuTitle) \(L10n.tr("punctuation.opening"))")
            configure(row.closing, value: style.closing, label: "\(row.kind.menuTitle) \(L10n.tr("punctuation.closing"))")
            configure(row.trigger, value: style.trigger, label: "\(row.kind.menuTitle) \(L10n.tr("punctuation.trigger"))")
            row.spaces.addItems(withTitles: PunctuationStyle.leadingSpacesRange.map(String.init))
            row.spaces.selectItem(at: style.leadingSpaces)
            row.spaces.setAccessibilityLabel("\(row.kind.menuTitle) \(L10n.tr("punctuation.leadingSpaces"))")
            row.spaces.target = self
            row.spaces.action = #selector(styleChanged)
            gridRows.append([NSTextField(labelWithString: row.kind.shortTitle), row.opening, row.closing, row.spaces, row.trigger])
        }
        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).width = 72

        triggersCheckbox.state = settings.punctuationTriggersEnabled ? .on : .off
        triggersCheckbox.target = self
        triggersCheckbox.action = #selector(triggersChanged)
        returnCheckbox.state = settings.punctuationClosesOnReturn ? .on : .off
        returnCheckbox.target = self
        returnCheckbox.action = #selector(returnChanged)

        shiftPopup.addItem(withTitle: L10n.tr("punctuation.off"))
        for kind in PunctuationKind.allCases {
            shiftPopup.addItem(withTitle: kind.shortTitle)
            shiftPopup.lastItem?.representedObject = kind.rawValue
        }
        let target = settings.punctuationShiftTarget
        shiftPopup.selectItem(at: target.flatMap { PunctuationKind.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        shiftPopup.target = self
        shiftPopup.action = #selector(shiftChanged)
        let shiftRow = NSStackView(views: [NSTextField(labelWithString: L10n.tr("punctuation.doubleShift")), shiftPopup])
        shiftRow.spacing = 12

        let stack = NSStackView(views: [grid, hint("punctuation.closingHint"), triggersCheckbox,
                                        hint("punctuation.triggerHint"), shiftRow, returnCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func configure(_ field: NSTextField, value: String, label: String) {
        field.stringValue = value
        field.delegate = self
        field.setAccessibilityLabel(label)
        field.widthAnchor.constraint(equalToConstant: 76).isActive = true
    }

    private func hint(_ key: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L10n.tr(key))
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return label
    }

    func controlTextDidChange(_ notification: Notification) { styleChanged() }

    @objc private func styleChanged() {
        for row in rows {
            SettingsManager.shared.setPunctuationStyle(
                PunctuationStyle(opening: row.opening.stringValue, closing: row.closing.stringValue,
                                 leadingSpaces: row.spaces.indexOfSelectedItem, trigger: row.trigger.stringValue),
                for: row.kind)
        }
    }

    @objc private func triggersChanged() {
        SettingsManager.shared.punctuationTriggersEnabled = triggersCheckbox.state == .on
    }

    @objc private func returnChanged() {
        SettingsManager.shared.punctuationClosesOnReturn = returnCheckbox.state == .on
    }

    @objc private func shiftChanged() {
        let raw = shiftPopup.selectedItem?.representedObject as? String
        SettingsManager.shared.punctuationShiftTarget = raw.flatMap(PunctuationKind.init(rawValue:))
    }
}
