import AppKit
import XCTest
@testable import JenaNoteKit

final class AIWorkContextBarTests: XCTestCase {
    private var originalLanguage: SettingsManager.Language!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        originalLanguage = SettingsManager.shared.language
        SettingsManager.shared.language = .ko
    }

    override func tearDown() {
        SettingsManager.shared.language = originalLanguage
        super.tearDown()
    }

    private func active(settings: Int = 6, ready: Int = 12, total: Int = 12, outside: Bool = false,
                        bytes: Int = 182_345, budget: AIPromptBudget = .ok) -> AIWorkContextStatus {
        .active(settingsCount: settings, summariesReady: ready, summariesTotal: total,
                outsideWriting: outside, contextBytes: bytes, budget: budget)
    }

    private func check(_ status: AIWorkContextStatus, dot: NSColor, text: String, detail: String?, button: String,
                       enabled: Bool = true, warning: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let a = AIWorkContextBar.appearance(for: status)
        XCTAssertEqual(a.dotColor, dot, file: file, line: line)
        XCTAssertEqual(a.text, text, file: file, line: line)
        XCTAssertEqual(a.detail, detail, file: file, line: line)
        XCTAssertEqual(a.buttonTitle, button, file: file, line: line)
        XCTAssertEqual(a.buttonEnabled, enabled, file: file, line: line)
        XCTAssertEqual(a.background != nil, warning, file: file, line: line)
    }

    func testAppearanceForEachStatusMatchesTable() {
        check(.unavailable(reason: .notInWork), dot: .systemGray, text: "작품 문맥 사용 안 함", detail: nil, button: "설정…")
        check(.unavailable(reason: .unsavedDocument), dot: .systemGray, text: "작품 문맥 사용 안 함", detail: nil,
              button: "설정…", enabled: false)
        check(.disabled, dot: .systemGray, text: "작품 문맥 꺼짐", detail: nil, button: "켜기")
        check(active(), dot: .systemGreen, text: "작품 문맥 사용 중", detail: "설정 6개 · 지난 화 12화", button: "설정…")
        check(active(ready: 2), dot: .systemGreen, text: "작품 문맥 사용 중",
              detail: "설정 6개 · 지난 화 2/12화 준비", button: "설정…")
        check(active(ready: 0, total: 0, outside: true), dot: .systemGreen, text: "작품 문맥 사용 중",
              detail: "설정 6개 · 지난 화 없음", button: "설정…")
        check(active(bytes: 400_000, budget: .warning), dot: .systemOrange, text: "작품 문맥 사용 중",
              detail: "400KB / 500KB에 가까워요", button: "설정…", warning: true)
        check(active(bytes: 640_000, budget: .over), dot: .systemOrange, text: "설정이 한도를 넘었어요",
              detail: "640KB / 500KB", button: "설정…", warning: true)
        check(.corrupt, dot: .systemRed, text: "작품 문맥 설정을 읽을 수 없어요", detail: nil, button: "다시 설정…")
        check(.generating(done: 3, total: 12), dot: .systemBlue, text: "지난 화 요약 만드는 중 3/12", detail: nil, button: "취소")
    }

    func testUnsavedDocumentDisablesSetupButton() {
        let a = AIWorkContextBar.appearance(for: .unavailable(reason: .unsavedDocument))
        XCTAssertFalse(a.buttonEnabled)
        XCTAssertEqual(a.tooltip, "먼저 저장하세요")
        let bar = AIWorkContextBar()
        bar.update(.unavailable(reason: .unsavedDocument))
        XCTAssertFalse(bar.button.isEnabled)
    }

    func testDetailCarriesNumbersNotSentence() {
        let a = AIWorkContextBar.appearance(for: active())
        XCTAssertEqual(a.text, "작품 문맥 사용 중")
        XCTAssertEqual(a.detail, "설정 6개 · 지난 화 12화")
    }

    func testRowClickAndButtonClickFireSameAction() throws {
        let bar = AIWorkContextBar()
        bar.frame = NSRect(x: 0, y: 0, width: 300, height: 32)
        bar.update(.disabled)
        var count = 0
        bar.onPrimaryAction = { count += 1 }
        bar.button.performClick(nil)
        XCTAssertEqual(count, 1)
        let click = try XCTUnwrap(bar.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)
        let action = try XCTUnwrap(click.action)
        _ = (click.target as AnyObject).perform(action, with: click)
        XCTAssertEqual(count, 2)
    }

    func testFormatBytes() {
        XCTAssertEqual(AIWorkContextBar.formatBytes(182_345), "182KB")
        XCTAssertEqual(AIWorkContextBar.formatBytes(1_234_567), "1.2MB")
        XCTAssertEqual(AIWorkContextBar.formatBytes(999), "1KB")
    }

    func testUpdateShowsTextAndKeepsStatus() {
        let bar = AIWorkContextBar()
        bar.update(.disabled)
        XCTAssertEqual(bar.status, .disabled)
        XCTAssertEqual(bar.displayedText, "작품 문맥 꺼짐")
    }

    func testBarSitsDirectlyBelowDocumentLabelInChatPanel() throws {
        let chat = AIChatViewController()
        chat.view.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        let stack = try XCTUnwrap(chat.view.subviews.compactMap { $0 as? NSStackView }.first)
        let views = stack.arrangedSubviews
        let label = try XCTUnwrap(views.firstIndex { $0 === chat.documentLabel })
        let bar = try XCTUnwrap(views.firstIndex { $0 === chat.workBar })
        XCTAssertEqual(bar, label + 1)
        chat.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(chat.workBar.frame.width, stack.frame.width, accuracy: 1)
    }
}
