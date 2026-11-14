import AppKit

final class AISettingsViewController: NSViewController {
    private let providerPopup = JenaPopUpButton(frame: .zero, pullsDown: false)
    private let pathLabel = NSTextField(labelWithString: "")
    private let pathField = NSTextField()
    private let addressField = NSTextField()
    private var addressRow: NSView!
    private let status = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var checkButton: NSButton!
    private var installButton: NSButton!
    private var loginButton: NSButton!
    private var docsButton: NSButton!
    private var runButton: NSButton!
    private var serverObserver: NSObjectProtocol?
    private var probe: AIClient?
    private var versionProcess: AIProcess?
    private var generation = UUID()
    // A successful request verifies this provider/executable, not every installed CLI.
    private var verifiedConnections = Set<String>()

    private func connectionKey(_ executable: URL) -> String {
        AISettings.provider.rawValue + ":" + executable.path
    }

    override func loadView() {
        providerPopup.addItems(withTitles: AIProvider.allCases.map(\.title))
        providerPopup.selectItem(at: AIProvider.allCases.firstIndex(of: AISettings.provider) ?? 0)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.isFilled = true
        providerPopup.font = .systemFont(ofSize: 13)
        providerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        pathField.placeholderString = L10n.tr("ai.pathPlaceholder")
        pathField.setAccessibilityLabel(L10n.tr("ai.path"))
        pathField.target = self
        pathField.action = #selector(pathChanged)
        let browse = SettingsButton(title: L10n.tr("ai.browse"), target: self, action: #selector(browsePath))
        installButton = SettingsButton(title: L10n.tr("ai.install"), target: self, action: #selector(install), primary: true)
        loginButton = SettingsButton(title: L10n.tr("ai.login"), target: self, action: #selector(login))
        checkButton = SettingsButton(title: L10n.tr("ai.recheck"), target: self, action: #selector(recheck))
        docsButton = SettingsButton(title: L10n.tr("ai.instructions"), target: self, action: #selector(openDocs))
        runButton = SettingsButton(title: L10n.tr("ai.local.run"), target: self, action: #selector(toggleLocalServer), primary: true)
        addressField.placeholderString = AISettings.defaultLocalServerAddress
        addressField.stringValue = AISettings.localServerAddress
        addressField.setAccessibilityLabel(L10n.tr("ai.local.address"))
        addressField.target = self
        addressField.action = #selector(addressChanged)

        // AI 도구 — 무엇을, 어디서 실행할지
        let pathControl = NSStackView(views: [SettingsFieldContainer(pathField, width: 220), browse])
        pathControl.spacing = 8
        addressRow = SettingsRow(title: L10n.tr("ai.local.address"), control: SettingsFieldContainer(addressField, width: 220))
        let tools = SettingsCard(rows: [
            SettingsRow(title: L10n.tr("ai.provider"), control: providerPopup),
            SettingsRow(titleLabel: pathLabel, control: pathControl),
            addressRow
        ])

        // 연결 — 지금 상태와 할 수 있는 일
        status.font = .systemFont(ofSize: 13)
        status.maximumNumberOfLines = 5
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityElement(true)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [runButton, installButton, loginButton, checkButton, docsButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        let connection = NSStackView(views: [status, actions])
        connection.orientation = .vertical
        connection.alignment = .leading
        connection.spacing = 12
        status.widthAnchor.constraint(equalTo: connection.widthAnchor).isActive = true

        let page = SettingsPageView(title: L10n.tr("ai.settings"))
        page.addSection(L10n.tr("ai.section.tool"), card: tools)
        page.addSection(L10n.tr("ai.section.connection"), card: SettingsCard(rows: [SettingsRow(content: connection)]))
        let help = NSStackView(views: [detail])
        help.orientation = .vertical
        help.alignment = .leading
        page.addSection(nil, card: SettingsCard(rows: [SettingsRow(content: help)]))
        detail.widthAnchor.constraint(equalTo: help.widthAnchor).isActive = true
        view = page

        serverObserver = NotificationCenter.default.addObserver(forName: AILocalServer.stateDidChange, object: AILocalServer.shared,
                                                                queue: .main) { [weak self] _ in self?.showInstallation() }
        providerChanged()
    }

    deinit {
        probe?.cancel()
        versionProcess?.cancel()
        if let serverObserver { NotificationCenter.default.removeObserver(serverObserver) }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        probe?.cancel()
        versionProcess?.cancel()
        generation = UUID()
    }

    @objc private func providerChanged() {
        probe?.cancel()
        versionProcess?.cancel()
        generation = UUID()
        AISettings.provider = AIProvider.allCases[max(0, providerPopup.indexOfSelectedItem)]
        pathField.stringValue = AISettings.customPath(for: AISettings.provider)
        checkButton.isEnabled = true
        let isLocal = AISettings.provider == .local
        for control in [installButton, loginButton, checkButton, docsButton] as [NSView] { control.isHidden = isLocal }
        runButton.isHidden = !isLocal
        addressRow.isHidden = !isLocal
        pathLabel.stringValue = L10n.tr(isLocal ? "ai.local.path" : "ai.path")
        pathField.placeholderString = L10n.tr(isLocal ? "ai.local.pathPlaceholder" : "ai.pathPlaceholder")
        detail.stringValue = isLocal ? L10n.tr("ai.local.help")
            : L10n.tr("ai.setupHelp") + (AISettings.provider == .grok ? "\n" + L10n.tr("ai.grokProfile") : "")
        if isLocal { AILocalServer.shared.refresh() }
        showInstallation()
    }

    private func showLocalServerState() {
        let server = AILocalServer.shared
        runButton.title = L10n.tr("ai.local.run")
        runButton.isEnabled = true
        switch server.state {
        case .stopped:
            status.stringValue = L10n.tr("ai.local.stopped")
        case .failed(let message):
            status.stringValue = String(message.prefix(2000))
        case .starting(let since):
            let seconds = Int(Date().timeIntervalSince(since))
            status.stringValue = String(format: L10n.tr("ai.local.starting"), String(format: "%d:%02d", seconds / 60, seconds % 60))
            runButton.title = L10n.tr("ai.local.stop")
        case .running(let owned):
            status.stringValue = L10n.tr(owned ? "ai.local.running" : "ai.local.external")
            runButton.title = L10n.tr("ai.local.stop")
            // Stopping a server this app did not start is not this app's call.
            runButton.isEnabled = owned
        }
    }

    @objc private func addressChanged() {
        AISettings.localServerAddress = addressField.stringValue
        AILocalServer.shared.refresh()
    }

    @objc private func toggleLocalServer() {
        pathChanged()
        addressChanged()
        switch AILocalServer.shared.state {
        case .starting, .running: AILocalServer.shared.stop()
        case .stopped, .failed: AILocalServer.shared.start()
        }
    }

    private func showInstallation() {
        guard AISettings.provider != .local else { showLocalServerState(); return }
        if let executable = AISettings.executable(for: AISettings.provider) {
            let verified = verifiedConnections.contains(connectionKey(executable))
            status.stringValue = L10n.tr(verified ? "ai.connected" : "ai.installed") + "\n" + executable.path
            installButton.isEnabled = false
            loginButton.title = L10n.tr(verified ? "ai.loggedIn" : "ai.login")
            loginButton.isEnabled = !verified
        } else {
            status.stringValue = L10n.tr("ai.notInstalled")
            installButton.isEnabled = true
            loginButton.title = L10n.tr("ai.login")
            loginButton.isEnabled = false
        }
    }

    @objc private func pathChanged() {
        probe?.cancel()
        versionProcess?.cancel()
        generation = UUID()
        AISettings.setPath(pathField.stringValue, for: AISettings.provider)
        checkButton.isEnabled = true
        showInstallation()
    }

    @objc private func browsePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField.stringValue = url.path
        pathChanged()
    }

    @objc private func install() {
        pathChanged()
        let provider = AISettings.provider
        status.stringValue = L10n.tr("ai.installing")
        AITerminal.open(provider: provider, install: true) { [weak self] error in
            guard AISettings.provider == provider else { return }
            self?.status.stringValue = error?.localizedDescription ?? L10n.tr("ai.installOpened")
        }
    }

    @objc private func login() {
        pathChanged()
        let provider = AISettings.provider
        AITerminal.open(provider: provider, install: false) { [weak self] error in
            guard AISettings.provider == provider else { return }
            self?.status.stringValue = error?.localizedDescription ?? L10n.tr("ai.loginOpened")
        }
    }

    @objc private func openDocs() { NSWorkspace.shared.open(AISettings.provider.documentation) }

    @objc private func recheck() {
        pathChanged()
        guard let executable = AISettings.executable(for: AISettings.provider) else { return }
        let provider = AISettings.provider
        let token = generation
        status.stringValue = L10n.tr("ai.checking")
        checkButton.isEnabled = false
        loginButton.isEnabled = false
        let process = AIProcess()
        versionProcess = process
        process.run(executable: executable, arguments: ["--version"], timeout: 15, environmentOverrides: provider.environmentOverrides) { [weak self] result in
            guard let self = self, self.generation == token else { return }
            switch result {
            case .failure(let error): self.finishCheck(error.localizedDescription)
            case .success(let output):
                guard output.status == 0 else { self.finishCheck(L10n.tr("ai.versionFailed")); return }
                let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let client = AIClient()
                self.probe = client
                client.send(provider: provider, prompt: "Reply with exactly JENANOTE_OK. Do not use any tools.") { [weak self] result in
                    guard let self = self, self.generation == token else { return }
                    switch result {
                    case .success(let answer):
                        self.finishCheck(answer.trimmingCharacters(in: .whitespacesAndNewlines) == "JENANOTE_OK"
                            ? L10n.tr("ai.connected") + "\n" + version
                            : L10n.tr("ai.unexpectedProbe"), authenticated: true)
                    case .failure(let error): self.finishCheck(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func finishCheck(_ message: String, authenticated: Bool = false) {
        if let executable = AISettings.executable(for: AISettings.provider) {
            let key = connectionKey(executable)
            if authenticated { verifiedConnections.insert(key) }
            else { verifiedConnections.remove(key) }
        }
        showInstallation()
        checkButton.isEnabled = true
        status.stringValue = String(message.prefix(2000))
        probe = nil
        versionProcess = nil
    }
}
