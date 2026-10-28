import AppKit

/// Shared canvas, with a softly filled composer and no separate transcript panel.
final class AIChatSurface: NSView {
    let isComposer: Bool
    init(isComposer: Bool = false) {
        self.isComposer = isComposer
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        (isComposer ? NSColor.labelColor.withAlphaComponent(0.06) : NSColor.windowBackgroundColor).setFill()
        if isComposer { NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill() }
        else { dirtyRect.fill() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Let the input method consume composition-confirming Return before treating Return as submit.
final class AIChatInputView: NSTextView {
    var onSubmit: (() -> Void)?
    var canSubmit: () -> Bool = { true }
    var placeholder = L10n.tr("ai.composer.placeholder")

    static func shouldSubmit(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Bool {
        (keyCode == 36 || keyCode == 76) && !hasMarkedText
            && modifiers.intersection([.shift, .control, .option, .command]).isEmpty
    }

    override func keyDown(with event: NSEvent) {
        let returnKey = event.keyCode == 36 || event.keyCode == 76
        if returnKey, !hasMarkedText(), event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            insertNewline(nil)
            return
        }
        if Self.shouldSubmit(keyCode: event.keyCode, modifiers: event.modifierFlags, hasMarkedText: hasMarkedText()) {
            if canSubmit() { onSubmit?() }
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() { super.didChangeText(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor
        ]
        (placeholder as NSString).draw(in: NSRect(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                                                 y: textContainerInset.height, width: max(0, bounds.width - 24), height: 36),
                                       withAttributes: attributes)
    }
}
