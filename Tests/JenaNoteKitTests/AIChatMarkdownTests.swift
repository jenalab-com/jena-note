import AppKit
import XCTest
@testable import JenaNoteKit

final class AIChatMarkdownTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }

    func testAssistantRendersMarkdownAndPreservesRawConversation() throws {
        let markdown = "# 제목\n\n**강조**와 *기울임*, `코드`\n- 항목\n1. 순서\n> 인용\n[링크](https://example.com)"
        let row = AIChatMessageView(message: .init(role: "assistant", text: markdown))
        let rendered = row.textView.attributedString()
        let text = rendered.string as NSString
        XCTAssertEqual(row.message.text, markdown, "Only presentation changes; history keeps the original model response")
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertFalse(rendered.string.contains("# 제목"))
        XCTAssertTrue(rendered.string.contains("•\t항목"))
        XCTAssertTrue(rendered.string.contains("1.\t순서"))
        let bold = try XCTUnwrap(rendered.attribute(.font, at: text.range(of: "강조").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let italic = try XCTUnwrap(rendered.attribute(.font, at: text.range(of: "기울임").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertEqual(rendered.attribute(.mdInlineCode, at: text.range(of: "코드").location, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(rendered.attribute(.link, at: text.range(of: "링크").location, effectiveRange: nil) as? String, "https://example.com")
        XCTAssertTrue(row.textView.isSelectable)
        XCTAssertFalse(row.textView.isEditable)
        XCTAssertFalse(row.hasBubble)
        for role in ["user", "status"] {
            XCTAssertEqual(AIChatMessageView(message: .init(role: role, text: markdown)).textView.string, markdown)
        }
    }

    func testCodeAndTableLayoutReflowsInsideSidebar() {
        let markdown = """
        ```swift
        let sample = "**그대로**"
        ```

        | 항목 | 설명 |
        | --- | --- |
        | 하나 | 긴 한글 설명과 English 텍스트가 좁은 채팅창에서도 줄바꿈되어야 합니다. |
        """
        let transcript = AIChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        transcript.setMessages([.init(role: "assistant", text: markdown), .init(role: "user", text: "다음")])
        transcript.layout()
        let row = transcript.messageViews[0]
        let rendered = row.textView.attributedString()
        XCTAssertTrue(rendered.string.contains("**그대로**"), "Code content must not be parsed as emphasis")
        XCTAssertFalse(rendered.string.contains("```"))
        XCTAssertFalse(rendered.string.contains("| --- |"))
        let cell = (rendered.string as NSString).range(of: "항목")
        let style = rendered.attribute(.paragraphStyle, at: cell.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(style?.textBlocks.first is NSTextTableBlock)
        let narrowHeight = row.frame.height
        XCTAssertTrue(narrowHeight.isFinite)
        XCTAssertGreaterThan(transcript.messageViews[1].frame.minY, row.frame.maxY)
        transcript.setFrameSize(NSSize(width: 560, height: 120))
        transcript.layout()
        XCTAssertLessThan(row.frame.height, narrowHeight)
        XCTAssertLessThanOrEqual(transcript.documentView!.frame.width, transcript.contentSize.width + 1)
    }

    func testImagesRetainDescriptionWithoutLoadingAndNonWebLinksRemainText() {
        let rendered = AIChatMarkdown.render("![도표](file:///private/example.png) [로컬](file:///tmp/example) [웹](https://example.com)")
        XCTAssertTrue(rendered.string.contains("도표"))
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            XCTAssertNil(value)
        }
        let local = (rendered.string as NSString).range(of: "로컬")
        XCTAssertNil(rendered.attribute(.link, at: local.location, effectiveRange: nil))
    }
}
