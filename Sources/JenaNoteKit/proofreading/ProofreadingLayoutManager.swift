import AppKit

extension NSAttributedString.Key {
    static let proofreadingUnderline = NSAttributedString.Key("JenaNoteProofreadingUnderline")
}

/// Custom decoration only; glyph positions, line heights and stored formatting stay unchanged.
final class ProofreadingLayoutManager: NSLayoutManager {
    override func drawUnderline(forGlyphRange glyphRange: NSRange, underlineType underlineVal: NSUnderlineStyle,
                                baselineOffset: CGFloat, lineFragmentRect lineRect: NSRect,
                                lineFragmentGlyphRange lineGlyphRange: NSRange, containerOrigin: NSPoint) {
        guard glyphRange.length > 0 else { return }
        let index = characterIndexForGlyph(at: glyphRange.location)
        guard temporaryAttribute(.proofreadingUnderline, atCharacterIndex: index, effectiveRange: nil) as? Bool == true,
              let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else {
            super.drawUnderline(forGlyphRange: glyphRange, underlineType: underlineVal,
                                baselineOffset: baselineOffset, lineFragmentRect: lineRect,
                                lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin)
            return
        }
        let font = textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 13)
        let bounds = boundingRect(forGlyphRange: glyphRange, in: container)
        let baseline = lineRect.minY + location(forGlyphAt: glyphRange.location).y
        // NSTextView uses flipped coordinates. Keep the wave below the font's descent.
        let centerY = containerOrigin.y + baseline + max(2, -font.descender) + 2.5
        let startX = containerOrigin.x + bounds.minX
        let endX = containerOrigin.x + bounds.maxX
        guard endX > startX else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.systemOrange.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.setLineDash([1.4, 2.8], count: 2, phase: 0)
        let amplitude: CGFloat = 1.3
        let wavelength: CGFloat = 6
        path.move(to: NSPoint(x: startX, y: centerY))
        var x = startX + 0.5
        while x < endX {
            let y = centerY + amplitude * sin((x - startX) * 2 * .pi / wavelength)
            path.line(to: NSPoint(x: x, y: y))
            x += 0.5
        }
        path.line(to: NSPoint(x: endX, y: centerY + amplitude * sin((endX - startX) * 2 * .pi / wavelength)))
        path.stroke()
    }
}
