import AppKit

// MARK: - Design Tokens

/// 사이드바 디자인 토큰 — 밝은/어두운 모드를 dynamic color 로 한 곳에서 정의한다.
/// 방향: 무채색 단일 톤, 선택은 블랙 필(로고와 같은 #111), 나머지는 옅은 회색 레이어.
enum SidebarStyle {

    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static let ink = NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1)

    static let background = dynamic("sidebar.background",
                                     light: NSColor(srgbRed: 0.969, green: 0.969, blue: 0.973, alpha: 1),
                                     dark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1))
    static let selectionFill = dynamic("sidebar.selectionFill",
                                        light: ink,
                                        dark: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.953, alpha: 1))
    static let selectionText = dynamic("sidebar.selectionText",
                                        light: .white, dark: ink)
    static let hoverFill = dynamic("sidebar.hoverFill",
                                    light: NSColor.black.withAlphaComponent(0.045),
                                    dark: NSColor.white.withAlphaComponent(0.065))
    static let guide = dynamic("sidebar.guide",
                                light: NSColor.black.withAlphaComponent(0.10),
                                dark: NSColor.white.withAlphaComponent(0.12))
    static let trackFill = dynamic("sidebar.trackFill",
                                    light: NSColor.black.withAlphaComponent(0.05),
                                    dark: NSColor.white.withAlphaComponent(0.07))
    static let knobFill = dynamic("sidebar.knobFill",
                                   light: .white,
                                   dark: NSColor(srgbRed: 0.235, green: 0.235, blue: 0.247, alpha: 1))
    static let hairline = dynamic("sidebar.hairline",
                                   light: NSColor.black.withAlphaComponent(0.07),
                                   dark: NSColor.white.withAlphaComponent(0.08))
    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let icon = dynamic("sidebar.icon",
                               light: NSColor.black.withAlphaComponent(0.55),
                               dark: NSColor.white.withAlphaComponent(0.60))

    // MARK: Metrics

    static let rowHeight: CGFloat = 30
    /// 행 pill 이 사이드바 가장자리에서 떨어지는 거리
    static let rowInset: CGFloat = 10
    /// 레벨 0 셀(아이콘) 시작 x
    static let cellOrigin: CGFloat = 20
    static let indent: CGFloat = 20
    /// pill 안에서 아이콘 앞 여백
    static let pillPadding: CGFloat = 8
    static let iconSize: CGFloat = 16
    static let pillRadius: CGFloat = 9

    static func cellX(level: Int) -> CGFloat { cellOrigin + CGFloat(level) * indent }
    static func pillX(level: Int) -> CGFloat { level == 0 ? rowInset : cellX(level: level) - pillPadding }
    /// 조상 레벨 l 의 아이콘 중심 — 들여쓰기 가이드 선이 지나가는 x
    static func guideX(ancestorLevel l: Int) -> CGFloat { cellX(level: l) + 2 + iconSize / 2 }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

// MARK: - Background

/// 사이드바 전체 배경 — NSSplitViewItem(sidebar)이 깔아주는 반투명 재질 대신 단정한 무채색 면.
final class SidebarBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        SidebarStyle.background.setFill()
        bounds.intersection(dirtyRect).fill() // 자기 영역 밖(clipsToBounds=false)은 칠하지 않는다
    }
}

/// 1px 구분선
final class SidebarHairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SidebarStyle.hairline.setFill()
        bounds.fill()
    }
}

// MARK: - Logo Mark

/// JenaNote 로고 마크 — Resources/JenaNote.svg 의 도형을 그대로 코드로 그린다
/// (번들 리소스 없이 어떤 크기에서도 선명하게). viewBox 64…960 영역을 뷰에 꽉 채운다.
final class SidebarLogoView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width, bounds.height) / 896
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -64, y: -64)

        // 바탕 — 블랙 라운드 스퀘어
        let base = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                          cornerWidth: 188, cornerHeight: 188, transform: nil)
        ctx.addPath(base)
        ctx.setFillColor(SidebarStyle.ink.cgColor)
        ctx.fillPath()
        if effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            // 어두운 배경 위에서 윤곽이 묻히지 않도록 아주 옅은 테두리
            ctx.addPath(base)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
            ctx.setLineWidth(1 / s)
            ctx.strokePath()
        }

        ctx.translateBy(x: 36, y: -27)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.white.cgColor)

        // 뒷장 — 앞 도형 둘레를 비워두는 clearance 마스크(even-odd 클립)
        ctx.saveGState()
        ctx.addRect(CGRect(x: -200, y: -200, width: 1424, height: 1424))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 192, y: 202, width: 656, height: 566),
                           cornerWidth: 126, cornerHeight: 126, transform: nil))
        ctx.clip(using: .evenOdd)
        ctx.translateBy(x: -45, y: 110)
        ctx.translateBy(x: 520, y: 485)
        ctx.rotate(by: 12 * .pi / 180)
        ctx.translateBy(x: -520, y: -485)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 244, y: 254, width: 552, height: 462),
                           cornerWidth: 42, cornerHeight: 42, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // J 자 노트 외곽
        let j = CGMutablePath()
        j.move(to: CGPoint(x: 500, y: 280))
        j.addArc(tangent1End: CGPoint(x: 770, y: 280), tangent2End: CGPoint(x: 770, y: 690), radius: 48)
        j.addArc(tangent1End: CGPoint(x: 770, y: 690), tangent2End: CGPoint(x: 270, y: 690), radius: 48)
        j.addArc(tangent1End: CGPoint(x: 270, y: 690), tangent2End: CGPoint(x: 270, y: 555), radius: 48)
        j.addLine(to: CGPoint(x: 270, y: 555))
        ctx.addPath(j)
        ctx.setLineWidth(52)
        ctx.strokePath()

        // 본문 줄
        for (y, x2) in [(420.0, 660.0), (505.0, 660.0), (590.0, 565.0)] {
            ctx.move(to: CGPoint(x: 365, y: y))
            ctx.addLine(to: CGPoint(x: x2, y: y))
        }
        ctx.setLineWidth(44)
        ctx.strokePath()

        ctx.restoreGState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Outline View

/// 사이드바 트리 — 기본 disclosure 삼각형을 숨기고(행 오른쪽 chevron 으로 대체),
/// 셀을 디자인 토큰 기준 들여쓰기에 맞춰 배치하며, hover 행을 추적한다.
class SidebarOutlineView: NSOutlineView {

    private(set) var hoverRow = -1

    func configureSidebarAppearance() {
        style = .plain
        selectionHighlightStyle = .regular
        backgroundColor = .clear
        headerView = nil
        intercellSpacing = NSSize(width: 0, height: 0)
        indentationPerLevel = SidebarStyle.indent
        rowSizeStyle = .custom
        rowHeight = SidebarStyle.rowHeight
        usesAutomaticRowHeights = false
        allowsMultipleSelection = false
        autoresizesOutlineColumn = false
        focusRingType = .none
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        guard row >= 0 else { return frame }
        let x = SidebarStyle.cellX(level: level(forRow: row))
        frame.origin.x = x
        frame.size.width = max(0, bounds.width - x - SidebarStyle.rowInset - 8)
        return frame
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["sidebarHover"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["sidebarHover": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    override func reloadData() {
        hoverRow = -1
        super.reloadData()
    }

    private func setHoveredRow(_ row: Int) {
        guard row != hoverRow else { return }
        let old = hoverRow
        hoverRow = row
        for r in [old, row] where r >= 0 && r < numberOfRows {
            (rowView(atRow: r, makeIfNecessary: false) as? SidebarRowView)?.isHovered = (r == hoverRow)
        }
    }
}

// MARK: - Row View

/// pill 모양 선택/hover + 조상 레벨 들여쓰기 가이드 선을 그리는 행.
final class SidebarRowView: NSTableRowView {

    var level = 0 { didSet { needsDisplay = true } }
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }

    private var pillRect: NSRect {
        let x = SidebarStyle.pillX(level: level)
        return NSRect(x: x, y: 1.5,
                      width: max(0, bounds.width - x - SidebarStyle.rowInset),
                      height: bounds.height - 3)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // 조상 레벨마다 세로 가이드 선 (행 위아래로 이어져 하나의 선처럼 보인다)
        if level > 0 {
            SidebarStyle.guide.setFill()
            for l in 0..<level {
                NSRect(x: SidebarStyle.guideX(ancestorLevel: l) - 0.5, y: 0, width: 1, height: bounds.height).fill()
            }
        }
        if isHovered && !isSelected {
            SidebarStyle.hoverFill.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: SidebarStyle.pillRadius, yRadius: SidebarStyle.pillRadius).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        SidebarStyle.selectionFill.setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: SidebarStyle.pillRadius, yRadius: SidebarStyle.pillRadius).fill()
    }

    /// 시스템의 emphasized 배경 스타일은 쓰지 않는다 — 실제 창에서 아이콘·글자를 흰색으로 덮어써
    /// 다크 모드의 흰 pill 위에서 사라진다. 대신 선택 여부를 셀에 직접 알려 색을 정한다.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
            syncCells()
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SidebarCellView)?.isRowSelected = isSelected
    }

    private func syncCells() {
        for case let cell as SidebarCellView in subviews { cell.isRowSelected = isSelected }
    }
}

// MARK: - Cell View

/// 아이콘 + 이름 + (펼칠 수 있으면) 오른쪽 chevron.
final class SidebarCellView: NSTableCellView {

    let chevronView = NSImageView()
    private var baseTextColor: NSColor = SidebarStyle.text
    private var baseIconColor: NSColor = SidebarStyle.icon
    private var usesAttributedText = false
    private var baseAttributed: NSAttributedString?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        self.imageView = imageView
        addSubview(imageView)

        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.textField = textField
        addSubview(textField)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.imageScaling = .scaleNone
        addSubview(chevronView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: SidebarStyle.iconSize),
            imageView.heightAnchor.constraint(equalToConstant: SidebarStyle.iconSize),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 9),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -6),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, font: NSFont, textColor: NSColor, icon: NSImage?, iconColor: NSColor = SidebarStyle.icon) {
        usesAttributedText = false
        baseAttributed = nil
        textField?.font = font
        textField?.stringValue = text
        imageView?.image = icon
        baseTextColor = textColor
        baseIconColor = iconColor
        setChevron(nil)
        applyColors()
    }

    func configure(attributed: NSAttributedString, icon: NSImage?) {
        usesAttributedText = true
        baseAttributed = attributed
        textField?.attributedStringValue = attributed
        imageView?.image = icon
        baseIconColor = SidebarStyle.icon
        setChevron(nil)
        applyColors()
    }

    /// nil = 펼칠 수 없음(숨김), true/false = 펼침 여부
    func setChevron(_ expanded: Bool?) {
        guard let expanded = expanded else {
            chevronView.image = nil
            chevronView.isHidden = true
            return
        }
        chevronView.isHidden = false
        chevronView.image = SidebarStyle.symbol(expanded ? "chevron.down" : "chevron.right", size: 10, weight: .semibold)
    }

    /// 선택 줄인지 — 행(SidebarRowView)이 직접 알려준다. 포커스와 무관하게 늘 반전 색.
    var isRowSelected = false { didSet { if oldValue != isRowSelected { applyColors() } } }

    private func applyColors() {
        let selected = isRowSelected
        if usesAttributedText, let base = baseAttributed {
            if selected {
                let inverted = NSMutableAttributedString(attributedString: base)
                inverted.addAttribute(.foregroundColor, value: SidebarStyle.selectionText,
                                      range: NSRange(location: 0, length: inverted.length))
                textField?.attributedStringValue = inverted
            } else {
                textField?.attributedStringValue = base
            }
        } else {
            textField?.textColor = selected ? SidebarStyle.selectionText : baseTextColor
        }
        imageView?.contentTintColor = selected ? SidebarStyle.selectionText : baseIconColor
        chevronView.contentTintColor = selected
            ? SidebarStyle.selectionText.withAlphaComponent(0.7)
            : SidebarStyle.secondaryText
    }
}

// MARK: - Icon Button

/// 테두리 없는 작은 아이콘 버튼 — hover 시 옅은 라운드 배경. `circled` 면 얇은 원형 테두리.
final class SidebarIconButton: NSButton {

    var circled = false { didSet { needsDisplay = true } }
    private var isHovering = false { didSet { needsDisplay = true } }
    /// NSButton 의 셀에 맡기면 심볼이 정렬 사각형 기준으로 축소·잘림(배지 달린 심볼)이 생겨
    /// 비정수 배율 화면에서 깨져 보인다. 이미지를 셀에 넣지 않고 직접 픽셀 정렬해 그린다.
    private var symbolImage: NSImage?

    convenience init(symbol: String, tooltip: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        symbolImage = SidebarStyle.symbol(symbol, size: 13, weight: .regular)
        title = ""
        imagePosition = .noImage
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["sidebarHover"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["sidebarHover": true]))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = isEnabled }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = circled ? rect.height / 2 : 6
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if isHovering {
            SidebarStyle.hoverFill.setFill()
            path.fill()
        }
        if circled {
            SidebarStyle.guide.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        guard let symbol = symbolImage, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 심볼의 전체 크기(배지 포함)를 가운데 두고 픽셀 격자에 맞춘다.
        let size = symbol.size
        let target = backingAlignedRect(NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                               width: size.width, height: size.height),
                                        options: .alignAllEdgesNearest)
        // sourceAtop 에 반투명 색을 쓰면 원래 심볼의 검정이 비쳐 진해진다 —
        // 색은 불투명하게 칠하고, 투명도는 레이어 전체에 건다.
        let base = (isEnabled && isHighlighted) ? SidebarStyle.text : SidebarStyle.icon
        let resolved = base.usingColorSpace(.sRGB) ?? base
        ctx.saveGState()
        ctx.setAlpha(resolved.alphaComponent * (isEnabled ? 1 : 0.3))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        symbol.draw(in: target)
        resolved.withAlphaComponent(1).set()
        target.fill(using: .sourceAtop)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

// MARK: - Pill Button (primary)

/// 블랙 pill 주 버튼 (빈 상태의 "폴더 추가…")
final class SidebarPillButton: NSButton {

    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        self.target = target
        self.action = action
        font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        translatesAutoresizingMaskIntoConstraints = false
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 28, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isHighlighted ? 0.8 : 1
        SidebarStyle.selectionFill.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: SidebarStyle.selectionText
        ]
        let text = NSAttributedString(string: title, attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

// MARK: - Select Box

/// 앱 공통 선택 상자 — 테두리 없이 "글자 + 작은 ⌄". 마우스를 올리거나 누르면
/// 사이드바 선택 pill 과 같은 모서리 비율(높이의 1/3)의 옅은 배경이 깔린다. 헤더 아이콘 버튼과 같은 결.
final class JenaPopUpButton: NSPopUpButton {
    override class var cellClass: AnyClass? {
        get { JenaPopUpButtonCell.self }
        set { }
    }

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        isBordered = true
        focusRingType = .none
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 설정 카드 안처럼 "입력 칸"으로 읽혀야 하는 곳 — 늘 옅은 바탕과 얇은 선을 깐다.
    var isFilled: Bool {
        get { (cell as? JenaPopUpButtonCell)?.isFilled ?? false }
        set { (cell as? JenaPopUpButtonCell)?.isFilled = newValue; needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += JenaPopUpButtonCell.chevronSpace + 6
        size.height = controlSize == .small ? 22 : HeaderStyle.height
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["selectHover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["selectHover": true]))
    }
    override func mouseEntered(with event: NSEvent) { (cell as? JenaPopUpButtonCell)?.isHovering = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { (cell as? JenaPopUpButtonCell)?.isHovering = false; needsDisplay = true }
}

final class JenaPopUpButtonCell: NSPopUpButtonCell {
    /// 오른쪽 ⌄ 자리
    static let chevronSpace: CGFloat = 12
    var isHovering = false
    var isFilled = false

    override init(textCell stringValue: String, pullsDown pullDown: Bool) {
        super.init(textCell: stringValue, pullsDown: pullDown)
        arrowPosition = .noArrow
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let box = frame.insetBy(dx: 1, dy: 1)
        if isFilled {
            let path = HeaderStyle.pill(box)
            (isHighlighted || isHovering ? HeaderStyle.onFill : SettingsStyle.buttonFill).setFill()
            path.fill()
            SidebarStyle.hairline.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isHighlighted {
            HeaderStyle.onFill.setFill()
            HeaderStyle.pill(box).fill()
        } else if isHovering {
            HeaderStyle.hoverFill.setFill()
            HeaderStyle.pill(box).fill()
        }
        guard let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) else { return }
        let slot = NSRect(x: box.maxX - Self.chevronSpace - 4, y: box.minY, width: Self.chevronSpace, height: box.height)
        let color = isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        HeaderStyle.drawTinted(chevron, in: slot, color: color, view: controlView)
    }

    /// 제목·아이콘은 왼쪽 여백을 두고, ⌄ 자리를 비워 그린다.
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var inner = super.drawingRect(forBounds: rect)
        inner.origin.x = rect.minX + 8
        inner.size.width = max(0, rect.width - 8 - Self.chevronSpace - 6)
        return inner
    }
}
