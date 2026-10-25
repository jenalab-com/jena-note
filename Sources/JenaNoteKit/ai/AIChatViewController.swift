import AppKit

final class AIChatViewController: NSViewController {
    var currentDocument: (() -> MarkdownDocument?)?
    var currentSelection: (() -> NSRange)?
    var applyEdit: ((AIEditSnapshot, String) throws -> Void)?
    static let defaultPanelWidth: CGFloat = 300
    static let minimumPanelWidth: CGFloat = 260
    static let maximumPanelWidth = defaultPanelWidth * 2

    private let transcript = AIChatTranscriptView()
    private(set) var isAwaitingResponse = false
    let responseProgress = NSProgressIndicator()
    private var loadingRow: NSStackView!
    let options = AIChatOptionsView()
    private let input = NSTextView()
    private let inputUndoManager = UndoManager()
    private let documentLabel = NSTextField(labelWithString: "")
    private let selectionLabel = NSTextField(wrappingLabelWithString: "")
    private let providerLabel = NSTextField(labelWithString: "")
    private var modeControl: NSSegmentedControl!
    private var sendButton: NSButton!
    private var cancelButton: NSButton!
    private var conversation: AIConversation?
    private var request: AIClient?
    private var generation = UUID()
    private var isSuspended = false

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: L10n.tr("ai.title"))
        title.font = .boldSystemFont(ofSize: 14)
        let settings = NSButton(title: L10n.tr("ai.settings"), target: self, action: #selector(showSettings))
        let top = NSStackView(views: [title, settings])
        top.orientation = .horizontal
        top.distribution = .equalSpacing
        documentLabel.lineBreakMode = .byTruncatingMiddle
        providerLabel.font = .systemFont(ofSize: 11)
        providerLabel.textColor = .secondaryLabelColor
        selectionLabel.font = .systemFont(ofSize: 11)
        selectionLabel.textColor = .secondaryLabelColor
        let historyScroll = transcript
        responseProgress.style = .bar
        responseProgress.controlSize = .small
        responseProgress.isIndeterminate = true
        responseProgress.usesThreadedAnimation = true
        responseProgress.setAccessibilityLabel(L10n.tr("ai.waiting"))
        let waitingLabel = NSTextField(labelWithString: L10n.tr("ai.waiting"))
        waitingLabel.font = .systemFont(ofSize: 11)
        waitingLabel.textColor = .secondaryLabelColor
        loadingRow = NSStackView(views: [responseProgress, waitingLabel])
        loadingRow.orientation = .horizontal
        loadingRow.spacing = 8
        loadingRow.isHidden = true
        transcript.setLoadingView(loadingRow)
        responseProgress.widthAnchor.constraint(equalToConstant: 64).isActive = true
        responseProgress.heightAnchor.constraint(equalToConstant: 4).isActive = true
        let inputScroll = makeScroll(textView: input, editable: true)
        input.setAccessibilityLabel(L10n.tr("ai.request"))
        modeControl = NSSegmentedControl(labels: [L10n.tr("ai.guide"), L10n.tr("ai.edit")],
                                         trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modeControl.selectedSegment = 0
        let requestLabel = NSTextField(labelWithString: L10n.tr("ai.request"))
        sendButton = NSButton(title: L10n.tr("ai.send"), target: self, action: #selector(send))
        cancelButton = NSButton(title: L10n.tr("ai.stop"), target: self, action: #selector(cancel))
        cancelButton.isEnabled = false
        let buttons = NSStackView(views: [sendButton, cancelButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [top, documentLabel, providerLabel, historyScroll, selectionLabel,
                                       modeControl, requestLabel, inputScroll, options, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            documentLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            historyScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            historyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputScroll.heightAnchor.constraint(equalToConstant: 80),
            selectionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        input.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                                name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                                name: NSTextView.didChangeSelectionNotification, object: nil)
    }

    deinit { request?.cancel(); NotificationCenter.default.removeObserver(self) }

    private func makeScroll(textView: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = editable
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }

    func switchDocument() {
        isSuspended = false
        _ = view
        conversation?.draft = input.string
        cancel()
        guard let document = currentDocument?() else {
            conversation = nil
            documentLabel.stringValue = L10n.tr("ai.noDocument")
            input.string = ""
            transcript.setMessages([])
            sendButton.isEnabled = false
            return
        }
        inputUndoManager.removeAllActions()
        conversation = AIConversationStore.shared.conversation(for: document)
        input.string = conversation?.draft ?? ""
        modeControl.selectedSegment = conversation?.mode.rawValue ?? 0
        documentLabel.stringValue = document.displayName
        sendButton.isEnabled = true
        render()
        selectionChanged()
    }

    func suspend() {
        isSuspended = true
        conversation?.draft = input.string
        cancel()
        options.suspend()
    }

    @objc private func showSettings() { PreferencesWindowController.shared.showAI() }

    @objc private func modeChanged() {
        conversation?.mode = AIChatMode(rawValue: modeControl.selectedSegment) ?? .guide
        selectionChanged()
    }

    @objc private func selectionChanged() {
        let range = currentSelection?() ?? NSRange(location: 0, length: 0)
        if range.length > 0, let doc = currentDocument?(), NSMaxRange(range) <= doc.content.length {
            let excerpt = doc.content.attributedSubstring(from: range).string.replacingOccurrences(of: "\n", with: " ")
            selectionLabel.stringValue = L10n.tr("ai.selection") + " \(range.length) · " + String(excerpt.prefix(60))
        } else {
            selectionLabel.stringValue = L10n.tr(modeControl.selectedSegment == 1 ? "ai.wholeEdit" : "ai.wholeContext")
        }
        providerLabel.stringValue = AISettings.provider.title
        if !isSuspended { options.configure(provider: AISettings.provider, tokens: conversation?.tokenUsage[AISettings.provider]) }
    }

    @objc func send() {
        guard request == nil, let document = currentDocument?() else { return }
        let conversation = AIConversationStore.shared.conversation(for: document)
        self.conversation = conversation
        documentLabel.stringValue = document.displayName
        let question = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let selection = currentSelection?() ?? NSRange(location: 0, length: 0)
        let snapshot = AIEditSnapshot(document: document, selection: selection)
        let mode = conversation.mode
        do {
            let prompt = try AIPrompt.make(snapshot: snapshot, messages: conversation.messages,
                                           request: question, mode: mode, hasSelection: selection.length > 0)
            let provider = AISettings.provider
            guard AISettings.executable(for: provider) != nil else {
                throw AIError(message: L10n.tr("ai.notInstalled"))
            }
            conversation.messages.append(AIChatMessage(role: "user", text: question))
            input.string = ""
            conversation.draft = ""
            let client = AIClient()
            request = client
            let token = UUID()
            generation = token
            setBusy(true)
            render()
            client.send(provider: provider, prompt: prompt, model: self.options.selectedModel) { [weak self, weak document] result in
                guard let self = self, self.generation == token else { return }
                self.request = nil
                self.setBusy(false)
                if let tokens = client.tokenUsage {
                    conversation.tokenUsage[provider, default: 0] += tokens
                }
                self.options.refresh()
                switch result {
                case .failure(let error):
                    conversation.messages.append(AIChatMessage(role: "status", text: error.localizedDescription))
                    // Retain the request so a connection failure does not lose the user's work.
                    if self.input.string.isEmpty { self.input.string = question; conversation.draft = question }
                case .success(let answer):
                    if mode == .guide {
                        conversation.messages.append(AIChatMessage(role: "assistant", text: answer))
                    } else {
                        do {
                            let edit = try AIPrompt.parseEdit(answer)
                            conversation.messages.append(AIChatMessage(role: "assistant", text: edit.explanation))
                            if let replacement = edit.replacement {
                                guard let doc = document, self.currentDocument?() === doc, snapshot.canApply(to: doc) else {
                                    throw AIError(message: L10n.tr("ai.editConflict"))
                                }
                                guard let apply = self.applyEdit else { throw AIError(message: L10n.tr("ai.noDocument")) }
                                try apply(snapshot, replacement)
                                conversation.messages.append(AIChatMessage(role: "status", text: L10n.tr("ai.applied")))
                            }
                        } catch {
                            conversation.messages.append(AIChatMessage(role: "status", text: error.localizedDescription + "\n\n" + answer))
                        }
                    }
                }
                self.render()
            }
        } catch { render(status: error.localizedDescription) }
    }

    @objc func cancel() {
        if request != nil {
            conversation?.messages.append(AIChatMessage(role: "status", text: L10n.tr("ai.cancelled")))
        }
        generation = UUID()
        request?.cancel()
        request = nil
        if isViewLoaded { setBusy(false); render() }
    }

    private func setBusy(_ busy: Bool) {
        isAwaitingResponse = busy
        options.setBusy(busy)
        loadingRow.isHidden = !busy
        if busy { responseProgress.startAnimation(nil) }
        else { responseProgress.stopAnimation(nil) }
        sendButton.isEnabled = !busy && currentDocument?() != nil
        cancelButton.isEnabled = busy
        modeControl.isEnabled = !busy
    }

    private func render(status: String? = nil) {
        var messages = conversation?.messages ?? []
        if let status = status { messages.append(AIChatMessage(role: "status", text: status)) }
        transcript.setMessages(messages)
        providerLabel.stringValue = AISettings.provider.title
        if !isSuspended { options.configure(provider: AISettings.provider, tokens: conversation?.tokenUsage[AISettings.provider]) }
    }
}

extension AIChatViewController: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? { inputUndoManager }
    func textDidChange(_ notification: Notification) { conversation?.draft = input.string }
}
