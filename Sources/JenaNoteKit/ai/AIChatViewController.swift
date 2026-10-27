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
    // Internal (not private) so layout tests can locate them in the panel stack.
    let documentLabel = NSTextField(labelWithString: "")
    let workBar = AIWorkContextBar()
    /// Task 7 hook: present the work context setup sheet (bar clicked in `.none` / `.corrupt`).
    var presentSetup: (() -> Void)?
    private var workSheet: AIWorkContextSheetController?
    /// Task 8 hook: present the work context popover (bar clicked in any other state).
    var presentPopover: (() -> Void)?
    private var workPopover: NSPopover?
    /// Summary run started from the popover ("다시 생성" / "모두 갱신"). It belongs to the work, not to a
    /// chat request: `cancel()`, `switchDocument()` and `suspend()` leave it running; only the popover's
    /// cancel button and `deinit` stop it. Separate from the send flow's `summaryRequest`.
    private var maintenanceRequest: AISummaryRequest?
    private var maintenanceStore: AIEpisodeSummaryStore?
    private var maintenanceProgress: (done: Int, total: Int)?
    private var maintenanceCancelled = false
    private var resolvedWork: AIResolvedWorkContext?
    private var summaryStore: AIEpisodeSummaryStore?
    /// This controller's own summary `prepare` request. Only it is cancelled by `cancel()`: the store
    /// is shared per work root, so another window's request must not be stopped.
    private var summaryRequest: AISummaryRequest?
    /// Set while `summaryRequest` runs: on cancel, counts the tokens already spent and takes the
    /// not-yet-sent question back out of the conversation into the input.
    private var abortPreparation: ((_ tokensUsed: Int) -> Void)?
    private var waitingLabel: NSTextField!
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
        waitingLabel = NSTextField(labelWithString: L10n.tr("ai.waiting"))
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
        workBar.onClick = { [weak self] in self?.workBarClicked() }
        let stack = NSStackView(views: [top, documentLabel, workBar, providerLabel, historyScroll, selectionLabel,
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
            workBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    deinit {
        request?.cancel()
        summaryRequest?.cancel()
        maintenanceRequest?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

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
            refreshWorkContext()
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
        refreshWorkContext()
    }

    // MARK: - Work context

    /// Re-locates and re-resolves the work for the current document and updates the bar.
    func refreshWorkContext() {
        _ = view
        guard let url = currentDocument?()?.fileURL else {
            resolvedWork = nil
            summaryStore = nil
            workBar.update(.none)
            return
        }
        switch AIWorkContext.locateResult(from: url) {
        case .failure:
            resolvedWork = nil
            summaryStore = nil
            workBar.update(.corrupt)
        case .success(nil):
            resolvedWork = nil
            summaryStore = nil
            workBar.update(.none)
        case .success(let context?):
            let resolved = AIWorkContextResolver.resolve(context, currentFile: url)
            let store = AIEpisodeSummaryStore.shared(for: context.rootURL)
            resolvedWork = resolved
            summaryStore = store
            workBar.update(AIWorkContextAssembler(resolved: resolved, store: store)
                .status(isGenerating: ownMaintenanceProgress.map { ($0.done, $0.total) }))
        }
        syncWorkPopover()
    }

    /// This window's maintenance progress, only while the shown work is the one being maintained.
    private var ownMaintenanceProgress: (done: Int, total: Int)? {
        guard let store = maintenanceStore, store === summaryStore else { return nil }
        return maintenanceProgress
    }

    /// Keeps an open popover in step with the bar: reloads it with the fresh resolution, or closes it
    /// when the document is no longer part of a (valid) work.
    private func syncWorkPopover() {
        guard let popover = workPopover, popover.isShown,
              let controller = popover.contentViewController as? AIWorkContextPopoverController else { return }
        guard let resolved = resolvedWork else { return popover.close() }
        controller.progress = ownMaintenanceProgress
        controller.reload(resolved)
    }

    private func workBarClicked() {
        switch workBar.status {
        case .none, .corrupt:
            if let presentSetup = presentSetup { presentSetup() } else { presentWorkSetupSheet() }
        case .active, .disabled, .generating:
            if let presentPopover = presentPopover { presentPopover() } else { presentWorkPopover() }
        }
    }

    private func presentWorkPopover() {
        guard let resolved = resolvedWork, let store = summaryStore else { return }
        let controller = AIWorkContextPopoverController(resolved: resolved, store: store)
        controller.preferredWidth = max(view.bounds.width, Self.minimumPanelWidth)
        controller.progress = ownMaintenanceProgress
        controller.onRegenerate = { [weak self] file, isSetting in self?.regenerateSummary(file, isSetting: isSetting) }
        controller.onRefreshAll = { [weak self] in self?.refreshAllSummaries() }
        controller.onCancelRefresh = { [weak self] in self?.cancelMaintenance() }
        // The popover saves context.json itself; re-resolve so the bar and the popover show the result.
        controller.onChange = { [weak self] in self?.refreshWorkContext() }
        controller.onOpenSheet = { [weak self] in
            guard let self = self else { return }
            self.workPopover?.close()
            self.presentWorkSetupSheet(existing: self.resolvedWork?.context)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        workPopover = popover
        popover.show(relativeTo: workBar.bounds, of: workBar, preferredEdge: .maxY)
    }

    // MARK: - Summary maintenance (popover)

    private func regenerateSummary(_ file: AIWorkFile, isSetting: Bool) {
        guard let store = summaryStore else { return }
        let provider = AISettings.provider
        let model = options.selectedModel
        runMaintenance(store: store, total: 1, name: file.relativePath) { _, completion in
            store.regenerate(file, isSetting: isSetting, provider: provider, model: model, completion: completion)
        }
    }

    /// "모두 갱신" regenerates only missing/stale summaries (spec §7.2, §6.3): `prepare` skips ready and
    /// manually edited ones, so hand-edited summaries are never overwritten here — "다시 생성" on a row
    /// is the explicit way to replace one. Summarized settings are included.
    private func refreshAllSummaries() {
        guard let resolved = resolvedWork, let store = summaryStore else { return }
        let summarized = AIWorkContextAssembler(resolved: resolved, store: store).summarizedSettings
        let total = store.pending(resolved.previousEpisodes, isSetting: false).count
            + store.pending(summarized, isSetting: true).count
        let provider = AISettings.provider
        let model = options.selectedModel
        runMaintenance(store: store, total: total, name: nil) { progress, completion in
            store.prepare(episodes: resolved.previousEpisodes, settings: summarized, provider: provider, model: model,
                          progress: progress, completion: completion)
        }
    }

    private func cancelMaintenance() {
        guard let handle = maintenanceRequest else { return }
        maintenanceCancelled = true
        handle.cancel() // completion runs synchronously; already generated summaries stay cached
    }

    /// Starts a popover summary run owned by this controller: progress drives the bar and an open
    /// popover; on completion every spent token is counted (spec §6.3) and failures become a status line.
    private func runMaintenance(store: AIEpisodeSummaryStore, total: Int, name: String?,
                                start: (_ progress: @escaping (Int, Int) -> Void,
                                        _ completion: @escaping (Result<Int, Error>) -> Void) -> AISummaryRequest) {
        guard maintenanceRequest == nil else { return }
        let provider = AISettings.provider
        let conversation = self.conversation // tokens and messages go to the conversation that started it
        var handle: AISummaryRequest?
        var finished = false
        maintenanceCancelled = false
        let request = start({ [weak self] done, total in
            guard let self = self, self.maintenanceRequest != nil else { return }
            self.maintenanceProgress = (done, total)
            self.refreshWorkContext()
        }, { [weak self] result in
            finished = true
            // A synchronous completion has no handle yet; then only a success can carry tokens.
            let spent = handle?.tokensUsed ?? ((try? result.get()) ?? 0)
            if spent > 0 { conversation?.tokenUsage[provider, default: 0] += spent }
            guard let self = self else { return }
            let cancelled = self.maintenanceCancelled
            self.maintenanceRequest = nil
            self.maintenanceStore = nil
            self.maintenanceProgress = nil
            self.maintenanceCancelled = false
            if case .failure(let error) = result {
                let message: String
                if cancelled {
                    message = L10n.tr("ai.cancelled")
                } else if let failure = error as? AISummaryGenerationError {
                    message = String(format: L10n.tr("ai.work.summaryFailed"), failure.file.relativePath,
                                     failure.underlying.localizedDescription)
                } else if let name = name {
                    message = String(format: L10n.tr("ai.work.summaryFailed"), name, error.localizedDescription)
                } else {
                    message = error.localizedDescription
                }
                conversation?.messages.append(AIChatMessage(role: "status", text: message))
            }
            if self.isViewLoaded {
                self.render()
                self.refreshWorkContext()
            }
        })
        handle = request
        guard !finished else { return }
        maintenanceRequest = request
        maintenanceStore = store
        maintenanceProgress = (0, total)
        refreshWorkContext()
    }

    private func presentWorkSetupSheet(existing: AIWorkContext? = nil) {
        guard let url = currentDocument?()?.fileURL, let window = view.window else { return }
        let sheet = AIWorkContextSheetController(fileURL: url, existing: existing)
        workSheet = sheet
        sheet.onSave = { [weak self] context in
            do {
                try context.save()
                self?.refreshWorkContext()
            } catch {
                self?.render(status: String(format: L10n.tr("ai.work.saveFailed"), error.localizedDescription))
            }
        }
        sheet.onClose = { [weak self] in self?.workSheet = nil }
        sheet.present(on: window)
    }

    /// The work context to attach to a request, or nil for the legacy (no `work`) prompt.
    private func requestWork() -> AIWorkContextAssembler? {
        guard let resolved = resolvedWork, let store = summaryStore, resolved.context.config.enabled else { return nil }
        if resolved.isOutsideWritingFolder && resolved.settings.isEmpty { return nil }
        return AIWorkContextAssembler(resolved: resolved, store: store)
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

    /// Order (spec §6.8): fix the question → generate missing summaries → snapshot → prompt → send.
    /// When no summary is needed (the usual case) the snapshot is taken at click time, as before.
    @objc func send() {
        guard request == nil, summaryRequest == nil, let document = currentDocument?() else { return }
        let conversation = AIConversationStore.shared.conversation(for: document)
        self.conversation = conversation
        documentLabel.stringValue = document.displayName
        let question = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let mode = conversation.mode
        let provider = AISettings.provider
        let history = conversation.messages
        refreshWorkContext()
        let work = requestWork()
        let episodes = work?.resolved.previousEpisodes ?? []
        let summarized = work?.summarizedSettings ?? []
        let jobs = work.map { $0.store.pending(episodes, isSetting: false) + $0.store.pending(summarized, isSetting: true) } ?? []

        guard let assembler = work, !jobs.isEmpty else {
            do {
                let (prompt, snapshot, skipped) = try makePrompt(document: document, history: history,
                                                                 question: question, mode: mode, work: work)
                guard AISettings.executable(for: provider) != nil else {
                    throw AIError(message: L10n.tr("ai.notInstalled"))
                }
                commit(question, to: conversation)
                noteSkipped(skipped, in: conversation)
                startRequest(prompt: prompt, snapshot: snapshot, document: document, conversation: conversation,
                             question: question, mode: mode, provider: provider, token: UUID())
            } catch { render(status: error.localizedDescription) }
            return
        }

        guard AISettings.executable(for: provider) != nil else { render(status: L10n.tr("ai.notInstalled")); return }
        // The store queues behind another window's run on the same work (spec §6.3).
        let store = assembler.store
        // Committed now so the question shows while waiting; taken back out (and returned to the
        // input) if summaries fail or are cancelled before the main request is sent.
        let userIndex = conversation.messages.count
        commit(question, to: conversation)
        if mode == .edit, (currentSelection?() ?? NSRange(location: 0, length: 0)).length > 0 {
            conversation.messages.append(AIChatMessage(role: "status", text: L10n.tr("ai.work.snapshotNote")))
        }
        let token = UUID()
        generation = token
        setBusy(true)
        showGenerating(done: 0, total: jobs.count)
        render()
        abortPreparation = { [weak self] tokensUsed in
            if tokensUsed > 0 { conversation.tokenUsage[provider, default: 0] += tokensUsed }
            self?.uncommit(question, at: userIndex, in: conversation)
        }
        var completed = 0
        var finished = false
        let handle = store.prepare(episodes: episodes, settings: summarized, provider: provider, model: options.selectedModel,
                      progress: { [weak self] done, total in
                          completed = done
                          guard let self = self, self.generation == token else { return }
                          self.showGenerating(done: done, total: total)
                      },
                      completion: { [weak self, weak document] result in
            finished = true
            guard let self = self, self.generation == token else { return } // cancel() already accounted
            // Every summary token counts (spec §6.3), whether the run succeeded or not. A synchronous
            // completion has no handle yet; then only a success can carry tokens.
            let spent = self.summaryRequest?.tokensUsed ?? ((try? result.get()) ?? 0)
            if spent > 0 { conversation.tokenUsage[provider, default: 0] += spent }
            self.summaryRequest = nil
            self.abortPreparation = nil
            switch result {
            case .success:
                guard let document = document, self.currentDocument?() === document else {
                    self.uncommit(question, at: userIndex, in: conversation)
                    return self.failRequest(L10n.tr("ai.noDocument"), question: question, conversation: conversation)
                }
                self.refreshWorkContext() // leave "요약 생성 중 N/N" for the real status
                do {
                    // Snapshot now: the selection and text at the moment summaries finished.
                    let (prompt, snapshot, skipped) = try self.makePrompt(document: document, history: history,
                                                                          question: question, mode: mode, work: assembler)
                    self.noteSkipped(skipped, in: conversation)
                    self.startRequest(prompt: prompt, snapshot: snapshot, document: document, conversation: conversation,
                                      question: question, mode: mode, provider: provider, token: token)
                } catch {
                    self.uncommit(question, at: userIndex, in: conversation)
                    self.failRequest(error.localizedDescription, question: question, conversation: conversation)
                }
            case .failure(let error):
                self.uncommit(question, at: userIndex, in: conversation)
                let name: String
                let reason: String
                if let failure = error as? AISummaryGenerationError {
                    name = failure.file.relativePath
                    reason = failure.underlying.localizedDescription
                } else {
                    name = completed < jobs.count ? jobs[completed].relativePath : ""
                    reason = error.localizedDescription
                }
                self.failRequest(String(format: L10n.tr("ai.work.summaryFailed"), name, reason),
                                 question: question, conversation: conversation)
            }
        })
        // The store may complete synchronously (e.g. an unreadable first file); keep no stale handle.
        if !finished { summaryRequest = handle } else { abortPreparation = nil }
    }

    /// Takes a question that was never sent back out of the conversation (with its snapshot note)
    /// and returns it to the input / draft.
    private func uncommit(_ question: String, at index: Int, in conversation: AIConversation) {
        var messages = conversation.messages
        if index < messages.count, messages[index].role == "user", messages[index].text == question {
            messages.remove(at: index)
            if index < messages.count, messages[index].role == "status",
               messages[index].text == L10n.tr("ai.work.snapshotNote") {
                messages.remove(at: index)
            }
            conversation.messages = messages
        }
        if self.conversation === conversation, input.string.isEmpty { input.string = question }
        if conversation.draft.isEmpty { conversation.draft = question }
    }

    private func makePrompt(document: MarkdownDocument, history: [AIChatMessage], question: String, mode: AIChatMode,
                            work: AIWorkContextAssembler?) throws -> (String, AIEditSnapshot, [AIWorkFile]) {
        let selection = currentSelection?() ?? NSRange(location: 0, length: 0)
        let snapshot = AIEditSnapshot(document: document, selection: selection)
        var payload: AIWorkPayload?
        var skipped: [AIWorkFile] = []
        if let work = work, let url = document.fileURL {
            (payload, skipped) = work.payload(currentFile: url)
        }
        let prompt = try AIPrompt.make(snapshot: snapshot, messages: history, request: question, mode: mode,
                                       hasSelection: selection.length > 0, work: payload)
        return (prompt, snapshot, skipped)
    }

    private func commit(_ question: String, to conversation: AIConversation) {
        conversation.messages.append(AIChatMessage(role: "user", text: question))
        input.string = ""
        conversation.draft = ""
    }

    /// Files that could not be read are not sent; say so rather than answering without them silently.
    private func noteSkipped(_ skipped: [AIWorkFile], in conversation: AIConversation) {
        guard !skipped.isEmpty else { return }
        let names = skipped.map(\.relativePath).joined(separator: ", ")
        conversation.messages.append(AIChatMessage(role: "status", text: L10n.tr("ai.work.unreadable") + ": " + names))
    }

    private func showGenerating(done: Int, total: Int) {
        waitingLabel.stringValue = String(format: L10n.tr("ai.work.generating"), done, total)
        workBar.update(.generating(done: done, total: total))
    }

    /// Failure before the main request was sent: keep the question so nothing is lost.
    private func failRequest(_ message: String, question: String, conversation: AIConversation) {
        conversation.messages.append(AIChatMessage(role: "status", text: message))
        if input.string.isEmpty { input.string = question; conversation.draft = question }
        setBusy(false)
        options.refresh()
        render()
        refreshWorkContext()
    }

    private func startRequest(prompt: String, snapshot: AIEditSnapshot, document: MarkdownDocument,
                              conversation: AIConversation, question: String, mode: AIChatMode,
                              provider: AIProvider, token: UUID) {
        let client = AIClient()
        request = client
        generation = token
        setBusy(true)
        waitingLabel.stringValue = L10n.tr("ai.waiting")
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
            self.refreshWorkContext()
        }
    }

    @objc func cancel() {
        let wasPreparing = summaryRequest != nil
        let wasRequesting = request != nil
        generation = UUID()
        request?.cancel()
        request = nil
        // Only this controller's own summary run; already generated summaries stay cached.
        // The main request was not sent yet, so the question goes back to the input.
        if let pending = summaryRequest {
            summaryRequest = nil
            pending.cancel()
            abortPreparation?(pending.tokensUsed)
        }
        abortPreparation = nil
        if wasRequesting || wasPreparing {
            conversation?.messages.append(AIChatMessage(role: "status", text: L10n.tr("ai.cancelled")))
        }
        if isViewLoaded {
            setBusy(false)
            render()
            if wasPreparing { refreshWorkContext() }
        }
    }

    private func setBusy(_ busy: Bool) {
        isAwaitingResponse = busy
        options.setBusy(busy)
        loadingRow.isHidden = !busy
        if busy { responseProgress.startAnimation(nil) }
        else { responseProgress.stopAnimation(nil); waitingLabel.stringValue = L10n.tr("ai.waiting") }
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
