import AppKit
import QuartzCore

/// 문서를 여는 동안 본문 자리에 보이는 스켈레톤.
/// 큰 문서는 메인 스레드에서 그리므로, 빛줄기는 메인이 멈춰도 도는 Core Animation으로 움직인다.
final class DocumentLoadingView: NSView {
    private static let columnWidth: CGFloat = 640
    private static let sideMargin: CGFloat = 48
    private static let topMargin: CGFloat = 56
    private static let lineHeight: CGFloat = 12
    private static let lineGap: CGFloat = 14
    private static let paragraphGap: CGFloat = 30
    /// 문단 안 줄 길이. 마지막 줄을 짧게 해서 글처럼 보이게 한다.
    private static let paragraphs: [[CGFloat]] = [
        [1, 0.96, 0.98, 0.62], [0.97, 1, 0.94, 0.99, 0.41], [1, 0.95, 0.73]
    ]

    private let bars = CAShapeLayer()
    private let shimmer = CAGradientLayer()
    private let shimmerMask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bars)
        layer?.addSublayer(shimmer)
        shimmer.mask = shimmerMask
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(L10n.tr("document.loading"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override var wantsUpdateLayer: Bool { true }

    /// 글자가 없는 동안 뒤의 이전 문서를 누르지 못하게 입력을 막는다.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = PaperBackground.currentColor.cgColor
            bars.fillColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
            let light = NSColor.labelColor.withAlphaComponent(0.1)
            shimmer.colors = [light.withAlphaComponent(0).cgColor, light.cgColor, light.withAlphaComponent(0).cgColor]
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = linesPath()
        bars.frame = bounds
        bars.path = path
        shimmer.frame = bounds
        shimmerMask.frame = bounds
        shimmerMask.path = path
        CATransaction.commit()
        startShimmer()
    }

    private func linesPath() -> CGPath {
        let path = CGMutablePath()
        let width = max(0, min(Self.columnWidth, bounds.width - Self.sideMargin * 2))
        let left = (bounds.width - width) / 2
        var top = bounds.height - Self.topMargin

        func addLine(fraction: CGFloat, height: CGFloat) {
            let rect = CGRect(x: left, y: top - height, width: width * fraction, height: height)
            path.addRoundedRect(in: rect, cornerWidth: height / 2, cornerHeight: height / 2)
            top -= height + Self.lineGap
        }

        addLine(fraction: 0.42, height: Self.lineHeight * 2)
        top -= Self.paragraphGap - Self.lineGap
        var index = 0
        while top > 0 {
            Self.paragraphs[index % Self.paragraphs.count].forEach { addLine(fraction: $0, height: Self.lineHeight) }
            top -= Self.paragraphGap - Self.lineGap
            index += 1
        }
        return path
    }

    private func startShimmer() {
        guard shimmer.animation(forKey: "sweep") == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.4, -0.2, 0]
        sweep.toValue = [1, 1.2, 1.4]
        sweep.duration = 1.4
        sweep.repeatCount = .infinity
        shimmer.add(sweep, forKey: "sweep")
    }
}
