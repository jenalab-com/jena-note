import AppKit

// 설정 창 공용 부품 — 메인 창과 같은 디자인 토큰(SidebarStyle·HeaderStyle)으로,
// 시스템 설정처럼 "페이지 제목 → 섹션 카드 → 설정 줄" 구조를 만든다.

enum SettingsStyle {
    static let navWidth: CGFloat = 200
    static let contentInset: CGFloat = 28
    static let rowMinHeight: CGFloat = 44
    static let cardRadius: CGFloat = 10
    static let controlHeight: CGFloat = 26
}

// MARK: - Page

/// 설정 한 페이지 — 큰 제목 아래로 섹션(머리말·카드·각주)을 쌓는다. 길면 스크롤된다.
final class SettingsPageView: NSView {
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    init(title: String) {
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        heading.textColor = .labelColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 52, left: SettingsStyle.contentInset,
                                        bottom: SettingsStyle.contentInset, right: SettingsStyle.contentInset)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(20, after: heading)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 섹션 하나 — 머리말(선택), 카드, 각주(선택).
    @discardableResult
    func addSection(_ header: String?, card: SettingsCard, footnote: String? = nil) -> SettingsCard {
        if let header {
            let label = NSTextField(labelWithString: header)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(6, after: label)
        }
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * SettingsStyle.contentInset).isActive = true
        var last: NSView = card
        if let footnote {
            let note = NSTextField(wrappingLabelWithString: footnote)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -8).isActive = true
            stack.setCustomSpacing(4, after: card)
            last = note
        }
        stack.setCustomSpacing(22, after: last)
        return card
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Card & Row

/// 설정 줄 묶음 — 옅은 회색 둥근 카드, 줄 사이에 얇은 선.
final class SettingsCard: NSView {
    private let stack = NSStackView()

    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = SidebarHairlineView()
                line.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(line)
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
                line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        SidebarStyle.trackFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: SettingsStyle.cardRadius, yRadius: SettingsStyle.cardRadius).fill()
    }
}

/// 설정 한 줄 — 왼쪽에 이름(과 설명), 오른쪽에 컨트롤. `content` 만 주면 줄 전체를 컨트롤이 쓴다.
final class SettingsRow: NSView {
    let titleLabel: NSTextField

    init(title: String? = nil, detail: String? = nil, titleLabel: NSTextField? = nil, control: NSView?) {
        self.titleLabel = titleLabel ?? NSTextField(labelWithString: title ?? "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel.font = .systemFont(ofSize: 13)
        self.titleLabel.textColor = .labelColor
        self.titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let texts = NSStackView(views: [self.titleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if let detail, !detail.isEmpty {
            let note = NSTextField(wrappingLabelWithString: detail)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            texts.addArrangedSubview(note)
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        }
        texts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(texts)
        var constraints = [
            texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsStyle.rowMinHeight)
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.leadingAnchor.constraint(greaterThanOrEqualTo: texts.trailingAnchor, constant: 16),
                control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8)
            ]
        } else {
            constraints.append(texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14))
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// 줄 전체를 차지하는 내용(상태 문구·표 등).
    init(content: NSView, inset: CGFloat = 14) {
        titleLabel = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Controls

/// 설정 버튼 — 사이드바 pill 비율. 주 버튼은 검은 pill, 나머지는 옅은 회색 pill.
final class SettingsButton: NSButton {
    var isPrimary = false { didSet { needsDisplay = true } }
    private var isHovering = false { didSet { needsDisplay = true } }

    convenience init(title: String, target: AnyObject?, action: Selector?, primary: Bool = false) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isPrimary = primary
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 12, weight: .medium)
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
    }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)])
        return NSSize(width: ceil(size.width) + 24, height: SettingsStyle.controlHeight)
    }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["settingsHover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["settingsHover": true]))
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pressed = isHighlighted || (isHovering && isEnabled)
        // 보조 버튼은 옅은 회색 — 흰 창 바탕 위에서도, 회색 카드 위에서도 보이게.
        let fill: NSColor = isPrimary ? SidebarStyle.selectionFill : (pressed ? SettingsStyle.buttonHover : HeaderStyle.onFill)
        let alpha: CGFloat = isEnabled ? (isPrimary && pressed ? 0.85 : 1) : 0.45
        fill.withAlphaComponent((fill.usingColorSpace(.sRGB)?.alphaComponent ?? 1) * alpha).setFill()
        HeaderStyle.pill(box).fill()
        let color: NSColor = isPrimary ? SidebarStyle.selectionText : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.45)
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

extension SettingsStyle {
    /// 보조 버튼에 마우스를 올리거나 누를 때
    static let buttonHover = NSColor(name: NSColor.Name("settings.buttonHover")) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.15)
    }

    /// 카드(옅은 회색) 위의 버튼·입력 칸 바탕 — 카드보다 한 단계 밝게(다크는 진하게) 떠 보이도록.
    static let buttonFill = NSColor(name: NSColor.Name("settings.buttonFill")) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.10) : NSColor.white
    }
}

/// 입력 칸 — 테두리 대신 카드 위에 떠 있는 둥근 바탕(사이드바 pill 비율) + 얇은 선.
final class SettingsFieldContainer: NSView {
    let field: NSTextField

    init(_ field: NSTextField, width: CGFloat? = nil) {
        self.field = field
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = field.font ?? .systemFont(ofSize: 13)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        var constraints = [
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: SettingsStyle.controlHeight)
        ]
        if let width { constraints.append(widthAnchor.constraint(equalToConstant: width)) }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = HeaderStyle.pill(box)
        SettingsStyle.buttonFill.setFill()
        path.fill()
        SidebarStyle.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Navigation

/// 설정 창 왼쪽 목록의 한 줄 — 메인 사이드바와 같은 검은 pill 선택, hover 옅은 배경.
final class SettingsNavItem: NSButton {
    let pageID: String
    var isSelectedPage = false { didSet { needsDisplay = true } }
    private var isHovering = false { didSet { needsDisplay = true } }
    private let symbol: String

    init(pageID: String, symbol: String, target: AnyObject?, action: Selector) {
        self.pageID = pageID
        self.symbol = symbol
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: SidebarStyle.rowHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var title: String { didSet { setAccessibilityLabel(title); needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["navHover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["navHover": true]))
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: 0, y: 1.5, width: bounds.width, height: bounds.height - 3)
        if isSelectedPage {
            SidebarStyle.selectionFill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: SidebarStyle.pillRadius, yRadius: SidebarStyle.pillRadius).fill()
        } else if isHovering {
            SidebarStyle.hoverFill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: SidebarStyle.pillRadius, yRadius: SidebarStyle.pillRadius).fill()
        }
        let color: NSColor = isSelectedPage ? SidebarStyle.selectionText : SidebarStyle.text
        if let image = SidebarStyle.symbol(symbol, size: 13) {
            HeaderStyle.drawTinted(image, in: NSRect(x: 10, y: 0, width: 18, height: bounds.height),
                                   color: isSelectedPage ? SidebarStyle.selectionText : SidebarStyle.icon, view: self)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isSelectedPage ? .semibold : .regular), .foregroundColor: color
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: 36, y: bounds.midY - size.height / 2))
    }
}

// MARK: - Window surfaces (백업·사전·작업 문맥 같은 도구 창 공용)

/// 도구 창 바탕 — 설정 페이지와 같은 문서 바탕색. 자기 영역만 칠한다.
final class SettingsSurfaceView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// 미리보기·목록을 담는 둥근 카드 — 설정 카드와 같은 색·반지름, 안쪽은 잘라낸다.
final class SettingsPanelView: NSView {
    init(content: NSView, inset: CGFloat = 0) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = SettingsStyle.cardRadius
        layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        SidebarStyle.trackFill.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

enum SettingsText {
    static func heading(_ text: String) -> NSTextField {
        // 메뉴 이름("…" 로 끝나는)을 그대로 받아도 제목에는 말줄임을 붙이지 않는다.
        var title = text.trimmingCharacters(in: .whitespaces)
        for suffix in ["…", "..."] where title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    static func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }
    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// 도구 창 공통 틀 — 타이틀바를 투명하게, 제목은 창 메뉴용으로만 남기고 본문에 큰 제목을 둔다.
    static func applyToolWindowChrome(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = SettingsSurfaceView()
    }
}
