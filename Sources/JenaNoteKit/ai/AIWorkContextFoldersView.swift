import AppKit

/// ③ "작품 폴더" tab (spec §7.2): work root and writing folder (path + "바꾸기…" + preview),
/// title, validation errors and the "use work context" switch. Every accepted change goes
/// through `controller.mutate`; a writing folder outside the root is shown as an error and not saved.
final class AIWorkContextFoldersView: NSView, NSTextFieldDelegate {
    private weak var controller: AIWorkContextWindowController?

    let rootPathLabel = NSTextField(labelWithString: "")
    let rootPreviewLabel = NSTextField(labelWithString: "")
    let writingPathLabel = NSTextField(labelWithString: "")
    let writingPreviewLabel = NSTextField(labelWithString: "")
    let titleField = NSTextField(string: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let enableSwitch = NSSwitch()
    /// Visible next to the switch while there are no sources ("참고 자료를 먼저 추가하세요").
    let needsSourcesLabel = NSTextField(labelWithString: L10n.tr("ai.work.folders.needsSources"))

    /// Error from the last rejected choice; cleared by the next accepted change.
    private var rejection: [AIWorkContextValidationError] = []
    private var rejectionMessages: [String] = []
    private var rejectedDraft: AIWorkContextModel.FoldersDraft?

    init(controller: AIWorkContextWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func build() {
        for label in [rootPathLabel, writingPathLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        for label in [rootPreviewLabel, writingPreviewLabel] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleField.delegate = self
        enableSwitch.target = self
        enableSwitch.action = #selector(enableToggled)

        let rootChange = NSButton(title: L10n.tr("ai.work.folders.change"), target: self, action: #selector(chooseRootClicked))
        let writingChange = NSButton(title: L10n.tr("ai.work.folders.change"), target: self, action: #selector(chooseWritingClicked))
        for button in [rootChange, writingChange] { button.bezelStyle = .rounded }

        let enableLabel = NSTextField(labelWithString: L10n.tr("ai.work.folders.enable"))
        needsSourcesLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        needsSourcesLabel.textColor = .secondaryLabelColor
        needsSourcesLabel.isHidden = true
        let enableRow = NSStackView(views: [enableSwitch, enableLabel, needsSourcesLabel])
        enableRow.spacing = 8
        enableRow.alignment = .centerY

        let stack = NSStackView(views: [
            row(L10n.tr("ai.work.folders.root"), rootPathLabel, rootChange),
            indented(rootPreviewLabel),
            row(L10n.tr("ai.work.folders.writing"), writingPathLabel, writingChange),
            indented(writingPreviewLabel),
            row(L10n.tr("ai.work.folders.title"), titleField, nil),
            errorLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[3])
        stack.translatesAutoresizingMaskIntoConstraints = false
        enableRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(enableRow)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: enableRow.topAnchor, constant: -12),
            enableRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            enableRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    private static let labelWidth: CGFloat = 80

    private func row(_ title: String, _ main: NSView, _ trailing: NSView?) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        let views = [label, main] + (trailing.map { [$0] } ?? [])
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func indented(_ view: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        let stack = NSStackView(views: [spacer, view])
        stack.spacing = 8
        return stack
    }

    // MARK: - Render

    func render(_ draft: AIWorkContextModel.FoldersDraft, enabled: Bool) {
        // A rejected choice keeps showing what was picked and why, until the next accepted change.
        let shown = rejectedDraft ?? draft
        rootPathLabel.stringValue = shown.rootURL.path
        writingPathLabel.stringValue = shown.writingFolder.path
        rootPreviewLabel.stringValue = Self.previewText(shown.rootURL)
        writingPreviewLabel.stringValue = Self.previewText(shown.writingFolder)
        if titleField.currentEditor() == nil, titleField.stringValue != draft.title {
            titleField.stringValue = draft.title
        }
        var messages = (draft.errors + rejection).map { Self.message(for: $0, draft: shown) } + rejectionMessages
        if let saveError = controller?.lastSaveError { messages.append(saveError) }
        errorLabel.stringValue = messages.joined(separator: "\n")
        errorLabel.isHidden = messages.isEmpty
        enableSwitch.state = enabled ? .on : .off
        // No sources → the context cannot be on (`normalizeEnabled` invariant).
        let hasSources = !(controller?.context.config.settingsSources.isEmpty ?? true)
        enableSwitch.isEnabled = hasSources
        enableSwitch.toolTip = hasSources ? nil : L10n.tr("ai.work.folders.needsSources")
        needsSourcesLabel.isHidden = hasSources
    }

    /// Error text wraps at the content width instead of clipping at the window's minimum width.
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 40)
        if errorLabel.preferredMaxLayoutWidth != width { errorLabel.preferredMaxLayoutWidth = width }
    }

    private static let previewLimit = 5

    /// "안에: a, b, c" — "…" only when the folder holds more than `previewLimit` entries.
    static func previewText(_ url: URL) -> String {
        let names = AIWorkContextModel.folderPreview(url, limit: previewLimit + 1)
        guard !names.isEmpty else { return "" }
        let more = names.count > previewLimit
        let shown = names.prefix(previewLimit).joined(separator: ", ") + (more ? "…" : "")
        return String(format: L10n.tr("ai.work.folders.preview"), shown)
    }

    private static func message(for error: AIWorkContextValidationError, draft: AIWorkContextModel.FoldersDraft) -> String {
        switch error {
        case .noSettingsSources: return L10n.tr("ai.work.errorNoSettings")
        case .settingsIsRoot: return L10n.tr("ai.work.errorSourceIsRoot")
        case .settingsOutsideRoot(let path): return String(format: L10n.tr("ai.work.errorOutsideRoot"), path)
        case .writingFolderOutsideRoot:
            return String(format: L10n.tr("ai.work.errorOutsideRoot"), draft.writingFolder.path)
        }
    }

    // MARK: - Changes (internal for tests)

    func chooseRoot(_ url: URL) {
        guard let controller = controller else { return }
        let current = AIWorkContextModel.foldersDraft(from: controller.context)
        let draft = AIWorkContextModel.FoldersDraft(rootURL: url, writingFolder: current.writingFolder, title: current.title)
        guard draft.errors.isEmpty else { return reject(draft) }
        guard !controller.rootHasOtherContext(url) else {
            return reject(draft, messages: [L10n.tr("ai.work.folders.errorRootHasContext")])
        }
        clearRejection()
        controller.changeRoot(to: url)
    }

    func chooseWritingFolder(_ url: URL) {
        guard let controller = controller else { return }
        let current = AIWorkContextModel.foldersDraft(from: controller.context)
        let draft = AIWorkContextModel.FoldersDraft(rootURL: current.rootURL, writingFolder: url, title: current.title)
        guard draft.errors.isEmpty else { return reject(draft) }
        clearRejection()
        let relative = AIWorkContext.relativePath(of: url, to: current.rootURL) ?? ""
        controller.mutate { $0.writingFolder = relative }
    }

    /// Commits the title field's text while it is still being edited (window closing).
    func commitPendingTitle() {
        guard titleField.currentEditor() != nil else { return }
        commitTitle(titleField.stringValue)
    }

    func commitTitle(_ text: String) {
        guard let controller = controller else { return }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            titleField.stringValue = controller.context.config.title
            return
        }
        guard title != controller.context.config.title else { return }
        controller.mutate { $0.title = title }
    }

    func setEnabled(_ on: Bool) {
        controller?.mutate { config in
            config.disabledByUser = !on
            config.enabled = on && !config.settingsSources.isEmpty
        }
    }

    private func reject(_ draft: AIWorkContextModel.FoldersDraft, messages: [String] = []) {
        rejectedDraft = draft
        rejection = draft.errors
        rejectionMessages = messages
        guard let controller = controller else { return }
        render(AIWorkContextModel.foldersDraft(from: controller.context), enabled: controller.context.config.enabled)
    }

    private func clearRejection() {
        rejectedDraft = nil
        rejection = []
        rejectionMessages = []
    }

    // MARK: - Actions

    @objc private func chooseRootClicked() {
        guard let controller = controller else { return }
        if let url = pickFolder(start: controller.context.rootURL) { chooseRoot(url) }
    }

    @objc private func chooseWritingClicked() {
        guard let controller = controller else { return }
        if let url = pickFolder(start: controller.context.writingFolderURL ?? controller.context.rootURL) {
            chooseWritingFolder(url)
        }
    }

    @objc private func enableToggled() { setEnabled(enableSwitch.state == .on) }

    private func pickFolder(start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField else { return }
        commitTitle(titleField.stringValue)
    }
}
