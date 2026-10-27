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

    private func active(ready: Int = 6, total: Int = 6, previous: Bool = true, outside: Bool = false,
                        budget: AIPromptBudget = .ok) -> AIWorkContextStatus {
        .active(settingsCount: 4, contextBytes: 182_345, summariesReady: ready, summariesTotal: total,
                previousEpisode: previous, outsideWriting: outside, budget: budget)
    }

    func testTextForEachStatus() {
        XCTAssertEqual(AIWorkContextBar.text(for: .none), "작품 문맥: 해당 없음 · 설정하기")
        XCTAssertEqual(AIWorkContextBar.text(for: active()), "작품 문맥: 설정 4개 (182KB) · 요약 6화 · 앞 화 전문")
        XCTAssertEqual(AIWorkContextBar.text(for: active(ready: 2)), "작품 문맥: 설정 4개 (182KB) · 요약 2/6화 · 앞 화 전문")
        XCTAssertEqual(AIWorkContextBar.text(for: active(ready: 0, total: 0, previous: false, outside: true)),
                       "작품 문맥: 설정 4개 (182KB) · 집필 폴더 밖")
        XCTAssertEqual(AIWorkContextBar.text(for: .disabled), "작품 문맥: 꺼짐")
        XCTAssertEqual(AIWorkContextBar.text(for: .generating(done: 3, total: 6)), "요약 생성 중 3/6")
        XCTAssertEqual(AIWorkContextBar.text(for: .corrupt), "작품 문맥: 설정 파일 오류 · 다시 설정")
    }

    func testColorByBudget() {
        XCTAssertEqual(AIWorkContextBar.color(for: active(budget: .ok)), .secondaryLabelColor)
        XCTAssertEqual(AIWorkContextBar.color(for: active(budget: .warning)), .systemOrange)
        XCTAssertEqual(AIWorkContextBar.color(for: active(budget: .over)), .systemRed)
        XCTAssertFalse(AIWorkContextBar.text(for: active(budget: .warning)).contains("한도 초과"))
        XCTAssertEqual(AIWorkContextBar.text(for: active(budget: .over)),
                       "작품 문맥: 설정 4개 (182KB) · 요약 6화 · 앞 화 전문 · 한도 초과")
        XCTAssertEqual(AIWorkContextBar.color(for: .none), .secondaryLabelColor)
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
        XCTAssertEqual(bar.displayedText, "작품 문맥: 꺼짐")
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
