import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    // NSMenu가 delegate를 weak으로 참조하므로 강참조 유지
    private let recentMenuDelegate = RecentDocumentsMenuDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsManager.shared.applyAppearance()
        setupMenu()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // 최근 문서가 있으면 복원, 없으면 빈 문서 생성
        if let lastURL = NSDocumentController.shared.recentDocumentURLs.first,
           FileManager.default.fileExists(atPath: lastURL.path) {
            NSDocumentController.shared.openDocument(withContentsOf: lastURL, display: true) { _, _, _ in }
            return true
        }
        do {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
            return true
        } catch {
            return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Menu Setup (코드 기반)

    func rebuildMenu() {
        setupMenu()
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // 앱 메뉴
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.tr("menu.app.about"), action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("menu.app.settings"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("menu.app.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L10n.tr("menu.app.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L10n.tr("menu.app.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("menu.app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 파일 메뉴
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: L10n.tr("menu.file"))
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: L10n.tr("menu.file.new"), action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: L10n.tr("menu.file.open"), action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")

        let recentMenuItem = NSMenuItem(title: L10n.tr("menu.file.recent"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: L10n.tr("menu.file.recent"))
        recentMenu.delegate = recentMenuDelegate
        recentMenuItem.submenu = recentMenu
        fileMenu.addItem(recentMenuItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.tr("menu.file.save"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: L10n.tr("menu.file.saveAs"), action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: L10n.tr("menu.file.revert"), action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.tr("menu.file.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 편집 메뉴
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L10n.tr("menu.edit"))
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: L10n.tr("menu.edit.undo"), action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.tr("menu.edit.redo"), action: #selector(UndoManager.redo), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.tr("menu.edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.tr("menu.edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.tr("menu.edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plainPaste = editMenu.addItem(withTitle: L10n.tr("menu.edit.pastePlain"), action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plainPaste.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: L10n.tr("menu.edit.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.tr("menu.edit.find"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")

        // 서식 메뉴
        let formatMenuItem = NSMenuItem()
        mainMenu.addItem(formatMenuItem)
        let formatMenu = NSMenu(title: L10n.tr("menu.format"))
        formatMenuItem.submenu = formatMenu

        formatMenu.addItem(withTitle: L10n.tr("menu.format.bold"), action: #selector(EditorViewController.toggleBold), keyEquivalent: "b")
        formatMenu.addItem(withTitle: L10n.tr("menu.format.italic"), action: #selector(EditorViewController.toggleItalic), keyEquivalent: "i")
        formatMenu.addItem(withTitle: L10n.tr("menu.format.code"), action: #selector(EditorViewController.toggleInlineCode), keyEquivalent: "")
        formatMenu.addItem(.separator())
        formatMenu.addItem(withTitle: L10n.tr("menu.format.h1"), action: #selector(EditorViewController.setHeading1), keyEquivalent: "")
        formatMenu.addItem(withTitle: L10n.tr("menu.format.h2"), action: #selector(EditorViewController.setHeading2), keyEquivalent: "")
        formatMenu.addItem(withTitle: L10n.tr("menu.format.h3"), action: #selector(EditorViewController.setHeading3), keyEquivalent: "")
        formatMenu.addItem(withTitle: L10n.tr("menu.format.body"), action: #selector(EditorViewController.setBodyText), keyEquivalent: "")
        formatMenu.addItem(.separator())
        formatMenu.addItem(withTitle: L10n.tr("menu.format.ul"), action: #selector(EditorViewController.toggleUnorderedList), keyEquivalent: "")
        formatMenu.addItem(withTitle: L10n.tr("menu.format.ol"), action: #selector(EditorViewController.toggleOrderedList), keyEquivalent: "")
        formatMenu.addItem(withTitle: L10n.tr("menu.format.quote"), action: #selector(EditorViewController.toggleBlockquote), keyEquivalent: "")
        formatMenu.addItem(.separator())
        let linkItem = formatMenu.addItem(withTitle: L10n.tr("menu.format.link"), action: #selector(EditorViewController.insertLink), keyEquivalent: "k")
        linkItem.keyEquivalentModifierMask = .command

        // 윈도우 메뉴
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: L10n.tr("menu.window"))
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: L10n.tr("menu.window.minimize"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.tr("menu.window.zoom"), action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L10n.tr("menu.window.front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        // 도움말 메뉴
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: L10n.tr("menu.help"))
        helpMenuItem.submenu = helpMenu
        let helpItem = helpMenu.addItem(withTitle: L10n.tr("menu.help.help"), action: #selector(showHelp(_:)), keyEquivalent: "?")
        helpItem.target = self

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString()

        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .link: URL(string: "https://www.jenalab.com")!
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        credits.append(NSAttributedString(string: "@jenalab\n", attributes: labelAttrs))
        credits.append(NSAttributedString(string: "https://www.jenalab.com", attributes: linkAttrs))

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
    }

    @objc func showSettings(_ sender: Any?) {
        PreferencesWindowController.shared.show()
    }

    @objc func showHelp(_ sender: Any?) {
        HelpWindowController.shared.show()
    }

    @objc func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}

// MARK: - Recent Documents Menu Delegate

private class RecentDocumentsMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recentURLs = Array(NSDocumentController.shared.recentDocumentURLs.prefix(5))
        if recentURLs.isEmpty {
            let empty = NSMenuItem(title: L10n.tr("menu.file.recent.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for url in recentURLs {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(AppDelegate.openRecentDocument(_:)), keyEquivalent: "")
                item.representedObject = url
                item.target = NSApp.delegate
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let clear = NSMenuItem(title: L10n.tr("menu.file.recent.clear"), action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
            clear.target = NSDocumentController.shared
            menu.addItem(clear)
        }
    }
}
