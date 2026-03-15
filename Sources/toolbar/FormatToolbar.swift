import AppKit

class FormatToolbar: NSToolbar {

    weak var target: AnyObject?

    private static let itemBold         = NSToolbarItem.Identifier("bold")
    private static let itemItalic       = NSToolbarItem.Identifier("italic")
    private static let itemCode         = NSToolbarItem.Identifier("inlineCode")
    private static let itemH1           = NSToolbarItem.Identifier("heading1")
    private static let itemH2           = NSToolbarItem.Identifier("heading2")
    private static let itemH3           = NSToolbarItem.Identifier("heading3")
    private static let itemBody         = NSToolbarItem.Identifier("bodyText")
    private static let itemUL           = NSToolbarItem.Identifier("unorderedList")
    private static let itemOL           = NSToolbarItem.Identifier("orderedList")
    private static let itemBlockquote   = NSToolbarItem.Identifier("blockquote")
    private static let itemLink         = NSToolbarItem.Identifier("link")
    private static let itemHR            = NSToolbarItem.Identifier("horizontalRule")
    private static let itemLineSpacing   = NSToolbarItem.Identifier("lineSpacing")

    // 상태 표시용 버튼 참조
    private weak var boldButton: NSButton?
    private weak var italicButton: NSButton?
    private weak var codeButton: NSButton?
    private weak var h1Button: NSButton?
    private weak var h2Button: NSButton?
    private weak var h3Button: NSButton?
    private weak var bodyButton: NSButton?
    private weak var ulButton: NSButton?
    private weak var olButton: NSButton?
    private weak var blockquoteButton: NSButton?
    private weak var linkButton: NSButton?

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)
        delegate = self
        displayMode = .iconOnly
        allowsUserCustomization = false
        autosavesConfiguration = false
    }

    // MARK: - State Update

    func updateState(attributes: [NSAttributedString.Key: Any]) {
        let font      = attributes[.font] as? NSFont
        let traits    = font?.fontDescriptor.symbolicTraits ?? []
        let blockType = attributes[.mdBlockType] as? String ?? "body"
        let isCode    = attributes[.mdInlineCode] as? Bool == true
        let hasLink   = attributes[.link] != nil

        boldButton?.state       = traits.contains(.bold)         ? .on : .off
        italicButton?.state     = traits.contains(.italic)       ? .on : .off
        codeButton?.state       = isCode                         ? .on : .off
        h1Button?.state         = (blockType == "h1")            ? .on : .off
        h2Button?.state         = (blockType == "h2")            ? .on : .off
        h3Button?.state         = (blockType == "h3")            ? .on : .off
        bodyButton?.state       = (blockType == "body")          ? .on : .off
        ulButton?.state         = (blockType == "ul")            ? .on : .off
        olButton?.state         = (blockType == "ol")            ? .on : .off
        blockquoteButton?.state = (blockType == "blockquote")    ? .on : .off
        linkButton?.state       = hasLink                        ? .on : .off
    }
}

// MARK: - NSToolbarDelegate

extension FormatToolbar: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            FormatToolbar.itemBody,
            FormatToolbar.itemH1,
            FormatToolbar.itemH2,
            FormatToolbar.itemH3,
            .space,
            FormatToolbar.itemBold,
            FormatToolbar.itemItalic,
            FormatToolbar.itemCode,
            .space,
            FormatToolbar.itemUL,
            FormatToolbar.itemOL,
            FormatToolbar.itemBlockquote,
            .space,
            FormatToolbar.itemLink,
            FormatToolbar.itemHR,
            .space,
            FormatToolbar.itemLineSpacing,
            .flexibleSpace
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {

        switch itemIdentifier {
        case FormatToolbar.itemBold:
            let item = makeItem(itemIdentifier, label: "굵게", systemImage: "bold",
                                action: #selector(EditorViewController.toggleBold))
            boldButton = item.view as? NSButton; return item
        case FormatToolbar.itemItalic:
            let item = makeItem(itemIdentifier, label: "기울임", systemImage: "italic",
                                action: #selector(EditorViewController.toggleItalic))
            italicButton = item.view as? NSButton; return item
        case FormatToolbar.itemCode:
            let item = makeItem(itemIdentifier, label: "코드", systemImage: "chevron.left.forwardslash.chevron.right",
                                action: #selector(EditorViewController.toggleInlineCode))
            codeButton = item.view as? NSButton; return item
        case FormatToolbar.itemH1:
            let item = makeTextItem(itemIdentifier, label: "H1", text: "H1",
                                    action: #selector(EditorViewController.setHeading1))
            h1Button = item.view as? NSButton; return item
        case FormatToolbar.itemH2:
            let item = makeTextItem(itemIdentifier, label: "H2", text: "H2",
                                    action: #selector(EditorViewController.setHeading2))
            h2Button = item.view as? NSButton; return item
        case FormatToolbar.itemH3:
            let item = makeTextItem(itemIdentifier, label: "H3", text: "H3",
                                    action: #selector(EditorViewController.setHeading3))
            h3Button = item.view as? NSButton; return item
        case FormatToolbar.itemBody:
            let item = makeTextItem(itemIdentifier, label: "본문", text: "T",
                                    action: #selector(EditorViewController.setBodyText))
            bodyButton = item.view as? NSButton; return item
        case FormatToolbar.itemUL:
            let item = makeItem(itemIdentifier, label: "목록", systemImage: "list.bullet",
                                action: #selector(EditorViewController.toggleUnorderedList))
            ulButton = item.view as? NSButton; return item
        case FormatToolbar.itemOL:
            let item = makeItem(itemIdentifier, label: "번호 목록", systemImage: "list.number",
                                action: #selector(EditorViewController.toggleOrderedList))
            olButton = item.view as? NSButton; return item
        case FormatToolbar.itemBlockquote:
            let item = makeItem(itemIdentifier, label: "인용", systemImage: "text.quote",
                                action: #selector(EditorViewController.toggleBlockquote))
            blockquoteButton = item.view as? NSButton; return item
        case FormatToolbar.itemLink:
            let item = makeItem(itemIdentifier, label: "링크", systemImage: "link",
                                action: #selector(EditorViewController.insertLink))
            linkButton = item.view as? NSButton; return item
        case FormatToolbar.itemHR:
            return makeItem(itemIdentifier, label: "구분선", systemImage: "minus",
                            action: #selector(EditorViewController.insertHorizontalRule))
        case FormatToolbar.itemLineSpacing:
            return makeLineSpacingItem(itemIdentifier)
        default:
            return nil
        }
    }

    // MARK: - Item Builders

    private func makeItem(_ identifier: NSToolbarItem.Identifier,
                          label: String,
                          systemImage: String,
                          action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: label)?
            .withSymbolConfiguration(config)

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 26))
        button.image = image
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.setButtonType(.pushOnPushOff)
        button.action = action
        button.target = nil
        item.view = button
        return item
    }

    private func makeTextItem(_ identifier: NSToolbarItem.Identifier,
                              label: String,
                              text: String,
                              action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 26))
        button.title = text
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.setButtonType(.pushOnPushOff)
        button.action = action
        button.target = nil
        item.view = button
        return item
    }

    private func makeLineSpacingItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "줄 간격"
        item.toolTip = "줄 간격"

        let seg = NSSegmentedControl(frame: NSRect(x: 0, y: 0, width: 96, height: 26))
        seg.segmentCount = 3
        seg.setLabel("1×", forSegment: 0)
        seg.setLabel("1.5×", forSegment: 1)
        seg.setLabel("2×", forSegment: 2)
        seg.trackingMode = .selectOne
        seg.selectedSegment = 0
        seg.action = #selector(EditorViewController.changeLineSpacing(_:))
        seg.target = nil
        item.view = seg
        return item
    }
}
