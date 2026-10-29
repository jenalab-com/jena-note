import AppKit

final class DocumentBackupWindowController: NSWindowController {
    private weak var documentToRestore: MarkdownDocument?
    private let picker = NSPopUpButton()
    private let preview = NSTextView()
    private let comparisonView = DocumentHistoryComparisonView()
    private let previewScroll = NSScrollView()
    private let restore = NSButton()
    private let compare = NSButton(checkboxWithTitle: L10n.tr("history.compare"), target: nil, action: nil)
    private var entries: [DocumentBackupStore.Snapshot] = []

    init(document: MarkdownDocument) {
        self.documentToRestore = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 780, height: 500)
        window.isReleasedWhenClosed = false
        window.title = L10n.tr("backup.title") + " · " + document.displayName
        super.init(window: window)
        let hint = NSTextField(wrappingLabelWithString: L10n.tr("backup.hint"))
        hint.textColor = .secondaryLabelColor
        picker.target = self; picker.action = #selector(selectionChanged)
        preview.isEditable = false; preview.isRichText = false
        preview.font = .systemFont(ofSize: 13)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        let scroll = previewScroll
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
        restore.title = L10n.tr("backup.restore")
        restore.target = self; restore.action = #selector(restoreSelected)
        compare.target = self; compare.action = #selector(selectionChanged)
        let create = NSButton(title: L10n.tr("history.create"), target: self, action: #selector(createVersion))
        let refresh = NSButton(title: L10n.tr("history.refresh"), target: self, action: #selector(reload))
        let actions = NSStackView(views: [create, restore, refresh])
        let stack = NSStackView(views: [hint, picker, compare, body, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        for item in [hint, picker, body] { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
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
