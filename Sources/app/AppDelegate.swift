import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    // NSMenu가 delegate를 weak으로 참조하므로 강참조 유지
    private let recentMenuDelegate = RecentDocumentsMenuDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    private func setupMenu() {
        let mainMenu = NSMenu()

        // 앱 메뉴
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Jena Note 정보", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Jena Note 숨기기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "다른 항목 숨기기", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "모두 보기", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Jena Note 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 파일 메뉴
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "파일")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "새 문서", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "열기...", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")

        let recentMenuItem = NSMenuItem(title: "최근 열었던 항목", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "최근 열었던 항목")
        recentMenu.delegate = recentMenuDelegate
        recentMenuItem.submenu = recentMenu
        fileMenu.addItem(recentMenuItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "저장", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "다른 이름으로 저장...", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "되돌리기", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 편집 메뉴
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "편집")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "실행 취소", action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "다시 실행", action: #selector(UndoManager.redo), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plainPaste = editMenu.addItem(withTitle: "서식 없이 붙여넣기", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plainPaste.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "찾기...", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")

        // 서식 메뉴
        let formatMenuItem = NSMenuItem()
        mainMenu.addItem(formatMenuItem)
        let formatMenu = NSMenu(title: "서식")
        formatMenuItem.submenu = formatMenu

        formatMenu.addItem(withTitle: "굵게", action: #selector(EditorViewController.toggleBold), keyEquivalent: "b")
        formatMenu.addItem(withTitle: "기울임", action: #selector(EditorViewController.toggleItalic), keyEquivalent: "i")
        formatMenu.addItem(withTitle: "코드", action: #selector(EditorViewController.toggleInlineCode), keyEquivalent: "")
        formatMenu.addItem(.separator())
        formatMenu.addItem(withTitle: "제목 1", action: #selector(EditorViewController.setHeading1), keyEquivalent: "")
        formatMenu.addItem(withTitle: "제목 2", action: #selector(EditorViewController.setHeading2), keyEquivalent: "")
        formatMenu.addItem(withTitle: "제목 3", action: #selector(EditorViewController.setHeading3), keyEquivalent: "")
        formatMenu.addItem(withTitle: "본문", action: #selector(EditorViewController.setBodyText), keyEquivalent: "")
        formatMenu.addItem(.separator())
        formatMenu.addItem(withTitle: "목록", action: #selector(EditorViewController.toggleUnorderedList), keyEquivalent: "")
        formatMenu.addItem(withTitle: "번호 목록", action: #selector(EditorViewController.toggleOrderedList), keyEquivalent: "")
        formatMenu.addItem(withTitle: "인용", action: #selector(EditorViewController.toggleBlockquote), keyEquivalent: "")
        formatMenu.addItem(.separator())
        let linkItem = formatMenu.addItem(withTitle: "링크 삽입", action: #selector(EditorViewController.insertLink), keyEquivalent: "k")
        linkItem.keyEquivalentModifierMask = .command

        // 윈도우 메뉴
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "윈도우")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "확대/축소", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "모든 창 앞으로", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        // 도움말 메뉴
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "도움말")
        helpMenuItem.submenu = helpMenu
        let helpItem = helpMenu.addItem(withTitle: "Jena Note 도움말", action: #selector(showHelp(_:)), keyEquivalent: "?")
        helpItem.target = self

        NSApp.mainMenu = mainMenu
    }

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
            let empty = NSMenuItem(title: "최근 항목 없음", action: nil, keyEquivalent: "")
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
            let clear = NSMenuItem(title: "목록 지우기", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
            clear.target = NSDocumentController.shared
            menu.addItem(clear)
        }
    }
}
