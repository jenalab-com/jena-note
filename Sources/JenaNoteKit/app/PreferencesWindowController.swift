import AppKit

/// 설정 창 — 왼쪽은 메인 사이드바와 같은 목록(검은 pill 선택), 오른쪽은 "제목 → 섹션 카드" 페이지.
/// 신호등 버튼 아래까지 목록 바탕이 올라가도록 타이틀바를 투명하게 둔다.
class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    /// 목록 순서 — (페이지 ID, 아이콘)
    static let pageOrder: [(id: String, symbol: String)] = [
        ("general", "gearshape"), ("ui", "paintpalette"), ("punctuation", "quote.bubble"), ("ai", "sparkles")
    ]

    private(set) var selectedPage = "general"
    private var pages: [String: NSViewController] = [:]
    private var navItems: [SettingsNavItem] = []
    private let navStack = NSStackView()
    private let contentView = NSView()

    private let languagePopup = JenaPopUpButton(frame: .zero, pullsDown: false)
    private let appearancePopup = JenaPopUpButton(frame: .zero, pullsDown: false)
    private let autosavePopup = JenaPopUpButton(frame: .zero, pullsDown: false)
    private let autosaveSwitch = NSSwitch()
    private let paperColorWell = CircleColorWell(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    private var resetPaperButton: SettingsButton!

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        self.init(window: window)
        setupUI()
        rebuildPages()
        select(selectedPage)
        window.center()
    }

    func show() {
        refreshTitles()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAI() {
        select("ai")
        show()
    }

    /// 목록에서 페이지를 고른다.
    func select(_ id: String) {
        guard let page = pages[id] else { return }
        selectedPage = id
        contentView.subviews.forEach { $0.removeFromSuperview() }
        let view = page.view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        for item in navItems { item.isSelectedPage = item.pageID == id }
    }

    /// 테스트·외부에서 특정 페이지의 화면을 꺼낼 때.
    func pageView(_ id: String) -> NSView? { pages[id]?.view }

    // MARK: - Layout

    private func setupUI() {
        let root = NSView()
        let nav = SidebarBackgroundView()
        nav.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nav)

        let content = ContentBackgroundView()
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentView)

        let divider = SidebarHairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navStack.translatesAutoresizingMaskIntoConstraints = false
        nav.addSubview(navStack)
        for page in Self.pageOrder {
            let item = SettingsNavItem(pageID: page.id, symbol: page.symbol, target: self, action: #selector(navClicked(_:)))
            navItems.append(item)
            navStack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: root.topAnchor),
            nav.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            nav.widthAnchor.constraint(equalToConstant: SettingsStyle.navWidth),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: nav.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: content.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // 신호등 버튼 아래부터 목록
            navStack.topAnchor.constraint(equalTo: nav.topAnchor, constant: 52),
            navStack.leadingAnchor.constraint(equalTo: nav.leadingAnchor, constant: 10),
            navStack.trailingAnchor.constraint(equalTo: nav.trailingAnchor, constant: -10)
        ])

        let controller = NSViewController()
        controller.view = root
        window?.contentViewController = controller
        window?.setContentSize(NSSize(width: 760, height: 540))

        for language in SettingsManager.Language.allCases {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        for popup in [languagePopup, appearancePopup, autosavePopup] {
            popup.isFilled = true
            popup.font = .systemFont(ofSize: 13)
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        }
        languagePopup.target = self; languagePopup.action = #selector(languageChanged)
        autosaveSwitch.target = self; autosaveSwitch.action = #selector(autosaveChanged)
        autosavePopup.target = self; autosavePopup.action = #selector(autosaveIntervalChanged)
        appearancePopup.target = self; appearancePopup.action = #selector(appearanceChanged)
        paperColorWell.target = self
        paperColorWell.action = #selector(paperChanged(_:))
        paperColorWell.isContinuous = true
        paperColorWell.translatesAutoresizingMaskIntoConstraints = false
        paperColorWell.widthAnchor.constraint(equalToConstant: 28).isActive = true
        paperColorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        resetPaperButton = SettingsButton(title: "", target: self, action: #selector(resetPaper))
    }

    /// 페이지를 (다시) 만든다 — 언어를 바꾸면 모든 문구가 새 언어로 다시 그려지도록.
    private func rebuildPages() {
        refreshControls()
        let general = SettingsPageView(title: L10n.tr("settings.tab.general"))
        general.addSection(nil, card: SettingsCard(rows: [
            SettingsRow(title: L10n.tr("settings.language"), control: languagePopup)
        ]))
        general.addSection(L10n.tr("autosave.section"), card: SettingsCard(rows: [
            SettingsRow(title: L10n.tr("autosave.enabled"), control: autosaveSwitch),
            SettingsRow(title: L10n.tr("autosave.interval"), control: autosavePopup)
        ]), footnote: L10n.tr("autosave.hint"))

        let colors = NSStackView(views: [paperColorWell, resetPaperButton])
        colors.spacing = 10
        colors.alignment = .centerY
        let ui = SettingsPageView(title: L10n.tr("settings.tab.ui"))
        ui.addSection(nil, card: SettingsCard(rows: [
            SettingsRow(title: L10n.tr("settings.colorMode"), control: appearancePopup),
            SettingsRow(title: L10n.tr("paper.title"), control: colors)
        ]))

        pages = [
            "general": Self.controller(general),
            "ui": Self.controller(ui),
            "punctuation": PunctuationSettingsViewController(),
            "ai": AISettingsViewController()
        ]
        refreshTitles()
    }

    private static func controller(_ view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    @objc private func navClicked(_ sender: SettingsNavItem) { select(sender.pageID) }

    // MARK: - Actions

    @objc private func languageChanged() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let language = SettingsManager.Language(rawValue: raw) else { return }
        SettingsManager.shared.language = language
        // 모든 페이지를 새 언어로 다시 만든다.
        let current = selectedPage
        rebuildPages()
        select(current)
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
        SettingsManager.shared.autosaveEnabled = autosaveSwitch.state == .on
        refreshAutosaveItems()
    }
    @objc private func autosaveIntervalChanged() {
        guard let seconds = autosavePopup.selectedItem?.representedObject as? Int else { return }
        SettingsManager.shared.autosaveInterval = seconds
    }

    // MARK: - Refresh

    private func refreshPaperColor() {
        paperColorWell.color = PaperBackground.currentColor
        paperColorWell.setAccessibilityLabel(L10n.tr("paper.title"))
        paperColorWell.toolTip = L10n.tr("paper.chooseColor")
        resetPaperButton.title = L10n.tr("paper.resetColor")
    }
    private func refreshAutosaveItems() {
        autosaveSwitch.state = SettingsManager.shared.autosaveEnabled ? .on : .off
        autosaveSwitch.setAccessibilityLabel(L10n.tr("autosave.enabled"))
        autosavePopup.isEnabled = SettingsManager.shared.autosaveEnabled
        autosavePopup.removeAllItems()
        for seconds in SettingsManager.autosaveIntervals {
            autosavePopup.addItem(withTitle: L10n.tr("autosave.seconds.\(seconds)"))
            autosavePopup.lastItem?.representedObject = seconds
        }
        autosavePopup.selectItem(at: SettingsManager.autosaveIntervals.firstIndex(of: SettingsManager.shared.autosaveInterval) ?? 1)
    }
    private func refreshControls() {
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
    private func refreshTitles() {
        window?.title = L10n.tr("settings.title")
        for item in navItems { item.title = L10n.tr("settings.tab.\(item.pageID)") }
        refreshControls()
    }
}

/// 설정 페이지 바탕 — 문서 바탕색(메인 창 본문과 같은 면).
private final class ContentBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill() // 자기 영역 밖(clipsToBounds=false)은 칠하지 않는다
    }
}
