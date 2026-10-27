import AppKit

/// Three-segment budget bar for the sources tab (spec §7.2 ①): settings (orange), episode
/// summaries (blue), previous episode (gray), each proportional to `limit`. Over the limit the
/// segments are scaled to fill 100% and the track's right edge is tinted red.
final class AIWorkContextBudgetBar: NSView {
    static let colors: [NSColor] = [.systemOrange, .systemBlue, .systemGray]

    /// Width fractions (0...1) of the three segments, in order; they never add up to more than 1.
    private(set) var fractions: [CGFloat] = [0, 0, 0]
    private(set) var isOverflowing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 8).isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityRole(.levelIndicator)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(settings: Int, summaries: Int, previous: Int, limit: Int) {
        let values = [settings, summaries, previous].map { max($0, 0) }
        let total = values.reduce(0, +)
        let limit = max(limit, 1)
        isOverflowing = total > limit
        let scale = CGFloat(max(total, limit))
        fractions = values.map { CGFloat($0) / scale }
        setAccessibilityValue("\(total * 100 / limit)%")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        var x: CGFloat = 0
        for (fraction, color) in zip(fractions, Self.colors) {
            let width = bounds.width * fraction
            color.setFill()
            NSRect(x: x, y: 0, width: width, height: bounds.height).fill()
            x += width
        }
        if isOverflowing {
            NSColor.systemRed.setFill()
            NSRect(x: bounds.width - 4, y: 0, width: 4, height: bounds.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Row/cell builders for `AIWorkContextSourcesView`.
enum AIWorkContextSourceRowViews {
    static func small(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = color
        return label
    }

    static func symbol(_ name: String, tooltip: String? = nil, color: NSColor? = nil) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: tooltip) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = color
        view.toolTip = tooltip
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    /// 📁/📄 icon · relative path · "폴더 · N개 파일" / "파일 · 54KB" · × button.
    static func sourceRow(_ source: AIWorkContextModel.SourceRow, index: Int,
                          target: AnyObject, removeAction: Selector) -> NSStackView {
        let icon = symbol(source.isDirectory ? "folder" : "doc.text")
        let path = NSTextField(labelWithString: source.relativePath)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detailText: String
        if source.isDirectory {
            detailText = String(format: L10n.tr("ai.work.sources.folderCount"), source.fileCount ?? 0)
        } else {
            detailText = String(format: L10n.tr("ai.work.sources.fileSize"),
                                source.byteCount.map(AIWorkContextBar.formatBytes) ?? "—")
        }
        let detail = small(detailText)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.tr("ai.work.remove"))
                                  ?? NSImage(), target: target, action: removeAction)
        remove.isBordered = false
        remove.tag = index
        remove.toolTip = L10n.tr("ai.work.remove")
        remove.setAccessibilityLabel(L10n.tr("ai.work.remove") + " " + source.relativePath)
        let row = NSStackView(views: [icon, path, detail, spacer, remove])
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    /// The four cells of one settings-file row: include checkbox, path (+ ⚠), size, 원문/요약.
    static func fileCells(_ row: AIWorkContextModel.SettingRow, index: Int, target: AnyObject,
                          includeAction: Selector, modeAction: Selector) -> [NSView] {
        let checkbox = NSButton(checkboxWithTitle: "", target: target, action: includeAction)
        checkbox.state = row.included ? .on : .off
        checkbox.tag = index
        checkbox.setAccessibilityLabel(row.file.relativePath)

        let path = NSTextField(labelWithString: row.file.relativePath)
        path.lineBreakMode = .byTruncatingMiddle
        path.textColor = row.unreadable ? .disabledControlTextColor : .labelColor
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var pathViews: [NSView] = [path]
        if row.unreadable {
            pathViews.insert(symbol("exclamationmark.triangle", tooltip: L10n.tr("ai.work.unreadable"),
                                    color: .secondaryLabelColor), at: 0)
        } else if AIWorkContextModel.isLarge(row.file) {
            pathViews.insert(symbol("exclamationmark.triangle", tooltip: L10n.tr("ai.work.largeFile"),
                                    color: .systemOrange), at: 0)
        }
        let pathCell = NSStackView(views: pathViews)
        pathCell.spacing = 4
        pathCell.alignment = .centerY
        pathCell.toolTip = row.file.relativePath

        let size = small(AIWorkContextBar.formatBytes(row.file.byteCount),
                         color: row.unreadable ? .disabledControlTextColor : .secondaryLabelColor)
        size.alignment = .right

        let mode = NSSegmentedControl(labels: [L10n.tr("ai.work.sources.full"), L10n.tr("ai.work.sources.summary")],
                                      trackingMode: .selectOne, target: target, action: modeAction)
        mode.controlSize = .small
        mode.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        mode.selectedSegment = row.summarized ? 1 : 0
        mode.tag = index
        mode.isEnabled = row.included && !row.unreadable
        return [checkbox, pathCell, size, mode]
    }
}
