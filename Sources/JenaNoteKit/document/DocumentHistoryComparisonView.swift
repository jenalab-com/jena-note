import AppKit

/// Two aligned, non-wrapping columns with synchronized vertical scrolling.
final class DocumentHistoryComparisonView: NSStackView {
    private let summary = NSTextField(labelWithString: "")
    private let leftTitle = NSTextField(labelWithString: "")
    private let rightTitle = NSTextField(labelWithString: "")
    private let left = NSTextView(), right = NSTextView()
    private let leftScroll = NSScrollView(), rightScroll = NSScrollView()
    private let changeMap = DocumentHistoryChangeMap()
    private var syncing = false
    private var changedRanges: [NSRange] = []
    private var changeIndex = 0

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        let previous = NSButton(title: L10n.tr("history.previousChange"), target: self, action: #selector(previousChange))
        let next = NSButton(title: L10n.tr("history.nextChange"), target: self, action: #selector(nextChange))
        addArrangedSubview(NSStackView(views: [summary, previous, next]))
        let columns = NSStackView()
        columns.distribution = .fillEqually; columns.spacing = 32
        for (title, text, scroll) in [(leftTitle, left, leftScroll), (rightTitle, right, rightScroll)] {
            title.lineBreakMode = .byTruncatingMiddle
            text.isEditable = false
            text.isHorizontallyResizable = true; text.isVerticallyResizable = true
            text.minSize = .zero
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = text.maxSize
            text.textContainerInset = NSSize(width: 8, height: 8)
            scroll.documentView = text
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            let column = NSStackView(views: [title, scroll])
            column.orientation = .vertical; column.alignment = .leading
            columns.addArrangedSubview(column)
            title.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        changeMap.translatesAutoresizingMaskIntoConstraints = false
        columns.addSubview(changeMap)
        NSLayoutConstraint.activate([
            changeMap.leadingAnchor.constraint(equalTo: leftScroll.trailingAnchor, constant: 6),
            changeMap.widthAnchor.constraint(equalToConstant: 20),
            changeMap.topAnchor.constraint(equalTo: leftScroll.topAnchor),
            changeMap.bottomAnchor.constraint(equalTo: leftScroll.bottomAnchor)
        ])
        changeMap.onSelect = { [weak self] index in
            guard let self, self.changedRanges.indices.contains(index) else { return }
            self.changeIndex = index
            self.left.scrollRangeToVisible(self.changedRanges[index])
            self.updateVisibleFraction()
        }
        addArrangedSubview(columns)
        columns.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func show(rows: [DocumentHistoryDiff.Row], version: String) {
        leftTitle.stringValue = L10n.tr("history.previousVersion") + " · " + version
        rightTitle.stringValue = L10n.tr("history.currentVersion")
        let added = rows.filter { $0.kind == .added }.count
        let removed = rows.filter { $0.kind == .removed }.count
        let modified = rows.filter { $0.kind == .modified }.count
        summary.stringValue = added + removed + modified == 0 ? L10n.tr("history.identical") :
            String(format: L10n.tr("history.changeCounts"), modified, added, removed)
        changedRanges = []; changeIndex = 0
        changeMap.setRows(rows)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 22; paragraph.maximumLineHeight = 22
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let leftText = NSMutableAttributedString(), rightText = NSMutableAttributedString()
        for row in rows {
            let changed = row.kind != .unchanged
            let start = leftText.length
            for (output, number, body, isLeft) in [(leftText, row.previousLine, row.previous, true), (rightText, row.currentLine, row.current, false)] {
                var attributes = base
                let marker = !changed ? " " : row.kind == .modified ? "~" : isLeft ? "−" : "+"
                let line = body.map { String(format: "%5d %@  ", number ?? 0, marker) + $0 } ?? "      ·"
                if changed {
                    let color: NSColor = row.kind == .modified ? .systemOrange : isLeft ? .systemRed : .systemGreen
                    attributes[.backgroundColor] = color.withAlphaComponent(body == nil ? 0.06 : 0.18)
                }
                output.append(NSAttributedString(string: line + "\n", attributes: attributes))
            }
            if changed { changedRanges.append(NSRange(location: start, length: leftText.length - start)) }
        }
        left.textStorage?.setAttributedString(leftText)
        right.textStorage?.setAttributedString(rightText)
        left.sizeToFit(); right.sizeToFit()
        if let first = changedRanges.first { left.scrollRangeToVisible(first) }
        else { left.scrollToBeginningOfDocument(nil); right.scrollToBeginningOfDocument(nil) }
    }
    override func layout() {
        super.layout()
        updateVisibleFraction()
    }
    private func updateVisibleFraction() {
        let height = max(1, left.bounds.height)
        let visible = leftScroll.contentView.bounds
        let start = min(1, max(0, visible.minY / height))
        let end = min(1, max(start, visible.maxY / height))
        changeMap.visibleFraction = start...end
    }
    @objc private func previousChange() { jump(-1) }
    @objc private func nextChange() { jump(1) }
    private func jump(_ offset: Int) {
        guard !changedRanges.isEmpty else { return }
        changeIndex = (changeIndex + offset + changedRanges.count) % changedRanges.count
        left.scrollRangeToVisible(changedRanges[changeIndex])
    }
    @objc private func scrolled(_ notification: Notification) {
        guard !syncing, let clip = notification.object as? NSClipView else { return }
        syncing = true; defer { syncing = false }
        let target = clip === leftScroll.contentView ? rightScroll : leftScroll
        target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.origin.x, y: clip.bounds.origin.y))
        target.reflectScrolledClipView(target.contentView)
        updateVisibleFraction()
    }
}
