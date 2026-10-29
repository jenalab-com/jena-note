import AppKit

/// Positions every changed row against the whole manuscript, independent of scrolling.
final class DocumentHistoryChangeMap: NSView {
    struct Marker {
        let row: Int
        let kind: DocumentHistoryDiff.Kind
    }
    private(set) var markers: [Marker] = []
    private var rowCount = 1
    var onSelect: ((Int) -> Void)?
    var visibleFraction: ClosedRange<CGFloat> = 0...1 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    func setRows(_ rows: [DocumentHistoryDiff.Row]) {
        rowCount = max(1, rows.count)
        markers = rows.enumerated().compactMap { index, row in
            row.kind == .unchanged ? nil : Marker(row: index, kind: row.kind)
        }
        toolTip = L10n.tr("history.changeMap")
        setAccessibilityLabel(L10n.tr("history.changeMap"))
        needsDisplay = true
    }

    func markerRect(at index: Int) -> NSRect {
        let height = min(bounds.height, max(4, min(8, bounds.height / CGFloat(rowCount))))
        let center = (CGFloat(markers[index].row) + 0.5) / CGFloat(rowCount) * bounds.height
        return NSRect(x: 3, y: min(max(0, center - height / 2), max(0, bounds.height - height)), width: max(0, bounds.width - 6), height: height)
    }

    func selectNearest(to y: CGFloat) {
        guard let index = markers.indices.min(by: { abs(markerRect(at: $0).midY - y) < abs(markerRect(at: $1).midY - y) }) else { return }
        onSelect?(index)
    }

    override func mouseDown(with event: NSEvent) {
        selectNearest(to: convert(event.locationInWindow, from: nil).y)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: visibleFraction.lowerBound * bounds.height, width: bounds.width,
               height: max(2, (visibleFraction.upperBound - visibleFraction.lowerBound) * bounds.height))).fill()
        for index in markers.indices {
            let color: NSColor
            switch markers[index].kind {
            case .added: color = .systemGreen
            case .removed: color = .systemRed
            case .modified: color = .systemOrange
            case .unchanged: continue
            }
            color.setFill()
            NSBezierPath(roundedRect: markerRect(at: index), xRadius: 2, yRadius: 2).fill()
        }
    }
}
