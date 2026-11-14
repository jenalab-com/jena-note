import AppKit

/// 헤더(툴바) 컨트롤 공통 규칙 — 높이 28pt, 테두리 없음, 아이콘 한 가지 색,
/// hover/켜짐일 때만 사이드바 선택 pill 비율(높이의 1/3)의 옅은 배경.
/// 시스템 베젤(유리 캡슐·세그먼트 구분선)에 기대지 않아 모든 컨트롤이 같은 결로 보인다.
enum HeaderStyle {
    static let height: CGFloat = 28
    static let iconPointSize: CGFloat = 14
    /// B·I·AI 같은 글자 아이콘 — 심볼과 눈높이가 맞도록 조금 크게
    static let letterPointSize: CGFloat = 15
    static let cornerRatio: CGFloat = SidebarStyle.pillRadius / (SidebarStyle.rowHeight - 3)

    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static let tint = dynamic("header.tint", light: NSColor.black.withAlphaComponent(0.72),
                              dark: NSColor.white.withAlphaComponent(0.80))
    static let hoverFill = SidebarStyle.hoverFill
    static let onFill = dynamic("header.onFill", light: NSColor.black.withAlphaComponent(0.09),
                                dark: NSColor.white.withAlphaComponent(0.14))

    static func symbol(_ name: String, label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: iconPointSize, weight: .regular))
    }

    /// 글자 하나(또는 둘)를 템플릿 이미지로 — B(굵게)·I(기울임)·AI.
    static func letters(_ text: String, font: NSFont, label: String) -> NSImage {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = string.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { rect in
            string.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    static func pill(_ rect: NSRect) -> NSBezierPath {
        let radius = rect.height * cornerRatio
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    /// 템플릿 이미지를 한 가지 색으로, 픽셀 격자에 맞춰 가운데 그린다.
    static func drawTinted(_ image: NSImage, in bounds: NSRect, color: NSColor, view: NSView) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = image.size
        let target = view.backingAlignedRect(NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                                    width: size.width, height: size.height),
                                             options: .alignAllEdgesNearest)
        let resolved = color.usingColorSpace(.sRGB) ?? color
        ctx.saveGState()
        ctx.setAlpha(resolved.alphaComponent)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: target)
        resolved.withAlphaComponent(1).set()
        target.fill(using: .sourceAtop)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// 헤더 아이콘 버튼 — 28×28, 테두리 없음. 켜짐(굵게·기울임 등)이면 진한 배경, hover 면 옅은 배경.
/// `title` 은 접근성·테스트용으로만 남고 화면에는 `image` 만 그린다.
final class HeaderButton: NSButton {
    private var isHovering = false { didSet { needsDisplay = true } }
    /// 정사각형 한 변 — 헤더 28, 하단 바 26, 글자 크기 −/+ 22
    private var side: CGFloat = HeaderStyle.height

    convenience init(image: NSImage?, label: String, target: AnyObject?, action: Selector?, toggles: Bool = false,
                     size: CGFloat = HeaderStyle.height) {
        self.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        side = size
        title = label
        self.image = image
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(toggles ? .pushOnPushOff : .momentaryChange)
        toolTip = label
        setAccessibilityLabel(label)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["headerHover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["headerHover": true]))
    }
    override func mouseEntered(with event: NSEvent) { isHovering = isEnabled }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override var isEnabled: Bool { didSet { if !isEnabled { isHovering = false }; needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        if state == .on || isHighlighted {
            HeaderStyle.onFill.setFill()
            HeaderStyle.pill(box).fill()
        } else if isHovering {
            HeaderStyle.hoverFill.setFill()
            HeaderStyle.pill(box).fill()
        }
        guard let image else { return }
        let color = isEnabled ? HeaderStyle.tint : HeaderStyle.tint.withAlphaComponent(0.28)
        HeaderStyle.drawTinted(image, in: bounds, color: color, view: self)
    }
}

/// 여러 개를 함께 켜고 끄는 아이콘 묶음(대사·인용·생각) — NSSegmentedControl 동작은 그대로,
/// 그리기만 HeaderButton 과 같게: 구분선·테두리 없이 칸마다 28×28 아이콘.
final class HeaderSegmentedControl: NSSegmentedControl {
    private var hoveredSegment = -1 { didSet { if oldValue != hoveredSegment { needsDisplay = true } } }
    /// 칸 하나의 크기 — 헤더 28, 하단 바 26
    var cellSize: CGFloat = HeaderStyle.height { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(segmentCount) * cellSize, height: cellSize)
    }

    private func segmentRect(_ index: Int) -> NSRect {
        let width = bounds.width / CGFloat(max(1, segmentCount))
        return NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["headerHover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["headerHover": true]))
    }
    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        hoveredSegment = isEnabled ? min(segmentCount - 1, max(0, Int(x / (bounds.width / CGFloat(max(1, segmentCount)))))) : -1
    }
    override func mouseExited(with event: NSEvent) { hoveredSegment = -1 }
    override func setSelected(_ selected: Bool, forSegment segment: Int) {
        super.setSelected(selected, forSegment: segment)
        needsDisplay = true
    }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        for index in 0..<segmentCount {
            let rect = segmentRect(index)
            let box = NSRect(x: rect.midX - cellSize / 2 + 1, y: rect.midY - cellSize / 2 + 1,
                             width: cellSize - 2, height: cellSize - 2)
            if isSelected(forSegment: index) {
                HeaderStyle.onFill.setFill()
                HeaderStyle.pill(box).fill()
            } else if index == hoveredSegment {
                HeaderStyle.hoverFill.setFill()
                HeaderStyle.pill(box).fill()
            }
            guard let image = image(forSegment: index) else { continue }
            // 칸별로 꺼진 것(예: AI 대화 중 페이징)도 흐리게
            let enabled = isEnabled && isEnabled(forSegment: index)
            let color = enabled ? HeaderStyle.tint : HeaderStyle.tint.withAlphaComponent(0.28)
            HeaderStyle.drawTinted(image, in: rect, color: color, view: self)
        }
    }
}

/// 툴바가 테두리 있는 시스템 컨트롤(선택 상자·색상 상자·세그먼트) 뒤에 깔아 버리는 유리 캡슐을 막는
/// 평범한 상자. 안의 컨트롤은 그대로 동작하고, `control` 로 꺼낼 수 있다.
final class HeaderItemContainer: NSView {
    let control: NSView

    init(_ control: NSView) {
        self.control = control
        super.init(frame: NSRect(origin: .zero, size: control.fittingSize))
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: HeaderStyle.height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension NSToolbarItem {
    /// 헤더 항목 안의 실제 컨트롤 — 유리 캡슐을 막는 상자로 감싸져 있어도 꺼낸다.
    var control: NSView? {
        (view as? HeaderItemContainer)?.control ?? (view as? HeaderFieldContainer)?.control ?? view
    }
}

/// 헤더 찾기 칸 — 시스템 유리 대신 사이드바 "전체 검색"과 같은 둥근 회색 바탕.
final class HeaderFieldContainer: NSView {
    let control: NSView

    init(_ control: NSView) {
        self.control = control
        super.init(frame: NSRect(origin: .zero, size: control.fittingSize))
        if let field = control as? NSTextField {
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: HeaderStyle.height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        SidebarStyle.trackFill.setFill()
        HeaderStyle.pill(bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// 헤더 묶음 사이의 얇은 세로선 — 서식·목록·문장부호·삽입을 눈으로 나눈다.
final class HeaderDivider: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 9, height: HeaderStyle.height) }
    override func draw(_ dirtyRect: NSRect) {
        SidebarStyle.hairline.setFill()
        NSRect(x: bounds.midX - 0.5, y: bounds.midY - 8, width: 1, height: 16).fill()
    }
}
