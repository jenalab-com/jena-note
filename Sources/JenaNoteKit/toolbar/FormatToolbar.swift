import AppKit

class FormatToolbar: NSToolbar {

    weak var target: AnyObject?
    weak var aiTarget: AnyObject?
    private static let itemAI = NSToolbarItem.Identifier("aiChat")

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
    private static let itemImage         = NSToolbarItem.Identifier("image")
    private static let itemHR            = NSToolbarItem.Identifier("horizontalRule")
    private static let itemColor         = NSToolbarItem.Identifier("textColor")
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

    private var hasSelectedText = false
    func updateSelection(hasSelectedText: Bool) {
        self.hasSelectedText = hasSelectedText
        codeButton?.isEnabled = hasSelectedText
    }

    // MARK: - State Update

    func updateState(attributes: [NSAttributedString.Key: Any]) {
        let font      = attributes[.font] as? NSFont
        let traits    = font?.fontDescriptor.symbolicTraits ?? []
        let blockType = attributes[.mdBlockType] as? String ?? "body"
        let isCode    = attributes[.mdInlineCode] as? Bool == true
        let hasLink   = attributes[.link] != nil

        // 제목은 글꼴 자체가 굵다 — 작가가 굵게 한 게 아니므로 B 를 켜지 않는다.
        let isHeading = ["h1", "h2", "h3"].contains(blockType)
        boldButton?.state       = traits.contains(.bold) && !isHeading ? .on : .off
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
            FormatToolbar.itemImage,
            FormatToolbar.itemHR,
            .space,
            FormatToolbar.itemColor,
            FormatToolbar.itemLineSpacing,
            .space,
            FormatToolbar.itemAI,
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
        case FormatToolbar.itemAI:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.visibilityPriority = .high
            item.label = L10n.tr("ai.title")
            item.view = NSButton(title: "AI", target: aiTarget, action: #selector(EditorWindowController.toggleAI(_:)))
            item.toolTip = L10n.tr("ai.title")
            return item
        case FormatToolbar.itemBold:
            let item = makeItem(itemIdentifier, label: "굵게", systemImage: "bold",
                                action: #selector(EditorViewController.toggleBold))
            boldButton = item.view as? NSButton
            // SF Symbols 의 bold 글리프는 비정수 배율 화면에서 옆으로 퍼져 보여, 글꼴의 B 를 쓴다.
            boldButton?.image = HeaderStyle.letters("B", font: .systemFont(ofSize: HeaderStyle.letterPointSize, weight: .bold), label: "굵게")
            return item
        case FormatToolbar.itemItalic:
            let item = makeItem(itemIdentifier, label: "기울임", systemImage: "italic",
                                action: #selector(EditorViewController.toggleItalic))
            italicButton = item.view as? NSButton
            italicButton?.image = HeaderStyle.letters("I", font: NSFontManager.shared.convert(
                .systemFont(ofSize: HeaderStyle.letterPointSize, weight: .regular), toHaveTrait: .italicFontMask), label: "기울임")
            return item
        case FormatToolbar.itemCode:
            let item = makeTextItem(itemIdentifier, label: L10n.tr("toolbar.inlineCode"), text: L10n.tr("toolbar.inlineCode"),
                                    action: #selector(EditorViewController.toggleInlineCode))
            item.toolTip = L10n.tr("toolbar.inlineCodeHint")
            codeButton = item.view as? NSButton
            codeButton?.toolTip = item.toolTip
            codeButton?.setAccessibilityLabel(item.label)
            codeButton?.isEnabled = hasSelectedText
            codeButton?.image = HeaderStyle.symbol("curlybraces", label: item.label)
            return item
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
        case FormatToolbar.itemImage:
            return makeItem(itemIdentifier, label: "이미지", systemImage: "photo",
                            action: #selector(EditorViewController.insertImage))
        case FormatToolbar.itemHR:
            return makeItem(itemIdentifier, label: "구분선", systemImage: "minus",
                            action: #selector(EditorViewController.insertHorizontalRule))
        case FormatToolbar.itemColor:
            return makeColorWellItem(itemIdentifier)
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
        let button = HeaderButton(image: HeaderStyle.symbol(systemImage, label: label), label: label,
                                  target: target, action: action, toggles: true)
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
        let button = HeaderButton(image: nil, label: text, target: target, action: action, toggles: true)
        item.view = button
        return item
    }

    private func makeColorWellItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let label = L10n.tr("toolbar.textColor")
        item.label = label
        item.toolTip = label

        let well = CircleColorWell(frame: NSRect(x: 0, y: 0, width: HeaderStyle.height, height: HeaderStyle.height))
        well.color = .labelColor
        // NSColorWell도 NSToolbarItem.view 안에서 책임 체인 디스패치가 불안정 —
        // FormatToolbar.target에 직접 묶는다 (line spacing과 동일한 처방).
        well.target = target
        well.action = #selector(EditorViewController.changeTextColor(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: HeaderStyle.height).isActive = true
        well.heightAnchor.constraint(equalToConstant: HeaderStyle.height).isActive = true
        item.view = well
        return item
    }

    private func makeLineSpacingItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let label = L10n.tr("toolbar.lineSpacing")
        item.label = label
        item.toolTip = label

        let seg = NSSegmentedControl(frame: NSRect(x: 0, y: 0, width: 96, height: 26))
        seg.segmentCount = 3
        seg.setLabel("1×", forSegment: 0)
        seg.setLabel("1.5×", forSegment: 1)
        seg.setLabel("2×", forSegment: 2)
        seg.trackingMode = .selectOne
        seg.selectedSegment = 0
        seg.action = #selector(EditorViewController.changeLineSpacing(_:))
        // NSSegmentedControl in NSToolbarItem.view does not reliably traverse
        // the responder chain when target is nil on macOS — bind directly to
        // the editor view controller via FormatToolbar.target.
        seg.target = target
        seg.translatesAutoresizingMaskIntoConstraints = false
        seg.widthAnchor.constraint(equalToConstant: 96).isActive = true
        seg.heightAnchor.constraint(equalToConstant: 26).isActive = true
        item.view = seg
        return item
    }
}

/// 동그란 글자색 버튼 — 고른 색으로 채운 원 + 얇은 테두리. 누르면 색상 패널이 열린다(NSColorWell 동작 그대로).
final class CircleColorWell: NSColorWell {
    override func draw(_ dirtyRect: NSRect) {
        // 다른 아이콘(약 16pt)과 같은 눈높이의 작은 원 — 28pt 칸 가운데.
        let side: CGFloat = 15
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let circle = NSBezierPath(ovalIn: rect)
        color.setFill()
        circle.fill()
        // 흰색·검은색도 배경과 구분되도록 얇은 테두리, 색상 패널과 연결된 동안은 강조색 링.
        (isActive ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        circle.lineWidth = isActive ? 2 : 1
        circle.stroke()
    }
}
