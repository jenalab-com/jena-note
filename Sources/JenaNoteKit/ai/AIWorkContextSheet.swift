import AppKit

/// Setup sheet for a work context (작품 문맥): root, settings sources, writing folder, title.
final class AIWorkContextSheetController: NSWindowController {

    /// Pure state model; all validation goes through `AIWorkContext.validate`.
    struct Draft: Equatable {
        var rootURL: URL
        var settingsSources: [URL]
        var writingFolder: URL
        var title: String
        /// Existing config whose non-editable fields are preserved by `makeConfig()`.
        var base: AIWorkContextConfig?

        var errors: [AIWorkContextValidationError] {
            AIWorkContext.validate(rootURL: rootURL, settingsSources: settingsSources, writingFolder: writingFolder)
        }
        var canSave: Bool { errors.isEmpty }

        /// URLs become paths relative to the root; URLs outside the root are dropped.
        func makeConfig() -> AIWorkContextConfig {
            var config = base ?? AIWorkContextConfig(title: title, settingsSources: [], writingFolder: "")
            config.title = title
            config.settingsSources = settingsSources.compactMap { AIWorkContext.relativePath(of: $0, to: rootURL) }
            config.writingFolder = AIWorkContext.relativePath(of: writingFolder, to: rootURL) ?? ""
            return config
        }
    }

    static func draft(fileURL: URL, existing: AIWorkContext?) -> Draft {
        if let existing = existing {
            return Draft(rootURL: existing.rootURL, settingsSources: existing.settingsSourceURLs,
                         writingFolder: existing.writingFolderURL, title: existing.config.title,
                         base: existing.config)
        }
        let suggestion = AIWorkContextSuggestion.make(for: fileURL)
        return Draft(rootURL: suggestion.rootURL,
                     settingsSources: suggestion.settingsSourceURL.map { [$0] } ?? [],
                     writingFolder: suggestion.writingFolderURL, title: suggestion.title, base: nil)
    }

    var onSave: ((AIWorkContext) -> Void)?

    private var draft: Draft
    private let rootLabel = NSTextField(labelWithString: "")
    private let writingLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField(string: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    private let saveButton = NSButton(title: "", target: nil, action: nil)

    init(fileURL: URL, existing: AIWorkContext?) {
        draft = Self.draft(fileURL: fileURL, existing: existing)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.title = L10n.tr("ai.work.sheetTitle")
        super.init(window: window)
        buildUI(in: window)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on window: NSWindow) {
        guard let sheet = self.window else { return }
        window.beginSheet(sheet, completionHandler: nil)
    }

    // MARK: - UI

    private func buildUI(in window: NSWindow) {
        for label in [rootLabel, writingLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.lineBreakMode = .byWordWrapping

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        titleField.delegate = self

        let chooseRoot = button("ai.work.choose", #selector(chooseRoot))
        let chooseWriting = button("ai.work.choose", #selector(chooseWritingFolder))
        let addFolder = button("ai.work.addFolder", #selector(addFolder))
        let addFile = button("ai.work.addFile", #selector(addFiles))
        removeButton.title = L10n.tr("ai.work.remove")
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        let cancel = button("ai.work.cancel", #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.title = L10n.tr("ai.work.save")
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"

        let sourceButtons = NSStackView(views: [addFolder, addFile, removeButton])
        sourceButtons.spacing = 8
        let footer = NSStackView(views: [NSView(), cancel, saveButton])
        footer.spacing = 8

        let stack = NSStackView(views: [
            header("ai.work.root"), row(rootLabel, chooseRoot),
            header("ai.work.settingsSources"), scroll, sourceButtons,
            header("ai.work.writingFolder"), row(writingLabel, chooseWriting),
            header("ai.work.title"), titleField,
            errorLabel, footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: sourceButtons)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
        ]
        for view in [scroll, titleField, errorLabel, footer] as [NSView] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40))
        }
        for view in stack.arrangedSubviews where view is NSStackView && view !== sourceButtons && view !== footer {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func header(_ key: String) -> NSTextField {
        let label = NSTextField(labelWithString: L10n.tr(key))
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    private func button(_ key: String, _ action: Selector) -> NSButton {
        NSButton(title: L10n.tr(key), target: self, action: action)
    }

    private func row(_ label: NSTextField, _ button: NSButton) -> NSStackView {
        let row = NSStackView(views: [label, button])
        row.spacing = 8
        return row
    }

    // MARK: - State

    private func reload() {
        rootLabel.stringValue = draft.rootURL.path
        writingLabel.stringValue = draft.writingFolder.path
        if titleField.stringValue != draft.title { titleField.stringValue = draft.title }
        table.reloadData()
        refreshValidation()
    }

    private func refreshValidation() {
        errorLabel.stringValue = draft.errors.map { error -> String in
            switch error {
            case .noSettingsSources: return L10n.tr("ai.work.errorNoSettings")
            case .settingsOutsideRoot(let path): return String(format: L10n.tr("ai.work.errorOutsideRoot"), path)
            case .writingFolderOutsideRoot:
                return String(format: L10n.tr("ai.work.errorOutsideRoot"), draft.writingFolder.path)
            }
        }.joined(separator: "\n")
        saveButton.isEnabled = draft.canSave
        removeButton.isEnabled = table.selectedRow >= 0
    }

    private func openPanel(directories: Bool, multiple: Bool, start: URL) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = multiple
        panel.directoryURL = start
        panel.prompt = L10n.tr("ai.work.choose")
        return panel.runModal() == .OK ? panel.urls : []
    }

    // MARK: - Actions

    @objc private func chooseRoot() {
        guard let url = openPanel(directories: true, multiple: false, start: draft.rootURL).first else { return }
        draft.rootURL = url
        reload()
    }

    @objc private func chooseWritingFolder() {
        guard let url = openPanel(directories: true, multiple: false, start: draft.writingFolder).first else { return }
        draft.writingFolder = url
        reload()
    }

    @objc private func addFolder() { addSources(openPanel(directories: true, multiple: true, start: draft.rootURL)) }
    @objc private func addFiles() { addSources(openPanel(directories: false, multiple: true, start: draft.rootURL)) }

    private func addSources(_ urls: [URL]) {
        for url in urls where !draft.settingsSources.contains(url) { draft.settingsSources.append(url) }
        reload()
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard draft.settingsSources.indices.contains(row) else { return }
        draft.settingsSources.remove(at: row)
        reload()
    }

    @objc private func cancelTapped() { endSheet() }

    @objc private func saveTapped() {
        draft.title = titleField.stringValue
        guard draft.canSave else { return }
        let context = AIWorkContext(rootURL: draft.rootURL, config: draft.makeConfig(), invalidPaths: [])
        endSheet()
        onSave?(context)
    }

    private func endSheet() {
        guard let sheet = window else { return }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
    }
}

extension AIWorkContextSheetController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { draft.settingsSources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = draft.settingsSources[row]
        let label = NSTextField(labelWithString: AIWorkContext.relativePath(of: url, to: draft.rootURL) ?? url.path)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshValidation() }
}

extension AIWorkContextSheetController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { draft.title = titleField.stringValue }
}
