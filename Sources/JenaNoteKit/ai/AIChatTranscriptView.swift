import AppKit

/// Rows own their wrapping width instead of imposing a text intrinsic width on the split pane.
final class AIChatTranscriptView: NSScrollView {
    private let canvas = AIChatCanvas()
    private(set) var messageViews: [AIChatMessageView] = []
    private var loadingView: NSView?
    private var lastLayoutWidth: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        autohidesScrollers = true
        hasHorizontalScroller = false
        borderType = .noBorder
        drawsBackground = false
        documentView = canvas
        setAccessibilityLabel(L10n.tr("ai.history"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLoadingView(_ view: NSView) {
        loadingView = view
        canvas.addSubview(view)
    }

    func setMessages(_ messages: [AIChatMessage]) {
        var retained = 0
        while retained < min(messages.count, messageViews.count),
              messages[retained].role == messageViews[retained].message.role,
              messages[retained].text == messageViews[retained].message.text {
            retained += 1
        }
        for row in messageViews.dropFirst(retained) { row.removeFromSuperview() }
        messageViews.removeSubrange(retained...)
        for message in messages.dropFirst(retained) {
            let row = AIChatMessageView(message: message)
            messageViews.append(row)
            canvas.addSubview(row)
        }
        arrangeMessages()
        scrollToBottom()
    }

    override func layout() {
        super.layout()
        guard abs(lastLayoutWidth - contentSize.width) > 0.5 else { return }
        let wasAtBottom = contentView.bounds.maxY >= canvas.bounds.height - 24
        arrangeMessages()
        if wasAtBottom { scrollToBottom() }
    }

    private func arrangeMessages() {
        let width = max(1, contentSize.width)
        lastLayoutWidth = width
        var y: CGFloat = 12
        for row in messageViews {
            let height = row.arrange(width: max(1, width - 16))
            row.frame = NSRect(x: 8, y: y, width: max(1, width - 16), height: height)
            y += height + 20
        }
        if let loadingView = loadingView, !loadingView.isHidden {
            loadingView.frame = NSRect(x: 8, y: y, width: max(1, width - 16), height: 20)
            y += 32
        }
        canvas.setFrameSize(NSSize(width: width, height: max(contentSize.height, y)))
    }

    private func scrollToBottom() {
        contentView.scroll(to: NSPoint(x: 0, y: max(0, canvas.bounds.height - contentSize.height)))
        reflectScrolledClipView(contentView)
    }
}

private final class AIChatCanvas: NSView {
    override var isFlipped: Bool { true }
}

final class AIChatMessageView: NSView {
    let message: AIChatMessage
    let textView = NSTextView()
    private(set) var bubbleFrame = NSRect.zero
    var hasBubble: Bool { message.role == "user" }
    override var isFlipped: Bool { true }

    init(message: AIChatMessage) {
        self.message = message
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = message.role == "assistant"
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.font = .systemFont(ofSize: message.role == "status" ? 11 : 13)
        textView.textColor = message.role == "status" ? .secondaryLabelColor : .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        if message.role == "assistant" {
            textView.textStorage?.setAttributedString(AIChatMarkdown.render(message.text))
        } else {
            textView.string = message.text
        }
        let speaker = hasBubble ? L10n.tr("ai.you") : message.role == "assistant" ? "AI" : L10n.tr("ai.status")
        textView.setAccessibilityLabel(speaker)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func arrange(width: CGFloat) -> CGFloat {
        let horizontalPadding: CGFloat = hasBubble ? 14 : 0
        let verticalPadding: CGFloat = hasBubble ? 10 : 0
        let naturalWidth = hasBubble ? ceil(textView.attributedString().size().width) + horizontalPadding * 2 : width
        let messageWidth = hasBubble ? min(max(64, naturalWidth), width * 0.86) : width
        let textWidth = max(1, messageWidth - horizontalPadding * 2)
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        let usedHeight = textView.textContainer.flatMap { textView.layoutManager?.usedRect(for: $0).height } ?? 18
        let textHeight = max(18, ceil(usedHeight))
        let height = textHeight + verticalPadding * 2
        let x = hasBubble ? width - messageWidth : 0
        bubbleFrame = NSRect(x: x, y: 0, width: messageWidth, height: height)
        textView.frame = NSRect(x: x + horizontalPadding, y: verticalPadding, width: textWidth, height: textHeight)
        needsDisplay = true
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hasBubble else { return }
        let path = NSBezierPath(roundedRect: bubbleFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor.controlColor.setFill()
        path.fill()
    }
}
