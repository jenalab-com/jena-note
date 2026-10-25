import AppKit

/// Reuse the document parser, with typography sized for the chat sidebar.
enum AIChatMarkdown {
    static func render(_ markdown: String) -> NSAttributedString {
        // No document base URL: generated image references must not load note files.
        let parsed = MarkdownSerializer.parse(markdown)
        let result = NSMutableAttributedString(attributedString: parsed)
        let fullRange = NSRange(location: 0, length: parsed.length)
        parsed.enumerateAttributes(in: fullRange) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont {
                let size = font.pointSize * 13 / MemoFont.body.pointSize
                result.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: size) ?? font, range: range)
            }
            if let address = attributes[.link] as? String,
               !["https", "http", "mailto"].contains(URL(string: address)?.scheme?.lowercased() ?? "") {
                result.removeAttribute(.link, range: range)
            }
        }
        // The editor uses empty attachments for unresolved images. In chat, keep their
        // description visible instead of showing a blank attachment.
        parsed.enumerateAttribute(.attachment, in: fullRange, options: .reverse) { value, range, _ in
            guard value != nil else { return }
            let alt = parsed.attribute(.mdImageAlt, at: range.location, effectiveRange: nil) as? String ?? ""
            let path = parsed.attribute(.mdImageRelPath, at: range.location, effectiveRange: nil) as? String ?? ""
            result.replaceCharacters(in: range, with: NSAttributedString(string: alt.isEmpty ? path : alt, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        return result
    }
}
