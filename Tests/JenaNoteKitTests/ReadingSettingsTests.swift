import XCTest
import AppKit
@testable import JenaNoteKit

final class ReadingSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "jn_readingPageMode")
        UserDefaults.standard.removeObject(forKey: "jn_readingFontScale")
        UserDefaults.standard.removeObject(forKey: "jn_documentFontSize")
        UserDefaults.standard.removeObject(forKey: "jn_readingLineLength")
    }

    func testDefaults() {
        XCTAssertEqual(SettingsManager.shared.readingPageMode, .scroll)
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 1.3, accuracy: 0.001)
        XCTAssertEqual(SettingsManager.shared.readingLineLength, 35)
    }

    func testPageModePersists() {
        SettingsManager.shared.readingPageMode = .paged
        XCTAssertEqual(SettingsManager.shared.readingPageMode, .paged)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "jn_readingPageMode"), "paged")
    }

    func testFontScaleClamps() {
        SettingsManager.shared.readingFontScale = 5.0
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 2.0, accuracy: 0.001)
        SettingsManager.shared.readingFontScale = 0.1
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 0.8, accuracy: 0.001)
    }

    /// 화면 배율은 10% 단위다. 예전 값이 103%로 저장돼 있어도 끝자리가 따라다니면 안 된다.
    func testDisplayZoomSnapsToTenPercentSteps() {
        UserDefaults.standard.set(1.0333333, forKey: "jn_readingFontScale")
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 1.0, accuracy: 0.0001)

        SettingsManager.shared.readingFontScale += 0.1
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 1.1, accuracy: 0.0001)
        SettingsManager.shared.readingFontScale += 0.1
        XCTAssertEqual(Int((SettingsManager.shared.readingFontScale * 100).rounded()), 120)

        UserDefaults.standard.set(0.9333333, forKey: "jn_readingFontScale")
        XCTAssertEqual(SettingsManager.shared.readingFontScale, 0.9, accuracy: 0.0001)
    }

    /// 실제 글자 크기와 화면 배율은 따로 움직이고, 화면에는 둘을 곱한 크기로 그린다.
    func testDocumentFontSizeIsSeparateFromDisplayZoom() {
        defer { UserDefaults.standard.removeObject(forKey: "jn_documentFontSize") }
        XCTAssertEqual(SettingsManager.shared.documentFontSize, MemoFont.body.pointSize, "처음에는 기본 본문 크기다")

        SettingsManager.shared.documentFontSize = 11
        SettingsManager.shared.readingFontScale = 1.5

        XCTAssertEqual(SettingsManager.shared.documentFontSize, 11, accuracy: 0.001, "배율이 실제 크기를 바꾸면 안 된다")
        XCTAssertEqual(SettingsManager.shared.readingDisplayScale * MemoFont.body.pointSize, 16.5, accuracy: 0.001)

        SettingsManager.shared.documentFontSize = 1
        XCTAssertEqual(SettingsManager.shared.documentFontSize, 8, accuracy: 0.001)
        SettingsManager.shared.documentFontSize = 99
        XCTAssertEqual(SettingsManager.shared.documentFontSize, 30, accuracy: 0.001)
    }

    func testFontSizeControlStepsToWholeNumbersAndAcceptsTypedValues() throws {
        _ = NSApplication.shared // sendAction·performClick 은 앱 객체가 있어야 전달된다(단독 실행 대비)
        var sent: [CGFloat] = []
        let control = NumberStepControl(value: 16.5, range: SettingsManager.documentFontSizeRange, unit: "pt")
        control.onChange = { sent.append($0) }
        let field = control.field
        XCTAssertEqual(field.stringValue, "16.5")

        control.increaseButton.performClick(nil)
        XCTAssertEqual(control.value, 17, "16.5에서 올리면 다음 정수다")
        control.decreaseButton.performClick(nil)
        XCTAssertEqual(control.value, 16)

        field.stringValue = "11,5"
        field.sendAction(field.action, to: field.target)
        XCTAssertEqual(control.value, 11.5, accuracy: 0.001)

        field.stringValue = "abc"
        field.sendAction(field.action, to: field.target)
        XCTAssertEqual(field.stringValue, "11.5", "숫자가 아니면 원래 값으로 돌아간다")
        XCTAssertEqual(sent, [17, 16, 11.5], "Each real change is sent once; invalid input sends nothing")
    }

    func testLetterSpacingIsWholePercentWithinRange() {
        defer { UserDefaults.standard.removeObject(forKey: "jn_documentLetterSpacing") }
        XCTAssertEqual(SettingsManager.shared.documentLetterSpacing, 0)
        SettingsManager.shared.documentLetterSpacing = 4.6
        XCTAssertEqual(SettingsManager.shared.documentLetterSpacing, 5)
        SettingsManager.shared.documentLetterSpacing = -50
        XCTAssertEqual(SettingsManager.shared.documentLetterSpacing, -10)
        SettingsManager.shared.documentLetterSpacing = 50
        XCTAssertEqual(SettingsManager.shared.documentLetterSpacing, 20)
    }

    /// 자간은 화면 조판에만 얹힌다. 코드는 건드리지 않고, 벗기면 원고에 남지 않는다.
    func testLetterSpacingStylesTextButNotCodeAndLeavesNoTrace() {
        let source = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("본문 `code`"))
        let styled = ReaderMetrics.styled(source, scale: 1, font: .sans, lineHeightMultiple: 1.2, letterSpacing: 10)
        let size = (styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0

        let kern = styled.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(kern ?? 0, size * 0.1, accuracy: 0.001)
        let code = (styled.string as NSString).range(of: "code")
        XCTAssertNil(styled.attribute(.kern, at: code.location, effectiveRange: nil), "코드에는 자간을 넣지 않는다")

        let back = ReaderMetrics.unstyled(styled)
        XCTAssertNil(back.attribute(.kern, at: 0, effectiveRange: nil))
        XCTAssertEqual(MarkdownSerializer.serialize(back), MarkdownSerializer.serialize(source), "원고는 자간과 무관하다")

        let zero = ReaderMetrics.styled(styled, scale: 1, font: .sans, lineHeightMultiple: 1.2, letterSpacing: 0)
        XCTAssertNil(zero.attribute(.kern, at: 0, effectiveRange: nil), "0%로 돌리면 지워진다")
    }
}
