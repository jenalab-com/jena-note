import AppKit

/// 부호 설정 탭. 작가마다 쓰는 부호와 진입 방식이 달라 값을 전부 작가에게 맡긴다.
final class PunctuationSettingsViewController: NSViewController, NSTextFieldDelegate {
    private struct Row {
        let kind: PunctuationKind
        let opening = NSTextField()
        let closing = NSTextField()
        let spaces = JenaPopUpButton(frame: .zero, pullsDown: false)
        let trigger = NSTextField()
    }

    private let rows = PunctuationKind.allCases.map { Row(kind: $0) }
    private let triggersCheckbox = NSSwitch()
    private let returnCheckbox = NSSwitch()
    private let shiftPopup = JenaPopUpButton(frame: .zero, pullsDown: false)

    override func loadView() {
        let settings = SettingsManager.shared
        let header = [L10n.tr("punctuation.opening"), L10n.tr("punctuation.closing"),
                      L10n.tr("punctuation.leadingSpaces"), L10n.tr("punctuation.trigger")]
            .map { title -> NSTextField in
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 11, weight: .medium)
                label.textColor = .secondaryLabelColor
                return label
            }
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
            row.spaces.isFilled = true
            row.spaces.font = .systemFont(ofSize: 13)
            row.spaces.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let name = NSTextField(labelWithString: row.kind.shortTitle)
            name.font = .systemFont(ofSize: 13)
            gridRows.append([name, SettingsFieldContainer(row.opening, width: 64), SettingsFieldContainer(row.closing, width: 64),
                             row.spaces, SettingsFieldContainer(row.trigger, width: 72)])
        }
        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.rowAlignment = .none
        grid.yPlacement = .center
        grid.column(at: 0).width = 56

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
        shiftPopup.isFilled = true
        shiftPopup.font = .systemFont(ofSize: 13)
        shiftPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        triggersCheckbox.setAccessibilityLabel(L10n.tr("punctuation.triggersEnabled"))
        returnCheckbox.setAccessibilityLabel(L10n.tr("punctuation.closesOnReturn"))

        let page = SettingsPageView(title: L10n.tr("settings.tab.punctuation"))
        // 표는 자기 크기만큼만 — 남는 폭은 오른쪽 빈자리가 먹어 칸 간격이 고르게 유지된다.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        grid.setContentHuggingPriority(.required, for: .horizontal)
        let gridLine = NSStackView(views: [grid, spacer])
        gridLine.distribution = .fill
        page.addSection(L10n.tr("punctuation.section.marks"), card: SettingsCard(rows: [SettingsRow(content: gridLine)]),
                        footnote: L10n.tr("punctuation.closingHint"))
        page.addSection(L10n.tr("punctuation.section.input"), card: SettingsCard(rows: [
            SettingsRow(title: L10n.tr("punctuation.triggersEnabled"), detail: L10n.tr("punctuation.triggerHint"),
                        control: triggersCheckbox),
            SettingsRow(title: L10n.tr("punctuation.doubleShift"), control: shiftPopup),
            SettingsRow(title: L10n.tr("punctuation.closesOnReturn"), control: returnCheckbox)
        ]))
        view = page
    }

    private func configure(_ field: NSTextField, value: String, label: String) {
        field.stringValue = value
        field.delegate = self
        field.setAccessibilityLabel(label)
        field.alignment = .center
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
