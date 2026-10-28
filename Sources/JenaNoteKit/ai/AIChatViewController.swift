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
    let input = AIChatInputView()
    let composer = AIChatSurface(isComposer: true)
    private let inputUndoManager = UndoManager()
    // Internal (not private) so layout tests can locate them in the panel stack.
    let documentLabel = NSTextField(labelWithString: "")
    let workBar = AIWorkContextBar()
    /// Shows the work context window. Injectable so tests can intercept presenting.
    var windowPresenter: (NSWindowController) -> Void = {
        $0.showWindow(nil)
        $0.window?.makeKeyAndOrderFront(nil)
    }
    /// The window that last received this panel's maintenance progress (cleared when it ends).
    private weak var progressWindow: AIWorkContextWindowController?
    /// The window whose hooks this panel set last (cleared in `deinit` if it still owns them).
    private weak var hookedWindow: AIWorkContextWindowController?
    /// Refreshes the row when the shown document gets a file URL (Save As on an untitled document).
    private var fileURLObservation: NSKeyValueObservation?
    /// Summary run started from the work context window ("다시 만들기" / "요약 전부 새로 만들기"). It
    /// belongs to the work, not to a chat request: `cancel()`, `switchDocument()` and `suspend()` leave
    /// it running; only the window's cancel button and `deinit` stop it. Separate from `summaryRequest`.
    private var maintenanceRequest: AISummaryRequest?
    private var maintenanceStore: AIEpisodeSummaryStore?
    /// The window whose button started the maintenance run; its progress goes there (never to the
    /// window of whatever work the panel shows now).
    private weak var maintenanceWindow: AIWorkContextWindowController?
    private var maintenanceProgress: (done: Int, total: Int)?
    private var maintenanceCancelled = false
    /// The send flow's summary preparation (`summaryRequest`): its store and progress, mirrored into
    /// that work's window as `sendProgress` (spec §5.2) so the episodes tab can name it.
    private var preparingStore: AIEpisodeSummaryStore?
    private var preparingProgress: (done: Int, total: Int)?
    private weak var sendProgressWindow: AIWorkContextWindowController?
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
    private(set) var modeControl: NSSegmentedControl!
    private(set) var sendButton: NSButton!
    private var conversation: AIConversation?
    private var retrieval: AIWorkRetrieval?
    private var preparingIndex = false
    private var request: AIClient?
    private var generation = UUID()
    private var isSuspended = false

    override func loadView() {
        view = AIChatSurface()
        documentLabel.font = .systemFont(ofSize: 13, weight: .medium)
        documentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let settings = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L10n.tr("ai.settings"))!,
                                target: self, action: #selector(showSettings))
        settings.isBordered = false
        settings.toolTip = L10n.tr("ai.settings")
        let top = NSStackView(views: [documentLabel, settings])
        top.orientation = .horizontal
        top.distribution = .equalSpacing
        documentLabel.lineBreakMode = .byTruncatingMiddle
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
        input.toolTip = L10n.tr("ai.composer.keyboard")
        input.onSubmit = { [weak self] in self?.send() }
        input.canSubmit = { [weak self] in self?.isAwaitingResponse == false }
        modeControl = NSSegmentedControl(labels: [L10n.tr("ai.guide"), L10n.tr("ai.edit")],
                                         trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modeControl.selectedSegment = 0
        modeControl.controlSize = .small
        modeControl.segmentStyle = .rounded
        modeControl.font = .systemFont(ofSize: 11)
        modeControl.setContentHuggingPriority(.required, for: .horizontal)
        sendButton = NSButton(title: "", target: self, action: #selector(performComposerAction))
        sendButton.isBordered = false
        sendButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        sendButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        updateActionButton()
        options.install(modeControl: modeControl, actionButton: sendButton)
        workBar.onPrimaryAction = { [weak self] in self?.openWorkWindow() }
        let composerContent = NSStackView(views: [workBar, selectionLabel, inputScroll, options])
        composerContent.orientation = .vertical
        composerContent.alignment = .leading
        composerContent.spacing = 8
        composerContent.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(composerContent)
        for item in composerContent.arrangedSubviews {
            item.widthAnchor.constraint(equalTo: composerContent.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            composerContent.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 10),
            composerContent.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -10),
            composerContent.topAnchor.constraint(equalTo: composer.topAnchor, constant: 10),
            composerContent.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -10),
            inputScroll.heightAnchor.constraint(equalToConstant: 68)
        ])
        let stack = NSStackView(views: [top, historyScroll, composer, options.usageStatusBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        for item in stack.arrangedSubviews { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            historyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged),
                                                name: AIWorkIndexStore.changed, object: nil)
        input.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                                name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                                name: NSTextView.didChangeSelectionNotification, object: nil)
    }

    deinit {
        // A window this panel fed must not stay stuck on "갱신 취소 N/M" with dead hooks.
        progressWindow?.maintenanceProgress = nil
        sendProgressWindow?.sendProgress = nil
        if let window = hookedWindow, window.hooksOwner == ObjectIdentifier(self) {
            window.onRegenerate = nil
            window.onRefreshAll = nil
            window.onCancelRefresh = nil
            window.onChange = nil
            window.hooksOwner = nil
        }
        request?.cancel()
        retrieval?.cancel()
        summaryRequest?.cancel()
        maintenanceRequest?.cancel()
        fileURLObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshWorkContext()
    }

    private func makeScroll(textView: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        textView.drawsBackground = false
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
        fileURLObservation?.invalidate()
        fileURLObservation = nil
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
        input.needsDisplay = true
        modeControl.selectedSegment = conversation?.mode.rawValue ?? 0
        documentLabel.stringValue = document.displayName
        sendButton.isEnabled = true
        render()
        selectionChanged()
        fileURLObservation = document.observe(\.fileURL, options: [.new]) { [weak self] _, _ in
            if Thread.isMainThread {
                self?.documentLocationChanged()
            } else {
                DispatchQueue.main.async { self?.documentLocationChanged() }
            }
        }
        documentLocationChanged()
        AIWorkIndexStore.prepareDocument(document.fileURL)
    }

    /// The shown document changed or got a new file URL (Save As): refresh the row and point an
    /// open work context window for its root at the new file.
    private func documentLocationChanged() {
        refreshWorkContext()
        if let url = currentDocument?()?.fileURL, let root = resolvedWork?.context.rootURL,
           let window = AIWorkContextWindowController.existing(for: root) {
            window.currentFile = url
            window.reload()
        }
    }

    // MARK: - Work context

    /// Re-locates and re-resolves the work for the current document and updates the bar.
    /// While this panel's send flow is generating summaries (`summaryRequest`), the row keeps its
    /// "요약 만드는 중 N/M" state; only the send flow itself moves it on.
    func refreshWorkContext() {
        _ = view
        let status: AIWorkContextStatus
        if let url = currentDocument?()?.fileURL {
            switch AIWorkContext.locateResult(from: url) {
            case .failure:
                resolvedWork = nil
                summaryStore = nil
                status = .corrupt
            case .success(nil):
                resolvedWork = nil
                summaryStore = nil
                status = .unavailable(reason: .notInWork)
            case .success(let context?):
                let resolved = AIWorkContextResolver.resolve(context, currentFile: url)
                let store = AIEpisodeSummaryStore.shared(for: context.rootURL)
                resolvedWork = resolved
                summaryStore = store
                if let progress = ownMaintenanceProgress {
                    status = .generating(done: progress.done, total: progress.total)
                } else if context.config.enabled && !context.config.settingsSources.isEmpty {
                    let index = AIWorkIndexStore.shared(for: context.rootURL)
                    status = .indexed(text: index.statusText, running: index.isRunning, failed: index.error != nil)
                } else {
                    status = context.config.settingsSources.isEmpty ? .unavailable(reason: .noSources) : .disabled
                }
            }
        } else {
            resolvedWork = nil
            summaryStore = nil
            status = .unavailable(reason: .unsavedDocument)
        }
        if summaryRequest != nil, case .generating = workBar.status {
            // keep the send flow's progress
        } else {
            workBar.update(status)
        }
        pushMaintenanceProgress()
    }

    @objc private func indexChanged() { refreshWorkContext() }

    /// This window's maintenance progress, only while the shown work is the one being maintained.
    private var ownMaintenanceProgress: (done: Int, total: Int)? {
        guard let store = maintenanceStore, store === summaryStore else { return nil }
        return maintenanceProgress
    }

    /// Mirrors this panel's maintenance progress into the window that started the run (nil once the
    /// run ends).
    private func pushMaintenanceProgress() {
        let target = maintenanceRequest == nil ? nil : maintenanceWindow
        if let previous = progressWindow, previous !== target { previous.maintenanceProgress = nil }
        if let target = target, target.maintenanceProgress?.done != maintenanceProgress?.done
            || target.maintenanceProgress?.total != maintenanceProgress?.total {
            target.maintenanceProgress = maintenanceProgress
        }
        progressWindow = target
    }

    /// Mirrors the send flow's summary progress into the window of the work being prepared (nil
    /// once preparation ends); a window opened mid-run picks it up through `presentWorkWindow`.
    private func pushSendProgress() {
        let target = preparingProgress == nil ? nil
            : preparingStore.flatMap { AIWorkContextWindowController.existing(for: $0.rootURL) }
        if let previous = sendProgressWindow, previous !== target { previous.sendProgress = nil }
        if let target = target, target.sendProgress?.done != preparingProgress?.done
            || target.sendProgress?.total != preparingProgress?.total {
            target.sendProgress = preparingProgress
        }
        sendProgressWindow = target
    }

    /// The send flow's preparation ended (sent, failed or cancelled).
    private func endPreparing() {
        preparingStore = nil
        preparingProgress = nil
        pushSendProgress()
    }

    /// Row action (spec §5.1, §7.1): routes by the row's current status to the work context window
    /// or, for "켜기", turns the work back on without opening anything.
    func openWorkWindow() {
        if case .generating = workBar.status {
            // The row's button is "취소" (spec §5.2): stop this panel's run, never open the window.
            if summaryRequest != nil {
                cancel()
            } else if maintenanceRequest != nil {
                cancelMaintenance()
            }
            return
        }
        guard let url = currentDocument?()?.fileURL else { return }
        switch workBar.status {
        case .unavailable(reason: .unsavedDocument):
            return
        case .unavailable(reason: .notInWork):
            presentFirstSetup(fileURL: url)
        case .unavailable(reason: .noSources):
            // Saved work without sources: nothing to turn on; the window opens where sources are added.
            guard let root = resolvedWork?.context.rootURL else { return }
            let controller = AIWorkContextWindowController.shared(for: root, store: AIEpisodeSummaryStore.shared(for: root))
            controller.currentFile = url
            controller.reload()
            presentWorkWindow(controller, tab: .sources)
        case .corrupt:
            // Never let first setup overwrite an unreadable file that could not be backed up.
            guard setCorruptContextAside(fileURL: url) else { return }
            presentFirstSetup(fileURL: url)
        case .disabled:
            guard let root = resolvedWork?.context.rootURL else { return }
            let controller = AIWorkContextWindowController.shared(for: root, store: AIEpisodeSummaryStore.shared(for: root))
            controller.currentFile = url
            controller.reload()
            guard !controller.context.config.settingsSources.isEmpty else {
                return presentWorkWindow(controller, tab: .sources)
            }
            controller.mutate { config in
                config.disabledByUser = false
                config.enabled = !config.settingsSources.isEmpty
            }
            refreshWorkContext()
        case .generating:
            return // handled above
        case .active, .indexed:
            guard let root = resolvedWork?.context.rootURL else { return }
            let controller = AIWorkContextWindowController.shared(for: root, store: AIEpisodeSummaryStore.shared(for: root))
            controller.currentFile = url
            controller.reload()   // a reused window may hold a config edited elsewhere since
            presentWorkWindow(controller, tab: .sources)
        }
    }

    private func presentFirstSetup(fileURL: URL) {
        let root = AIWorkContextSuggestion.make(for: fileURL).rootURL
        let controller = AIWorkContextWindowController.forFirstSetup(
            fileURL: fileURL, store: AIEpisodeSummaryStore.shared(for: root))
        presentWorkWindow(controller, tab: .folders)
    }

    /// Renames an unreadable `context.json` to `context.json.bak` (replacing an older backup) so first
    /// setup starts clean and never overwrites it. Only inside the work's own `.jenanote`; only an
    /// older backup that is a regular file is replaced. Returns false (with a status line) when the
    /// file could not be set aside, in which case first setup must not start.
    private func setCorruptContextAside(fileURL: URL) -> Bool {
        guard let root = AIWorkContext.locateRoot(from: fileURL) else { return true } // already gone
        let folder = root.appendingPathComponent(AIWorkContext.folderName)
        let config = folder.appendingPathComponent(AIWorkContext.fileName)
        let backup = folder.appendingPathComponent(AIWorkContext.fileName + ".bak")
        let fm = FileManager.default
        do {
            guard AIWorkContext.isSafeInsideRoot(config, root: root),
                  AIWorkContext.isSafeInsideRoot(backup, root: root) else {
                throw AIError(message: String(format: L10n.tr("ai.work.errorOutsideRoot"), config.path))
            }
            if let type = (try? fm.attributesOfItem(atPath: backup.path))?[.type] as? FileAttributeType,
               type == .typeRegular {
                try fm.removeItem(at: backup)
            }
            try fm.moveItem(at: config, to: backup)
            let moved = L10n.tr("ai.work.corruptMoved")
            if let conversation = conversation {
                conversation.messages.append(AIChatMessage(role: "status", text: moved))
                render()
            } else {
                render(status: moved)
            }
            return true
        } catch {
            render(status: String(format: L10n.tr("ai.work.saveFailed"), error.localizedDescription))
            return false
        }
    }

    /// Hands the window to this panel (hooks, progress) and shows it on `tab`; an already visible
    /// window is only brought to the front, keeping the tab the user is on.
    private func presentWorkWindow(_ controller: AIWorkContextWindowController, tab: AIWorkContextWindowController.Tab) {
        controller.onChange = { [weak self] in self?.refreshWorkContext() }
        // Summary hooks act on THIS window's work (its store and resolved context), never on the
        // work the panel shows now: the window outlives document switches.
        controller.onRegenerate = { [weak self, weak controller] file, isSetting in
            guard let self = self, let controller = controller else { return }
            self.regenerateSummary(file, isSetting: isSetting, in: controller)
        }
        controller.onRefreshAll = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            self.refreshAllSummaries(in: controller)
        }
        controller.onCancelRefresh = { [weak self] in self?.cancelMaintenance() }
        controller.hooksOwner = ObjectIdentifier(self)
        hookedWindow = controller
        pushMaintenanceProgress()
        pushSendProgress()
        if let window = controller.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        controller.select(tab)
        windowPresenter(controller)
    }

    // MARK: - Summary maintenance (work context window)

    /// "다시 만들기" in `window`: regenerates into that window's store. Refused while the window's
    /// context is provisional (nothing saved yet).
    private func regenerateSummary(_ file: AIWorkFile, isSetting: Bool, in window: AIWorkContextWindowController) {
        guard !window.isProvisional else { return }
        let store = window.store
        let provider = AISettings.provider
        let model = options.selectedModel
        runMaintenance(store: store, window: window, total: 1, name: file.relativePath) { _, completion in
            store.regenerate(file, isSetting: isSetting, provider: provider, model: model, completion: completion)
        }
    }

    /// "모두 갱신" regenerates only missing/stale summaries (spec §7.2, §6.3): `prepare` skips ready and
    /// manually edited ones, so hand-edited summaries are never overwritten here — "다시 생성" on a row
    /// is the explicit way to replace one. Summarized settings are included. Works on `window`'s
    /// store and resolved context (its current file), not on the panel's current work.
    private func refreshAllSummaries(in window: AIWorkContextWindowController) {
        guard !window.isProvisional, let resolved = window.resolved else { return }
        let store = window.store
        let summarized = AIWorkContextAssembler(resolved: resolved, store: store).summarizedSettings
        let index = store.snapshotIndex()
        let total = store.pending(resolved.previousEpisodes, isSetting: false, index: index).count
            + store.pending(summarized, isSetting: true, index: index).count
        let provider = AISettings.provider
        let model = options.selectedModel
        runMaintenance(store: store, window: window, total: total, name: nil) { progress, completion in
            store.prepare(episodes: resolved.previousEpisodes, settings: summarized, provider: provider, model: model,
                          progress: progress, completion: completion)
        }
    }

    private func cancelMaintenance() {
        guard let handle = maintenanceRequest else { return }
        maintenanceCancelled = true
        handle.cancel() // completion runs synchronously; already generated summaries stay cached
    }

    /// Starts a summary run owned by this controller: progress drives the bar and the open work
    /// context window that started it (`window`); on completion every spent token is counted (spec
    /// §6.3) and failures become a status line.
    private func runMaintenance(store: AIEpisodeSummaryStore, window: AIWorkContextWindowController,
                                total: Int, name: String?,
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
            self.maintenanceWindow = nil
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
            } else {
                self.pushMaintenanceProgress()
            }
        })
        handle = request
        guard !finished else { return }
        maintenanceRequest = request
        maintenanceStore = store
        maintenanceWindow = window
        maintenanceProgress = (0, total)
        refreshWorkContext()
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
        selectionLabel.isHidden = range.length == 0
        modeControl.toolTip = selectionLabel.stringValue
        if !isSuspended { options.configure(provider: AISettings.provider, tokens: conversation?.tokenUsage[AISettings.provider]) }
    }

    /// Order (spec §6.8): fix the question → generate missing summaries → snapshot → prompt → send.
    /// When no summary is needed (the usual case) the snapshot is taken at click time, as before.
    @objc func send() {
        guard !preparingIndex, request == nil, summaryRequest == nil, let document = currentDocument?() else { return }
        let conversation = AIConversationStore.shared.conversation(for: document)
        self.conversation = conversation
        documentLabel.stringValue = document.displayName
        let question = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let mode = conversation.mode
        let provider = AISettings.provider
        let history = conversation.messages
        refreshWorkContext()
        if let work = requestWork() {
            sendWithIndex(work: work, document: document, conversation: conversation,
                          question: question, mode: mode, history: history, provider: provider)
            return
        }
        do {
            let (prompt, snapshot, _) = try makePrompt(document: document, history: history,
                                                       question: question, mode: mode, work: nil)
            commit(question, to: conversation)
            startRequest(prompt: prompt, snapshot: snapshot, document: document, conversation: conversation,
                         question: question, mode: mode, provider: provider, token: UUID())
        } catch { render(status: error.localizedDescription) }
    }

    private func sendWithIndex(work: AIWorkContextAssembler, document: MarkdownDocument,
                               conversation: AIConversation, question: String, mode: AIChatMode,
                               history: [AIChatMessage], provider: AIProvider) {
        guard AISettings.executable(for: provider) != nil else { render(status: L10n.tr("ai.notInstalled")); return }
        let token = UUID()
        generation = token
        let userIndex = conversation.messages.count
        commit(question, to: conversation)
        preparingIndex = true
        abortPreparation = { [weak self] _ in self?.uncommit(question, at: userIndex, in: conversation) }
        setBusy(true)
        waitingLabel.stringValue = L10n.tr("ai.index.waiting")
        render()
        let store = AIWorkIndexStore.shared(for: work.resolved.context.rootURL)
        let model = options.selectedModel
        store.ensure(context: work.resolved.context) { [weak self, weak document] result in
            guard let self, self.generation == token, let document, self.currentDocument?() === document else { return }
            do {
                let index = try result.get()
                guard let url = document.fileURL, let latest = AIWorkContext.locate(from: url),
                      latest == work.resolved.context, latest.config.enabled else {
                    throw AIError(message: L10n.tr("ai.index.changed"))
                }
                let resolved = AIWorkContextResolver.resolve(latest, currentFile: url)
                let passages = try index.eligible(for: resolved)
                let selection = self.currentSelection?() ?? NSRange(location: 0, length: 0)
                let snapshot = AIEditSnapshot(document: document, selection: selection)
                let retrieval = AIWorkRetrieval()
                self.retrieval = retrieval
                self.waitingLabel.stringValue = L10n.tr("ai.index.searching")
                retrieval.prepare(passages: passages, title: latest.config.title, currentEpisode: url.lastPathComponent,
                                  document: snapshot.content.string, question: question, history: history, provider: provider, model: model) { [weak self, weak document] result in
                    guard let self, self.generation == token else { return }
                    conversation.tokenUsage[provider, default: 0] += retrieval.tokensUsed
                    self.retrieval = nil
                    self.preparingIndex = false
                    do {
                        guard let document, self.currentDocument?() === document,
                              AIWorkContext.locate(from: url) == latest else { throw AIError(message: L10n.tr("ai.index.changed")) }
                        let payload = try result.get()
                        let prompt = try AIPrompt.make(snapshot: snapshot, messages: history, request: question,
                                                      mode: mode, hasSelection: selection.length > 0, work: payload)
                        self.abortPreparation = nil
                        if !retrieval.consulted.isEmpty {
                            conversation.messages.append(AIChatMessage(role: "status", text: L10n.tr("ai.index.sources") + "\n" + retrieval.consulted.joined(separator: "\n")))
                        }
                        self.startRequest(prompt: prompt, snapshot: snapshot, document: document, conversation: conversation,
                                          question: question, mode: mode, provider: provider, token: token)
                    } catch {
                        self.abortPreparation?(0)
                        self.abortPreparation = nil
                        self.failRequest(error.localizedDescription, question: question, conversation: conversation)
                    }
                }
            } catch {
                self.preparingIndex = false
                self.abortPreparation?(0)
                self.abortPreparation = nil
                self.failRequest(error.localizedDescription, question: question, conversation: conversation)
            }
        }
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
        input.needsDisplay = true
        conversation.draft = ""
    }

    /// Files that could not be read are not sent; say so rather than answering without them silently.
    private func noteSkipped(_ skipped: [AIWorkFile], in conversation: AIConversation) {
        guard !skipped.isEmpty else { return }
        let names = skipped.map(\.relativePath).joined(separator: ", ")
        conversation.messages.append(AIChatMessage(role: "status", text: L10n.tr("ai.work.unreadable") + ": " + names))
    }

    /// Send-flow summary progress: the waiting row uses the same words as the work context row, and
    /// the work's window (if open) shows it in its episodes tab.
    private func showGenerating(done: Int, total: Int) {
        waitingLabel.stringValue = String(format: L10n.tr("ai.work.row.generating"), done, total)
        workBar.update(.generating(done: done, total: total))
        preparingProgress = (done, total)
        pushSendProgress()
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
        let wasPreparing = summaryRequest != nil || preparingIndex
        if let retrieval {
            conversation?.tokenUsage[AISettings.provider, default: 0] += retrieval.tokensUsed
            retrieval.cancel()
        }
        retrieval = nil
        if preparingIndex { abortPreparation?(0) }
        preparingIndex = false
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
        if preparingStore != nil || preparingProgress != nil { endPreparing() }
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
        sendButton.isEnabled = busy || currentDocument?() != nil
        updateActionButton()
        modeControl.isEnabled = !busy
    }

    @objc private func performComposerAction() {
        if isAwaitingResponse { cancel() } else { send() }
    }

    private func updateActionButton() {
        let title = L10n.tr(isAwaitingResponse ? "ai.stop" : "ai.send")
        sendButton.image = NSImage(systemSymbolName: isAwaitingResponse ? "stop.circle.fill" : "arrow.up.circle.fill",
                                   accessibilityDescription: title)
        sendButton.toolTip = title
        sendButton.setAccessibilityLabel(title)
    }

    private func render(status: String? = nil) {
        var messages = conversation?.messages ?? []
        if let status = status { messages.append(AIChatMessage(role: "status", text: status)) }
        transcript.setMessages(messages)
        if !isSuspended { options.configure(provider: AISettings.provider, tokens: conversation?.tokenUsage[AISettings.provider]) }
    }
}

extension AIChatViewController: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? { inputUndoManager }
    func textDidChange(_ notification: Notification) { conversation?.draft = input.string }
}
