import AppKit

class ReaderToolbar: NSToolbar {

    weak var target: AnyObject?

    private static let itemExit  = NSToolbarItem.Identifier("readerExit")
    private static let itemMode  = NSToolbarItem.Identifier("readerPageMode")
    private static let itemFontFamily = NSToolbarItem.Identifier("readerFontFamily")
    private static let itemLineSpacing = NSToolbarItem.Identifier("readerLineSpacing")
    private static let itemFontDown = NSToolbarItem.Identifier("readerFontDown")
    private static let itemFontUp   = NSToolbarItem.Identifier("readerFontUp")

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)
        delegate = self
        displayMode = .iconOnly
        allowsUserCustomization = false
        autosavesConfiguration = false
    }
}

extension ReaderToolbar: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ReaderToolbar.itemExit, .space,
         ReaderToolbar.itemMode, .space,
         ReaderToolbar.itemFontFamily, .space,
         ReaderToolbar.itemLineSpacing, .space,
         ReaderToolbar.itemFontDown, ReaderToolbar.itemFontUp, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(t)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ReaderToolbar.itemExit:
            return iconItem(id, label: L10n.tr("reader.exit"), symbol: "pencil",
                            action: #selector(EditorWindowController.exitReadingMode(_:)))
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
            return item
        case ReaderToolbar.itemFontFamily:
            return segmentItem(id, label: L10n.tr("reader.font"),
                               labels: [L10n.tr("reader.serif"), L10n.tr("reader.sans")],
                               selected: SettingsManager.shared.readingFont == .sans ? 1 : 0,
                               action: #selector(EditorWindowController.changeReaderFont(_:)))
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
            return nil
        }
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
