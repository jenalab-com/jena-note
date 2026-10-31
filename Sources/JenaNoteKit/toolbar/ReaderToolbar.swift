import AppKit

class ReaderToolbar: NSToolbar {

    weak var target: AnyObject?
    weak var formatTarget: EditorViewController? {
        didSet { formatItems.target = formatTarget }
    }
    private let formatItems = FormatToolbar(identifier: .init("FormatItemFactory"))
    private var isSourceActive = false
    private weak var sourceButton: NSButton?
    private var appearancePopover: NSPopover?
    private weak var headingControl: NSPopUpButton?
    private weak var widthControl: NSSegmentedControl?
    private static let itemSource = NSToolbarItem.Identifier("markdownSource")
    private static let itemAppearance = NSToolbarItem.Identifier("appearance")
    private static let itemHeading = NSToolbarItem.Identifier("heading")
    private static let itemLists = NSToolbarItem.Identifier("lists")
    private static let itemInsert = NSToolbarItem.Identifier("insert")
    private static let itemProofreading = NSToolbarItem.Identifier("proofreadSelection")
    private weak var proofreadingButton: NSButton?
    private var hasSelectedText = false

    func updateSelection(hasSelectedText: Bool) {
        self.hasSelectedText = hasSelectedText
        formatItems.updateSelection(hasSelectedText: hasSelectedText && !isSourceActive)
        proofreadingButton?.isEnabled = hasSelectedText && !isSourceActive
    }

    func setSourceActive(_ active: Bool) {
        isSourceActive = active
        sourceButton?.state = active ? .on : .off
        for item in items {
            let allowed = [Self.itemSource, Self.itemAI, NSToolbarItem.Identifier("find")].contains(item.itemIdentifier)
            (item.view as? NSControl)?.isEnabled = !active || allowed
        }
        pageModeControl?.setEnabled(!active, forSegment: 0)
        pageModeControl?.setEnabled(!active && !isAIActive, forSegment: 1)
        if active { formatItems.updateSelection(hasSelectedText: false) }
        proofreadingButton?.isEnabled = hasSelectedText && !active
    }

    func updateState(attributes: [NSAttributedString.Key: Any]) {
        formatItems.updateState(attributes: attributes)
        let block = attributes[.mdBlockType] as? String ?? "body"
        let index = ["body", "h1", "h2", "h3"].firstIndex(of: block) ?? 0
        headingControl?.selectItem(at: index)
    }
    var isAIActive = false
    private static let itemAI = NSToolbarItem.Identifier("aiChat")

    private static let itemMode  = NSToolbarItem.Identifier("readerPageMode")
    private static let itemFontFamily = NSToolbarItem.Identifier("readerFontFamily")
    private static let itemFontWeight = NSToolbarItem.Identifier("readerFontWeight")
    private static let itemLineSpacing = NSToolbarItem.Identifier("readerLineSpacing")
    private static let itemFontDown = NSToolbarItem.Identifier("readerFontDown")
    private static let itemFontUp   = NSToolbarItem.Identifier("readerFontUp")
    private static let itemWidth = NSToolbarItem.Identifier("readerWidth")
    private static let itemBookmark = NSToolbarItem.Identifier("readerBookmark")
    private static let itemBookmarkList = NSToolbarItem.Identifier("readerBookmarkList")

    /// 책갈피 토글 버튼 — 현재 화면에 책갈피가 있는지에 따라 아이콘이 채워진다.
    private weak var bookmarkButton: NSButton?

    /// 스크롤/페이징 세그먼트 — 코드가 조판을 바꿨을 때 선택 상태를 맞춰준다.
    private weak var pageModeControl: NSSegmentedControl?

    /// 조판이 코드에서 바뀐 경우(페이징 중 타이핑 → 스크롤 전환 등) 세그먼트를 따라 맞춘다.
    func updatePageModeSelection(_ mode: SettingsManager.ReadingPageMode) {
        pageModeControl?.selectedSegment = (mode == .paged) ? 1 : 0
    }

    func setAIActive(_ active: Bool) {
        isAIActive = active
        pageModeControl?.setEnabled(!active && !isSourceActive, forSegment: 1)
        if active { updatePageModeSelection(.scroll) }
    }

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)
        delegate = self
        displayMode = .iconOnly
        allowsUserCustomization = false
        autosavesConfiguration = false
    }

    /// 지금 보이는 화면에 책갈피가 있는지를 아이콘에 반영한다.
    func updateBookmarkState(active: Bool) {
        let symbol = active ? "bookmark.fill" : "bookmark"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        bookmarkButton?.image = NSImage(systemSymbolName: symbol,
                                        accessibilityDescription: L10n.tr("reader.bookmark.toggle"))?
            .withSymbolConfiguration(config)
    }

    /// 책갈피 목록 팝오버를 붙일 기준 뷰.
    var bookmarkAnchorView: NSView? { bookmarkButton }
}

extension ReaderToolbar: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ReaderToolbar.itemMode, ReaderToolbar.itemAppearance, ReaderToolbar.itemSource, .space,
         ReaderToolbar.itemHeading, .init("bold"), .init("italic"), .init("inlineCode"),
         ReaderToolbar.itemLists, ReaderToolbar.itemInsert, .init("textColor"), .init("find"),
         .flexibleSpace, ReaderToolbar.itemBookmark, ReaderToolbar.itemBookmarkList,
         ReaderToolbar.itemProofreading, ReaderToolbar.itemAI]
    }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(t)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ReaderToolbar.itemProofreading:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L10n.tr("proof.title")
            item.toolTip = item.label
            let button = NSButton(title: L10n.tr("proof.button"), target: target,
                                  action: #selector(EditorWindowController.proofreadSelection(_:)))
            button.toolTip = item.label
            button.isEnabled = hasSelectedText && !isSourceActive
            proofreadingButton = button
            item.view = button
            let menu = NSMenuItem(title: item.label, action: button.action, keyEquivalent: "")
            menu.target = target
            item.menuFormRepresentation = menu
            return item
        case ReaderToolbar.itemSource:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L10n.tr("source.title")
            item.toolTip = L10n.tr("source.hint")
            let button = NSButton(title: item.label, target: target,
                                  action: #selector(EditorWindowController.showMarkdownSource(_:)))
            button.toolTip = item.toolTip
            button.setButtonType(.pushOnPushOff)
            button.state = isSourceActive ? .on : .off
            sourceButton = button
            item.view = button
            let menu = NSMenuItem(title: item.label, action: button.action, keyEquivalent: "")
            menu.target = target
            item.menuFormRepresentation = menu
            return item
        case ReaderToolbar.itemAI:
            let item = NSToolbarItem(itemIdentifier: id)
            item.visibilityPriority = .high
            item.label = L10n.tr("ai.title")
            item.view = NSButton(title: "AI", target: target, action: #selector(EditorWindowController.toggleAI(_:)))
            item.toolTip = L10n.tr("ai.title")
            return item
        case ReaderToolbar.itemAppearance:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L10n.tr("toolbar.appearance")
            item.view = NSButton(title: item.label, target: self, action: #selector(showAppearance(_:)))
            item.toolTip = item.label
            return item
        case ReaderToolbar.itemHeading:
            let item = menuItem(id, label: L10n.tr("menu.format.body"), entries: [
                (L10n.tr("menu.format.body"), #selector(EditorViewController.setBodyText)),
                ("H1", #selector(EditorViewController.setHeading1)),
                ("H2", #selector(EditorViewController.setHeading2)),
                ("H3", #selector(EditorViewController.setHeading3))
            ], pullsDown: false)
            headingControl = item.view as? NSPopUpButton
            return item
        case ReaderToolbar.itemLists:
            return menuItem(id, label: L10n.tr("toolbar.lists"), entries: [
                (L10n.tr("menu.format.ul"), #selector(EditorViewController.toggleUnorderedList)),
                (L10n.tr("menu.format.ol"), #selector(EditorViewController.toggleOrderedList)),
                (L10n.tr("menu.format.quote"), #selector(EditorViewController.toggleBlockquote))
            ])
        case ReaderToolbar.itemInsert:
            return menuItem(id, label: L10n.tr("toolbar.insert"), entries: [
                (L10n.tr("menu.format.link"), #selector(EditorViewController.insertLink)),
                (L10n.tr("toolbar.image"), #selector(EditorViewController.insertImage)),
                (L10n.tr("toolbar.rule"), #selector(EditorViewController.insertHorizontalRule))
            ])
        case ReaderToolbar.itemBookmark:
            let item = iconItem(id, label: L10n.tr("reader.bookmark.toggle"), symbol: "bookmark",
                                action: #selector(EditorWindowController.toggleBookmark(_:)))
            bookmarkButton = item.view as? NSButton
            return item
        case ReaderToolbar.itemBookmarkList:
            return iconItem(id, label: L10n.tr("reader.bookmark.list"), symbol: "list.bullet",
                            action: #selector(EditorWindowController.showBookmarkList(_:)))
        case ReaderToolbar.itemMode:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L10n.tr("reader.pageMode")
            item.toolTip = L10n.tr("reader.pageMode")
            let seg = NSSegmentedControl(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            seg.segmentCount = 2
            seg.setLabel(L10n.tr("reader.scroll"), forSegment: 0)
            seg.setLabel(L10n.tr("reader.paged"), forSegment: 1)
            seg.trackingMode = .selectOne
            seg.selectedSegment = (SettingsManager.shared.readingPageMode == .paged) ? 1 : 0
            // NSSegmentedControl in NSToolbarItem.view does not reliably traverse
            // the responder chain when target is nil on macOS — bind directly to
            // the window controller via ReaderToolbar.target (same fix as FormatToolbar).
            seg.target = target
            seg.action = #selector(EditorWindowController.changeReaderPageMode(_:))
            seg.translatesAutoresizingMaskIntoConstraints = false
            seg.widthAnchor.constraint(equalToConstant: 120).isActive = true
            seg.heightAnchor.constraint(equalToConstant: 26).isActive = true
            item.view = seg
            pageModeControl = seg
            setAIActive(isAIActive)
            return item
        case ReaderToolbar.itemWidth:
            return segmentItem(id, label: L10n.tr("reader.width"),
                               labels: [L10n.tr("reader.widthMobile"), L10n.tr("reader.widthBook")],
                               selected: formatTarget?.readingWidthMode == .mobile ? 0 : 1,
                               action: #selector(EditorWindowController.changeReaderWidth(_:)))
        case ReaderToolbar.itemFontFamily:
            return fontPopUpItem(id)
        case ReaderToolbar.itemFontWeight:
            let weights = SettingsManager.ReadingWeight.allCases
            let sel = weights.firstIndex(of: SettingsManager.shared.readingWeight) ?? 1
            return segmentItem(id, label: L10n.tr("reader.weight"),
                               labels: weights.map { L10n.tr($0.locKey) },
                               selected: sel,
                               action: #selector(EditorWindowController.changeReaderWeight(_:)))
        case ReaderToolbar.itemLineSpacing:
            let ls = SettingsManager.shared.readingLineSpacing
            let sel = ls <= 1.35 ? 0 : (ls >= 1.75 ? 2 : 1)
            return segmentItem(id, label: L10n.tr("reader.lineSpacing"),
                               labels: [L10n.tr("reader.lineTight"), L10n.tr("reader.lineNormal"), L10n.tr("reader.lineWide")],
                               selected: sel,
                               action: #selector(EditorWindowController.changeReaderLineSpacing(_:)))
        case ReaderToolbar.itemFontDown:
            return iconItem(id, label: L10n.tr("reader.fontDown"), symbol: "textformat.size.smaller",
                            action: #selector(EditorWindowController.decreaseReaderFont(_:)))
        case ReaderToolbar.itemFontUp:
            return iconItem(id, label: L10n.tr("reader.fontUp"), symbol: "textformat.size.larger",
                            action: #selector(EditorWindowController.increaseReaderFont(_:)))
        default:
            return formatItems.toolbar(formatItems, itemForItemIdentifier: id, willBeInsertedIntoToolbar: flag)
        }
    }

    private func menuItem(_ id: NSToolbarItem.Identifier, label: String,
                          entries: [(String, Selector)], pullsDown: Bool = true) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 70, height: 26), pullsDown: pullsDown)
        if pullsDown { popup.addItem(withTitle: label) }
        for (title, action) in entries {
            popup.addItem(withTitle: title)
            popup.lastItem?.target = formatTarget
            popup.lastItem?.action = action
        }
        item.view = popup
        return item
    }

    @objc private func changePaperSize(_ sender: NSPopUpButton) {
        (target as? EditorWindowController)?.changeDocumentPaperSize(sender)
        widthControl?.selectedSegment = 1
    }

    @objc private func showAppearance(_ sender: NSButton) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for id in [Self.itemWidth, Self.itemFontFamily, Self.itemFontWeight, Self.itemLineSpacing] {
            guard let item = toolbar(self, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false),
                  let control = item.view else { continue }
            let label = NSTextField(labelWithString: item.label)
            label.font = .systemFont(ofSize: 12)
            let row = NSStackView(views: [label, control])
            row.spacing = 12
            stack.addArrangedSubview(row)
        }
        let paper = NSPopUpButton()
        for size in DocumentPaperSize.allCases {
            paper.addItem(withTitle: size.title)
            paper.lastItem?.representedObject = size.rawValue
        }
        paper.selectItem(at: DocumentPaperSize.allCases.firstIndex(of: .selected) ?? 0)
        paper.target = self
        paper.action = #selector(changePaperSize(_:))
        stack.insertArrangedSubview(NSStackView(views: [NSTextField(labelWithString: L10n.tr("paperSize.title")), paper]), at: 0)
        let zoom = NSStackView()
        zoom.addArrangedSubview(NSTextField(labelWithString: L10n.tr("toolbar.zoom")))
        for id in [Self.itemFontDown, Self.itemFontUp] {
            if let control = toolbar(self, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false)?.view {
                zoom.addArrangedSubview(control)
            }
        }
        stack.addArrangedSubview(zoom)
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 380, height: 285)
        popover.behavior = .transient
        appearancePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// 서체 선택 팝업 — 지금 머신에 설치된 서체만 담는다.
    ///
    /// 각 항목의 `representedObject` 에 `ReadingFont.rawValue` 를 실어 보낸다. 목록이
    /// 설치 상황에 따라 달라지므로 선택 인덱스로 서체를 되짚으면 어긋난다.
    private func fontPopUpItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = L10n.tr("reader.font"); item.toolTip = L10n.tr("reader.font")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 26),
                                  pullsDown: false)
        let fonts = ReaderMetrics.availableReadingFonts
        for f in fonts {
            popup.addItem(withTitle: L10n.tr(f.locKey))
            popup.lastItem?.representedObject = f.rawValue
            // 항목을 그 서체로 그려 준다 — 고르기 전에 생김새가 보이도록.
            if let menuItem = popup.lastItem {
                let font = ReaderMetrics.readerFont(family: f, size: 13, traits: [])
                menuItem.attributedTitle = NSAttributedString(string: L10n.tr(f.locKey),
                                                              attributes: [.font: font])
            }
        }
        // 저장된 서체가 이 머신에 없으면(폰트를 지운 경우) 자동 명조로 표시한다.
        let current = SettingsManager.shared.readingFont
        popup.selectItem(at: fonts.firstIndex(of: current) ?? 0)

        popup.target = target
        popup.action = #selector(EditorWindowController.changeReaderFont(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        popup.heightAnchor.constraint(equalToConstant: 26).isActive = true
        item.view = popup
        return item
    }

    private func segmentItem(_ id: NSToolbarItem.Identifier, label: String,
                             labels: [String], selected: Int, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label; item.toolTip = label
        let width = CGFloat(labels.count) * 44
        let seg = NSSegmentedControl(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        seg.segmentCount = labels.count
        for (i, l) in labels.enumerated() { seg.setLabel(l, forSegment: i) }
        seg.trackingMode = .selectOne
        seg.selectedSegment = selected
        if id == Self.itemWidth { widthControl = seg }
        // 세그먼트는 책임 체인을 안 타므로 target 에 직접 바인딩(FormatToolbar 와 동일 처방).
        seg.target = target
        seg.action = action
        seg.translatesAutoresizingMaskIntoConstraints = false
        seg.widthAnchor.constraint(equalToConstant: width).isActive = true
        seg.heightAnchor.constraint(equalToConstant: 26).isActive = true
        item.view = seg
        return item
    }

    private func iconItem(_ id: NSToolbarItem.Identifier, label: String,
                          symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label; item.toolTip = label
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 26))
        button.image = image
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.setButtonType(.momentaryPushIn)
        // Plain NSButtons in toolbar items DO traverse the responder chain reliably,
        // but for consistency (and because the action targets the window controller
        // explicitly) we bind directly to ReaderToolbar.target.
        button.target = target
        button.action = action
        item.view = button
        return item
    }
}
