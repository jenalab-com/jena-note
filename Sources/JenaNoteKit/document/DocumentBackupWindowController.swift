import AppKit

final class DocumentBackupWindowController: NSWindowController {
    private weak var documentToRestore: MarkdownDocument?
    private let picker = JenaPopUpButton(frame: .zero, pullsDown: false)
    private let preview = NSTextView()
    private let comparisonView = DocumentHistoryComparisonView()
    private let previewScroll = NSScrollView()
    private let restore = SettingsButton(title: L10n.tr("backup.restore"), target: nil, action: nil, primary: true)
    private let compare = NSSwitch()
    private var entries: [DocumentBackupStore.Snapshot] = []

    init(document: MarkdownDocument) {
        self.documentToRestore = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 780, height: 500)
        window.isReleasedWhenClosed = false
        window.title = L10n.tr("backup.title") + " · " + document.displayName
        super.init(window: window)
        SettingsText.applyToolWindowChrome(window)
        let content = window.contentView!

        // 제목 — 어느 문서의 백업인지 바로 보이게
        let heading = SettingsText.heading(L10n.tr("backup.title"))
        let documentName = SettingsText.section(document.displayName)
        let hint = SettingsText.note(L10n.tr("backup.hint"))

        // 버전 고르기 + 비교 스위치
        picker.target = self; picker.action = #selector(selectionChanged)
        picker.isFilled = true
        picker.font = .systemFont(ofSize: 13)
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        compare.target = self; compare.action = #selector(selectionChanged)
        compare.setAccessibilityLabel(L10n.tr("history.compare"))
        let compareLabel = NSTextField(labelWithString: L10n.tr("history.compare"))
        compareLabel.font = .systemFont(ofSize: 13)
        let chooser = NSStackView(views: [picker, compareLabel, compare])
        chooser.spacing = 10
        chooser.alignment = .centerY
        chooser.setCustomSpacing(18, after: picker)

        // 미리보기 / 비교 — 둥근 카드 안
        preview.isEditable = false; preview.isRichText = false
        preview.font = .systemFont(ofSize: 13)
        preview.drawsBackground = false
        preview.textContainerInset = NSSize(width: 12, height: 12)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        let scroll = previewScroll
        scroll.drawsBackground = false
        let body = NSView()
        for view in [scroll, comparisonView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                view.topAnchor.constraint(equalTo: body.topAnchor),
                view.bottomAnchor.constraint(equalTo: body.bottomAnchor)
            ])
        }
        comparisonView.isHidden = true
        scroll.documentView = preview; scroll.hasVerticalScroller = true
        let panel = SettingsPanelView(content: body)

        // 동작 — 만들기·새로고침은 왼쪽, 되돌리기(주 동작)는 오른쪽
        restore.target = self; restore.action = #selector(restoreSelected)
        let create = SettingsButton(title: L10n.tr("history.create"), target: self, action: #selector(createVersion))
        let refresh = SettingsButton(title: L10n.tr("history.refresh"), target: self, action: #selector(reload))
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let actions = NSStackView(views: [create, refresh, spacer, restore])
        actions.spacing = 8

        let titleRow = NSStackView(views: [heading, documentName])
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 10
        let stack = NSStackView(views: [titleRow, hint, chooser, panel, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.setCustomSpacing(6, after: titleRow)
        stack.setCustomSpacing(16, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsStyle.contentInset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -SettingsStyle.contentInset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -SettingsStyle.contentInset),
            panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        for item in [hint, chooser, panel, actions] as [NSView] { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        reload()
    }
    @objc private func reload() {
        guard let document = documentToRestore else { return }
        do {
            entries = []
            picker.removeAllItems()
            if let url = document.fileURL { entries = try document.backupStore.snapshots(for: url) }
            let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .medium
            for entry in entries {
                picker.addItem(withTitle: formatter.string(from: entry.createdAt) + (entry.name.map { " · " + $0 } ?? ""))
            }
            selectionChanged()
        } catch { restore.isEnabled = false; document.presentError(error) }
    }
    @objc private func createVersion() {
        guard let document = documentToRestore, let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("history.create")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = L10n.tr("history.name")
        alert.accessoryView = input
        alert.addButton(withTitle: L10n.tr("history.create"))
        alert.addButton(withTitle: L10n.tr("confirm.cancel"))
        alert.beginSheetModal(for: window) { [weak self, weak document] result in
            guard result == .alertFirstButtonReturn, let document else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            do { try document.createNamedVersion(String(name.prefix(120))); self?.reload() }
            catch { document.presentError(error) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selectionChanged() {
        let index = picker.indexOfSelectedItem
        let valid = entries.indices.contains(index)
        preview.string = valid ? (String(data: entries[index].data, encoding: .utf8) ?? L10n.tr("backup.invalid")) : L10n.tr("backup.empty")
        comparisonView.isHidden = true
        previewScroll.isHidden = false
        if valid, compare.state == .on, let document = documentToRestore {
            do {
                let data = try document.data(ofType: document.fileType ?? "net.daringfireball.markdown")
                guard let current = String(data: data, encoding: .utf8),
                      let previous = String(data: entries[index].data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                if let rows = DocumentHistoryDiff.rows(previous: previous, current: current) {
                    comparisonView.isHidden = false
                    previewScroll.isHidden = true
                    comparisonView.show(rows: rows, version: picker.titleOfSelectedItem ?? "")
                } else { preview.string = L10n.tr("history.tooLarge") }
            } catch { preview.string = error.localizedDescription }
        }
        restore.isEnabled = valid && String(data: entries[index].data, encoding: .utf8) != nil
    }
    @objc private func restoreSelected() {
        guard let document = documentToRestore, entries.indices.contains(picker.indexOfSelectedItem), let window else { return }
        let snapshot = entries[picker.indexOfSelectedItem]
        let alert = NSAlert()
        alert.messageText = L10n.tr("backup.confirm")
        alert.informativeText = L10n.tr("backup.confirmHint")
        alert.addButton(withTitle: L10n.tr("backup.restore")); alert.addButton(withTitle: L10n.tr("confirm.cancel"))
        alert.beginSheetModal(for: window) { [weak self, weak document] result in
            guard result == .alertFirstButtonReturn, let document else { return }
            do { try document.restoreBackup(snapshot); self?.close() }
            catch { document.presentError(error) }
        }
    }
}
