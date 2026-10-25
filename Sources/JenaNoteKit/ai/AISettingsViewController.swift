import AppKit

final class AISettingsViewController: NSViewController {
    private let providerPopup = NSPopUpButton()
    private let pathField = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var checkButton: NSButton!
    private var installButton: NSButton!
    private var loginButton: NSButton!
    private var probe: AIClient?
    private var versionProcess: AIProcess?
    private var generation = UUID()
    // A successful request verifies this provider/executable, not every installed CLI.
    private var verifiedConnections = Set<String>()

    private func connectionKey(_ executable: URL) -> String {
        AISettings.provider.rawValue + ":" + executable.path
    }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: L10n.tr("ai.settings"))
        title.font = .boldSystemFont(ofSize: 14)
        providerPopup.addItems(withTitles: AIProvider.allCases.map(\.title))
        providerPopup.selectItem(at: AIProvider.allCases.firstIndex(of: AISettings.provider) ?? 0)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        pathField.placeholderString = L10n.tr("ai.pathPlaceholder")
        pathField.setAccessibilityLabel(L10n.tr("ai.path"))
        pathField.target = self
        pathField.action = #selector(pathChanged)
        let browse = NSButton(title: L10n.tr("ai.browse"), target: self, action: #selector(browsePath))
        installButton = NSButton(title: L10n.tr("ai.install"), target: self, action: #selector(install))
        loginButton = NSButton(title: L10n.tr("ai.login"), target: self, action: #selector(login))
        checkButton = NSButton(title: L10n.tr("ai.recheck"), target: self, action: #selector(recheck))
        let docs = NSButton(title: L10n.tr("ai.instructions"), target: self, action: #selector(openDocs))
        let pathRow = NSStackView(views: [pathField, browse])
        pathRow.orientation = .horizontal
        let actions = NSStackView(views: [installButton, loginButton, checkButton, docs])
        actions.orientation = .horizontal
        actions.spacing = 8
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 5
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityElement(true)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, providerPopup, NSTextField(labelWithString: L10n.tr("ai.path")),
                                       pathRow, actions, status, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        providerChanged()
    }

    deinit { probe?.cancel(); versionProcess?.cancel() }

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
        detail.stringValue = L10n.tr("ai.setupHelp") + (AISettings.provider == .grok ? "\n" + L10n.tr("ai.grokProfile") : "")
        showInstallation()
    }

    private func showInstallation() {
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
