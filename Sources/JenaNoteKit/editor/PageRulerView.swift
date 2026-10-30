import AppKit

/// 워드식 가로 치수자. 페이지 한 장의 폭을 cm 눈금으로 보여주고, 좌·우 여백 핸들을
/// 끌어 여백을 바꾼다. 핸들을 페이지 바깥으로 끌면 그만큼 페이지가 넓어진다
/// (`maxPageWidth` 한도, `canGrowPage` 일 때만). 더블클릭은 `onReset`.
///
/// 값은 갖고만 있을 뿐 저장하지 않는다 — 끄는 동안은 `onMarginsChanging` 으로 이웃
/// 치수자를 따라 움직이게 하고, 손을 놓는 순간 `onCommitted` 로 한 번만 알린다
/// (매 픽셀마다 재조판하지 않기 위해). 눈금 0 은 왼쪽 여백이 끝나는 자리다(워드와 같다).
final class PageRulerView: NSView {

    static let height: CGFloat = 18
    /// 핸들을 잡을 수 있는 좌우 범위. 삼각형보다 넉넉히 둔다 — 눈으로 보는 것보다
    /// 손끝이 닿는 범위가 넓어야 잡힌다.
    static let handleHitSlop: CGFloat = 12
    private static let handleWidth: CGFloat = 12
    private static let handleHeight: CGFloat = 8

    /// 이 치수자가 보여주는 페이지 폭(pt). 뷰 폭과 같다. 끄는 동안 바깥으로 넓히면
    /// 뷰 프레임도 같이 넓어진다.
    var pageWidth: CGFloat { bounds.width }
    private(set) var leftMargin: CGFloat = 0
    private(set) var rightMargin: CGFloat = 0

    /// 페이지를 넓힐 수 있는 상한(pt). 호출자가 창 폭에서 정한다.
    var maxPageWidth: CGFloat = .greatestFiniteMagnitude
    /// 바깥으로 끌어 페이지를 넓힐 수 있는지. 모바일 폭처럼 고정 프리셋이면 false.
    var canGrowPage = true
    var usesPaperOrigin = false { didSet { needsDisplay = true } }

    var onMarginsChanging: ((CGFloat, CGFloat) -> Void)?
    /// (페이지 폭, 왼쪽 여백, 오른쪽 여백). 손을 놓을 때 값이 바뀌었으면 한 번.
    var onCommitted: ((CGFloat, CGFloat, CGFloat) -> Void)?
    var onReset: (() -> Void)?

    private enum Handle { case left, right }
    private var dragging: Handle?
    private var dragStartMargins: (CGFloat, CGFloat) = (0, 0)
    private var dragStartFrame: NSRect = .zero
    private var dragStartX: CGFloat = 0

    override var isFlipped: Bool { true }
    /// 비활성 창에서도 첫 클릭에 핸들이 잡히게 — 활성화 클릭을 따로 요구하면 "안 잡힌다"고 느낀다.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    /// 표시 여백을 바꾼다. 페이지 폭 안에 들어오도록 잘라 담으며 콜백은 부르지 않는다.
    func setMargins(left: CGFloat, right: CGFloat) {
        let m = ReaderMetrics.clampedMargins(left: left, right: right, pageWidth: pageWidth)
        guard Self.differs(m.left, leftMargin) || Self.differs(m.right, rightMargin) else { return }
        leftMargin = m.left
        rightMargin = m.right
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 폭이 줄면 저장된 여백이 더는 들어가지 않을 수 있다.
        setMargins(left: leftMargin, right: rightMargin)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let textX0 = leftMargin
        let textX1 = b.width - rightMargin

        // 바탕: 여백은 살짝 가라앉히고 글 영역은 종이색으로 띄운다.
        NSColor.quaternaryLabelColor.withAlphaComponent(0.18).setFill()
        b.fill()
        NSColor.textBackgroundColor.setFill()
        NSRect(x: textX0, y: 0, width: max(0, textX1 - textX0), height: b.height).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: b.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        drawTicks(in: b, origin: usesPaperOrigin ? 0 : textX0)
        drawHandle(at: textX0, side: .left)
        drawHandle(at: textX1, side: .right)
    }

    /// 0 을 글 시작점에 두고 양쪽으로 1cm 마다 숫자, 0.5cm 중간 눈금, 0.25cm 잔눈금.
    private func drawTicks(in b: NSRect, origin: CGFloat) {
        let cm = ReaderMetrics.pointsPerCentimeter
        let quarter = cm / 4
        let tickColor = NSColor.secondaryLabelColor
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let midY = b.midY
        var i = Int(floor(-origin / quarter))
        let last = Int(ceil((b.width - origin) / quarter))
        tickColor.setFill()
        while i <= last {
            let x = origin + CGFloat(i) * quarter
            if x < 0 || x > b.width { i += 1; continue }
            if i % 4 == 0 {
                let n = abs(i / 4)
                if n == 0 {
                    NSRect(x: x - 0.5, y: midY - 4, width: 1, height: 8).fill()
                } else {
                    let label = "\(n)" as NSString
                    let size = label.size(withAttributes: labelAttrs)
                    label.draw(at: NSPoint(x: x - size.width / 2, y: midY - size.height / 2),
                               withAttributes: labelAttrs)
                }
            } else if i % 2 == 0 {
                NSRect(x: x - 0.5, y: midY - 3, width: 1, height: 6).fill()
            } else {
                NSRect(x: x - 0.5, y: midY - 1.5, width: 1, height: 3).fill()
            }
            i += 1
        }
    }

    /// 여백 경계 핸들 — 아래를 향한 삼각형. 끄는 중이면 강조색에 cm 값을 곁들인다.
    private func drawHandle(at x: CGFloat, side: Handle) {
        let path = NSBezierPath()
        let w = Self.handleWidth, h = Self.handleHeight
        path.move(to: NSPoint(x: x - w / 2, y: 0))
        path.line(to: NSPoint(x: x + w / 2, y: 0))
        path.line(to: NSPoint(x: x, y: h))
        path.close()
        (dragging == side ? NSColor.controlAccentColor : NSColor.labelColor).setFill()
        path.fill()

        guard dragging == side else { return }
        let value = side == .left ? leftMargin : rightMargin
        let text = String(format: "%.2f cm · %.1f cm", value / ReaderMetrics.pointsPerCentimeter,
                          pageWidth / ReaderMetrics.pointsPerCentimeter) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor
        ]
        let size = text.size(withAttributes: attrs)
        var lx = side == .left ? x + 8 : x - 8 - size.width
        lx = min(max(0, lx), bounds.width - size.width)
        text.draw(at: NSPoint(x: lx, y: bounds.height - size.height - 1), withAttributes: attrs)
    }

    // MARK: - Hit testing & cursor

    private func handle(at point: NSPoint) -> Handle? {
        let slop = Self.handleHitSlop
        let lx = leftMargin, rx = bounds.width - rightMargin
        let dl = abs(point.x - lx), dr = abs(point.x - rx)
        guard min(dl, dr) <= slop else { return nil }
        return dl <= dr ? .left : .right
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let slop = Self.handleHitSlop
        for x in [leftMargin, bounds.width - rightMargin] {
            addCursorRect(NSRect(x: x - slop, y: 0, width: slop * 2, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        let p = convert(event.locationInWindow, from: nil)
        guard let h = handle(at: p) else { super.mouseDown(with: event); return }
        beginDrag(h, atX: p.x)
    }

    private func beginDrag(_ h: Handle, atX x: CGFloat) {
        dragging = h
        dragStartMargins = (leftMargin, rightMargin)
        dragStartFrame = frame
        dragStartX = x
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let h = dragging else { return }
        // 프레임이 끄는 중에 움직이므로 창 좌표로 이동량을 잰다.
        let startInWindow = dragStartFrame.minX + dragStartX
        let nowInWindow = superview?.convert(event.locationInWindow, from: nil).x ?? startInWindow
        applyDrag(handle: h, dx: nowInWindow - startInWindow)
    }

    /// 끌기 시작점 기준 이동량으로 여백을 다시 잡는다. 격자에 붙이고, 반대쪽 여백과
    /// 글 최소 폭이 남는 한계까지만 간다 — 한 번에 한 여백만 바꾸고 반대쪽은 밀지 않는다.
    /// 여백이 0 인데 더 바깥으로 끌면 그만큼 페이지를 넓힌다(`canGrowPage`·`maxPageWidth`).
    private func applyDrag(handle h: Handle, dx: CGFloat) {
        let (l0, r0) = dragStartMargins
        let baseWidth = dragStartFrame.width
        var l = l0, r = r0
        var growth: CGFloat = 0
        let maxGrowth = canGrowPage ? max(0, maxPageWidth - baseWidth) : 0
        switch h {
        case .left:
            let raw = l0 + dx
            if raw >= 0 {
                let limit = max(0, baseWidth - ReaderMetrics.minimumTextWidth - r0)
                l = min(ReaderMetrics.snappedMargin(raw), limit)
            } else {
                l = 0
                growth = min(ReaderMetrics.snappedMargin(-raw), maxGrowth)
            }
        case .right:
            let raw = r0 - dx
            if raw >= 0 {
                let limit = max(0, baseWidth - ReaderMetrics.minimumTextWidth - l0)
                r = min(ReaderMetrics.snappedMargin(raw), limit)
            } else {
                r = 0
                growth = min(ReaderMetrics.snappedMargin(-raw), maxGrowth)
            }
        }
        var f = dragStartFrame
        f.size.width += growth
        if h == .left { f.origin.x -= growth }
        let frameChanged = Self.differs(f.width, frame.width) || Self.differs(f.minX, frame.minX)
        guard frameChanged || Self.differs(l, leftMargin) || Self.differs(r, rightMargin) else { return }
        if frameChanged { frame = f }
        leftMargin = l
        rightMargin = r
        needsDisplay = true
        onMarginsChanging?(leftMargin, rightMargin)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { super.mouseUp(with: event); return }
        endDrag()
    }

    private func endDrag() {
        dragging = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if Self.differs(leftMargin, dragStartMargins.0) || Self.differs(rightMargin, dragStartMargins.1)
            || Self.differs(frame.width, dragStartFrame.width) {
            onCommitted?(pageWidth, leftMargin, rightMargin)
        }
    }

    /// 한계 계산(`pageWidth - 최소폭 - 반대쪽`)이 부동소수 오차로 같은 값을 다르게 낼 수
    /// 있어, 눈에 띄지 않는 차이는 변화로 치지 않는다.
    private static func differs(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 0.01 }

    // MARK: - Test hooks

    /// 테스트에서 끌기 흐름을 흉내 낸다 — 핸들을 잡고 `dx` 만큼 끈 뒤 손을 뗀다.
    func simulateDrag(handleAtLeft: Bool, dx: CGFloat) {
        let h: Handle = handleAtLeft ? .left : .right
        beginDrag(h, atX: handleAtLeft ? leftMargin : bounds.width - rightMargin)
        applyDrag(handle: h, dx: dx)
        endDrag()
    }
}
