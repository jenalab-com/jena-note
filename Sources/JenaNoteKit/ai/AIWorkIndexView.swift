import AppKit

/// Work-wide preparation, independent of any one chat or CLI session.
final class AIWorkIndexView: NSView, AIWorkContextRenderable {
    private weak var controller: AIWorkContextWindowController?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let usage = NSTextField(labelWithString: "")
    private let retry = NSButton(title: L10n.tr("ai.index.retry"), target: nil, action: nil)
    private let stop = NSButton(title: L10n.tr("ai.stop"), target: nil, action: nil)
    private let files = NSTextView()

    init(controller: AIWorkContextWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        let hint = NSTextField(wrappingLabelWithString: L10n.tr("ai.index.automatic"))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        retry.target = self
        retry.action = #selector(prepare)
        stop.target = self
        stop.action = #selector(cancel)
        let actions = NSStackView(views: [retry, stop])
        let scroll = NSScrollView()
        files.isEditable = false
        files.isRichText = false
        files.font = .systemFont(ofSize: 12)
        files.textContainer?.widthTracksTextView = true
        files.autoresizingMask = [.width]
        files.isVerticallyResizable = true
        scroll.documentView = files
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [hint, status, usage, actions, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in [hint, status, usage, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AIWorkIndexStore.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func render(controller: AIWorkContextWindowController) {
        let store = AIWorkIndexStore.shared(for: controller.context.rootURL)
        status.stringValue = store.statusText
        usage.stringValue = String(format: L10n.tr("ai.index.localCounts"), store.summaryCount, store.excerptCount)
        let reasons = Set(store.index.passages.compactMap(\.summaryIssue)).sorted().map { L10n.tr($0) }.joined(separator: "\n")
        usage.toolTip = reasons.isEmpty ? nil : reasons
        status.toolTip = usage.toolTip
        retry.isEnabled = !controller.isProvisional && controller.context.config.enabled && !store.isRunning
        stop.isEnabled = store.isRunning
        guard let resolved = controller.resolved else { files.string = ""; return }
        let root = controller.context.rootURL
        let paths = resolved.previousEpisodes.compactMap { AIWorkContext.relativePath(of: $0.url, to: root) }
        files.string = paths.map { path in
            let chunks = store.index.passages.filter { $0.path == path && !$0.isSetting }
            let ready = chunks.filter { !$0.summary.isEmpty }.count
            return "\(path)  ·  \(ready)/\(chunks.count)\n" + chunks.filter { !$0.summary.isEmpty }.map { chunk in
                let kind = L10n.tr(chunk.summaryOrigin == .excerpt ? "ai.index.excerpt" : "ai.index.localSummary")
                let reason = chunk.summaryIssue.map { " · " + L10n.tr($0) } ?? ""
                return "[" + kind + reason + "] " + chunk.summary
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
    @objc private func refresh() { if let controller { render(controller: controller) } }
    @objc private func prepare() {
        guard let controller else { return }
        AIWorkIndexStore.shared(for: controller.context.rootURL)
            .ensure(context: controller.context, retryExcerpts: true) { _ in }
    }
    @objc private func cancel() {
        guard let controller else { return }
        AIWorkIndexStore.shared(for: controller.context.rootURL).cancel()
    }
}
