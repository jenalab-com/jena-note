import AppKit

// MARK: - Preferences Window Controller

class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    private var languagePopup: NSPopUpButton!
    private var appearancePopup: NSPopUpButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("settings.title")
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        setupUI()
    }

    func show() {
        refreshLabels()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let padding: CGFloat = 24
        let labelWidth: CGFloat = 100
        let controlWidth: CGFloat = 220
        let rowHeight: CGFloat = 28
        let spacing: CGFloat = 16

        // Language row
        let langLabel = NSTextField(labelWithString: L10n.tr("settings.language"))
        langLabel.font = NSFont.systemFont(ofSize: 13)
        langLabel.alignment = .right
        langLabel.frame = NSRect(x: padding, y: 100, width: labelWidth, height: rowHeight)
        contentView.addSubview(langLabel)

        languagePopup = NSPopUpButton(frame: NSRect(
            x: padding + labelWidth + spacing,
            y: 100,
            width: controlWidth,
            height: rowHeight
        ), pullsDown: false)

        for lang in SettingsManager.Language.allCases {
            languagePopup.addItem(withTitle: lang.displayName)
            languagePopup.lastItem?.representedObject = lang.rawValue
        }

        let currentLang = SettingsManager.shared.language
        if let idx = SettingsManager.Language.allCases.firstIndex(of: currentLang) {
            languagePopup.selectItem(at: idx)
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        contentView.addSubview(languagePopup)

        // Appearance row
        let appearanceLabel = NSTextField(labelWithString: L10n.tr("settings.appearance"))
        appearanceLabel.font = NSFont.systemFont(ofSize: 13)
        appearanceLabel.alignment = .right
        appearanceLabel.frame = NSRect(x: padding, y: 56, width: labelWidth, height: rowHeight)
        contentView.addSubview(appearanceLabel)

        appearancePopup = NSPopUpButton(frame: NSRect(
            x: padding + labelWidth + spacing,
            y: 56,
            width: controlWidth,
            height: rowHeight
        ), pullsDown: false)

        for mode in SettingsManager.AppearanceMode.allCases {
            appearancePopup.addItem(withTitle: mode.displayName)
            appearancePopup.lastItem?.representedObject = mode.rawValue
        }

        let currentMode = SettingsManager.shared.appearanceMode
        if let idx = SettingsManager.AppearanceMode.allCases.firstIndex(of: currentMode) {
            appearancePopup.selectItem(at: idx)
        }
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged(_:))
        contentView.addSubview(appearancePopup)

        // Tag labels for refresh
        langLabel.tag = 1001
        appearanceLabel.tag = 1002
    }

    // MARK: - Actions

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let lang = SettingsManager.Language(rawValue: raw) else { return }
        SettingsManager.shared.language = lang
        refreshLabels()
        // Rebuild main menu with new language
        (NSApp.delegate as? AppDelegate)?.rebuildMenu()
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = SettingsManager.AppearanceMode(rawValue: raw) else { return }
        SettingsManager.shared.appearanceMode = mode
        refreshAppearanceItems()
    }

    // MARK: - Refresh

    private func refreshLabels() {
        window?.title = L10n.tr("settings.title")
        guard let contentView = window?.contentView else { return }
        if let langLabel = contentView.viewWithTag(1001) as? NSTextField {
            langLabel.stringValue = L10n.tr("settings.language")
        }
        if let appearanceLabel = contentView.viewWithTag(1002) as? NSTextField {
            appearanceLabel.stringValue = L10n.tr("settings.appearance")
        }
        refreshAppearanceItems()
    }

    private func refreshAppearanceItems() {
        let currentIdx = appearancePopup.indexOfSelectedItem
        appearancePopup.removeAllItems()
        for mode in SettingsManager.AppearanceMode.allCases {
            appearancePopup.addItem(withTitle: mode.displayName)
            appearancePopup.lastItem?.representedObject = mode.rawValue
        }
        if currentIdx >= 0 && currentIdx < appearancePopup.numberOfItems {
            appearancePopup.selectItem(at: currentIdx)
        }
    }
}
