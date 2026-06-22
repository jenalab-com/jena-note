import XCTest
import AppKit
@testable import JenaNoteKit

final class ImageAttachmentTests: XCTestCase {

    // MARK: - Parse

    func testParsePreservesImagePathAndAlt() {
        let md = "![고양이](attachments/cat.png)"
        let parsed = MarkdownSerializer.parse(md)

        var found = false
        let full = NSRange(location: 0, length: parsed.length)
        parsed.enumerateAttribute(.mdImageRelPath, in: full) { value, range, _ in
            guard let path = value as? String else { return }
            XCTAssertEqual(path, "attachments/cat.png")
            let alt = parsed.attribute(.mdImageAlt, at: range.location, effectiveRange: nil) as? String
            XCTAssertEqual(alt, "고양이")
            // attachment 문자가 실제로 들어가 있어야 한다
            XCTAssertNotNil(parsed.attribute(.attachment, at: range.location, effectiveRange: nil))
            found = true
        }
        XCTAssertTrue(found, "이미지 첨부가 파싱되지 않았다")
    }

    // MARK: - Round Trip (parse → serialize 동일성)

    func testRoundTripImageOnly() {
        let md = "![고양이](attachments/cat.png)"
        let serialized = MarkdownSerializer.serialize(MarkdownSerializer.parse(md))
        XCTAssertEqual(serialized.trimmingCharacters(in: .newlines), md)
    }

    func testRoundTripImageWithEmptyAlt() {
        let md = "![](attachments/photo.jpg)"
        let serialized = MarkdownSerializer.serialize(MarkdownSerializer.parse(md))
        XCTAssertEqual(serialized.trimmingCharacters(in: .newlines), md)
    }

    func testRoundTripImageMixedWithText() {
        let md = "사진: ![개](attachments/dog.png) 끝"
        let serialized = MarkdownSerializer.serialize(MarkdownSerializer.parse(md))
        XCTAssertEqual(serialized.trimmingCharacters(in: .newlines), md)
    }

    /// 링크 `[text](url)`가 이미지 `![alt](url)`로 오인되지 않아야 한다.
    func testLinkNotConfusedWithImage() {
        let md = "[애플](https://apple.com)"
        let serialized = MarkdownSerializer.serialize(MarkdownSerializer.parse(md))
        XCTAssertEqual(serialized.trimmingCharacters(in: .newlines), md)
    }

    // MARK: - Sized Image (HTML <img width>)

    func testParseImgTagPreservesWidth() {
        let md = "<img src=\"attachments/cat.png\" alt=\"고양이\" width=\"300\">"
        let parsed = MarkdownSerializer.parse(md)
        var found = false
        let full = NSRange(location: 0, length: parsed.length)
        parsed.enumerateAttribute(.mdImageRelPath, in: full) { value, range, _ in
            guard let path = value as? String else { return }
            XCTAssertEqual(path, "attachments/cat.png")
            XCTAssertEqual(parsed.attribute(.mdImageAlt, at: range.location, effectiveRange: nil) as? String, "고양이")
            XCTAssertEqual(parsed.attribute(.mdImageWidth, at: range.location, effectiveRange: nil) as? Int, 300)
            found = true
        }
        XCTAssertTrue(found, "img 태그가 파싱되지 않았다")
    }

    func testRoundTripSizedImage() {
        let md = "<img src=\"attachments/cat.png\" alt=\"고양이\" width=\"300\">"
        let serialized = MarkdownSerializer.serialize(MarkdownSerializer.parse(md))
        XCTAssertEqual(serialized.trimmingCharacters(in: .newlines), md)
    }

    func testRoundTripSizedImageNoAlt() {
        let md = "<img src=\"attachments/photo.jpg\" width=\"480\">"
        let serialized = MarkdownSerializer.serialize(MarkdownSerializer.parse(md))
        XCTAssertEqual(serialized.trimmingCharacters(in: .newlines), md)
    }

    /// 폭이 없으면 표준 마크다운으로 직렬화돼야 한다.
    func testNoWidthFallsBackToMarkdown() {
        let md = "![고양이](attachments/cat.png)"
        let serialized = MarkdownSerializer.serialize(MarkdownSerializer.parse(md))
        XCTAssertEqual(serialized.trimmingCharacters(in: .newlines), md)
    }

    // MARK: - Bounds Scaling (컨테이너 폭 기준)

    func testLargeImageScaledToContainerWidth() {
        let bounds = MarkdownSerializer.imageBounds(for: NSSize(width: 960, height: 480), maxWidth: 600)
        XCTAssertEqual(bounds.width, 600, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 300, accuracy: 0.01) // 비율 유지: 480 * (600/960)
    }

    func testSmallImageKeepsOriginalSize() {
        let bounds = MarkdownSerializer.imageBounds(for: NSSize(width: 100, height: 80), maxWidth: 600)
        XCTAssertEqual(bounds.width, 100, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 80, accuracy: 0.01)
    }
}
