import AppKit

class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()
    private let tabs = NSTabViewController()
    private let languagePopup = NSPopUpButton()
    private let appearancePopup = NSPopUpButton()
    private let autosavePopup = NSPopUpButton()
    private let autosaveCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let paperColorWell = NSColorWell()
    private let resetPaperButton = NSButton()
    private var labels: [(NSTextField, String)] = []

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.init(window: window)
        setupUI()
        refreshLabels()
        window.center()
    }

    func show() {
        refreshLabels()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func showAI() {
        tabs.selectedTabViewItemIndex = 2
        show()
    }

    private func setupUI() {
        tabs.tabStyle = .segmentedControlOnTop
        let general = NSViewController(); general.view = NSView()
        let ui = NSViewController(); ui.view = NSView()
        for (id, controller) in [("general", general), ("ui", ui), ("ai", AISettingsViewController())] {
            let item = NSTabViewItem(viewController: controller)
            item.identifier = id
            tabs.addTabViewItem(item)
        }
        window?.contentViewController = tabs
        window?.setContentSize(NSSize(width: 620, height: 500))

        for language in SettingsManager.Language.allCases {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.target = self; languagePopup.action = #selector(languageChanged)
        autosaveCheckbox.target = self; autosaveCheckbox.action = #selector(autosaveChanged)
        autosavePopup.target = self; autosavePopup.action = #selector(autosaveIntervalChanged)
        appearancePopup.target = self; appearancePopup.action = #selector(appearanceChanged)
        let hint = NSTextField(wrappingLabelWithString: "")
        labels.append((hint, "autosave.hint"))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        hint.widthAnchor.constraint(equalToConstant: 370).isActive = true
        installRows([
            row("settings.language", languagePopup),
            row("", autosaveCheckbox),
            row("autosave.interval", autosavePopup),
            row("", hint)
        ], in: general.view)
        paperColorWell.target = self
        paperColorWell.action = #selector(paperChanged(_:))
        paperColorWell.isContinuous = true
        paperColorWell.widthAnchor.constraint(equalToConstant: 64).isActive = true
        paperColorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        resetPaperButton.target = self
        resetPaperButton.action = #selector(resetPaper)
        resetPaperButton.bezelStyle = .rounded
        let colors = NSStackView(views: [paperColorWell, resetPaperButton])
        colors.spacing = 12
        installRows([row("settings.colorMode", appearancePopup), row("paper.title", colors)], in: ui.view)
    }

    private func row(_ key: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: "")
        label.alignment = .right
        if !key.isEmpty { labels.append((label, key)) }
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        if control is NSPopUpButton { control.widthAnchor.constraint(equalToConstant: 220).isActive = true }
        let row = NSStackView(views: [label, control])
        row.alignment = .centerY; row.spacing = 16
        return row
    }
    private func installRows(_ rows: [NSView], in view: NSView) {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    @objc private func languageChanged() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let language = SettingsManager.Language(rawValue: raw) else { return }
        SettingsManager.shared.language = language
        // Recreate the AI page so all of its localized controls follow the new language.
        let old = tabs.tabViewItems[2]
        tabs.removeTabViewItem(old)
        let ai = NSTabViewItem(viewController: AISettingsViewController()); ai.identifier = "ai"
        tabs.addTabViewItem(ai)
        refreshLabels()
        (NSApp.delegate as? AppDelegate)?.rebuildMenu()
    }
    @objc private func appearanceChanged() {
        guard let raw = appearancePopup.selectedItem?.representedObject as? String,
              let mode = SettingsManager.AppearanceMode(rawValue: raw) else { return }
        SettingsManager.shared.appearanceMode = mode
        refreshPaperColor()
    }
    @objc private func paperChanged(_ sender: NSColorWell) {
        PaperBackground.currentColor = sender.color
    }
    @objc private func resetPaper() {
        paperColorWell.deactivate()
        PaperBackground.selected = .standard
        refreshPaperColor()
    }
    @objc private func autosaveChanged() {
        SettingsManager.shared.autosaveEnabled = autosaveCheckbox.state == .on
        refreshAutosaveItems()
    }
    @objc private func autosaveIntervalChanged() {
        guard let seconds = autosavePopup.selectedItem?.representedObject as? Int else { return }
        SettingsManager.shared.autosaveInterval = seconds
    }
    private func refreshPaperColor() {
        paperColorWell.color = PaperBackground.currentColor
        paperColorWell.setAccessibilityLabel(L10n.tr("paper.title"))
        paperColorWell.toolTip = L10n.tr("paper.chooseColor")
        resetPaperButton.title = L10n.tr("paper.resetColor")
    }
    private func refreshAutosaveItems() {
        autosaveCheckbox.title = L10n.tr("autosave.enabled")
        autosaveCheckbox.state = SettingsManager.shared.autosaveEnabled ? .on : .off
        autosavePopup.isEnabled = SettingsManager.shared.autosaveEnabled
        autosavePopup.removeAllItems()
        for seconds in SettingsManager.autosaveIntervals {
            autosavePopup.addItem(withTitle: L10n.tr("autosave.seconds.\(seconds)"))
            autosavePopup.lastItem?.representedObject = seconds
        }
        autosavePopup.selectItem(at: SettingsManager.autosaveIntervals.firstIndex(of: SettingsManager.shared.autosaveInterval) ?? 1)
    }
    private func refreshLabels() {
        window?.title = L10n.tr("settings.title")
        for (label, key) in labels { label.stringValue = L10n.tr(key) }
        for item in tabs.tabViewItems { item.label = L10n.tr("settings.tab.\(item.identifier as? String ?? "general")") }
        languagePopup.selectItem(at: SettingsManager.Language.allCases.firstIndex(of: SettingsManager.shared.language) ?? 0)
        appearancePopup.removeAllItems()
        for mode in SettingsManager.AppearanceMode.allCases {
            appearancePopup.addItem(withTitle: mode.displayName)
            appearancePopup.lastItem?.representedObject = mode.rawValue
        }
        appearancePopup.selectItem(at: SettingsManager.AppearanceMode.allCases.firstIndex(of: SettingsManager.shared.appearanceMode) ?? 0)
        refreshPaperColor()
        refreshAutosaveItems()
    }
}
