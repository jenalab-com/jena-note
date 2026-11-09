import AppKit
import XCTest
@testable import JenaNoteKit

final class PunctuationTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private var keys: [String] {
        var all = ["jn_punctuationTriggersEnabled", "jn_punctuationClosesOnReturn", "jn_punctuationShiftTarget",
                   "jn_readingPageMode"]
        for kind in PunctuationKind.allCases {
            for field in ["opening", "closing", "leadingSpaces", "trigger"] {
                all.append("jn_punctuation_\(kind.rawValue)_\(field)")
            }
        }
        return all
    }
    private let controller = PunctuationController()
    private var view: EditorTextView!
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.configure()
        view.punctuation = controller
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
    }

    override func tearDown() {
        window.close()
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func type(_ text: String) {
        for character in text {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func setStyle(_ kind: PunctuationKind = .dialogue, _ change: (inout PunctuationStyle) -> Void) {
        var style = SettingsManager.shared.punctuationStyle(for: kind)
        change(&style)
        SettingsManager.shared.setPunctuationStyle(style, for: kind)
    }

    // MARK: - Toggle

    func testTurningOnInsertsOnlyTheOpeningMark() {
        controller.toggle(.dialogue, in: view)
        XCTAssertEqual(view.string, "\"")
        XCTAssertEqual(view.selectedRange().location, 1)
        XCTAssertTrue(controller.isActive(.dialogue))
    }

    func testTurningOffClosesAtTheCaret() {
        controller.toggle(.dialogue, in: view)
        type("안녕")
        controller.toggle(.dialogue, in: view)
        XCTAssertEqual(view.string, "\"안녕\"")
        XCTAssertEqual(view.selectedRange().location, 4)
        XCTAssertFalse(controller.isActive(.dialogue))
    }

    func testLeadingSpacesComeBeforeTheOpeningMarkOnly() {
        setStyle { $0.leadingSpaces = 2 }
        controller.toggle(.dialogue, in: view)
        type("네")
        controller.toggle(.dialogue, in: view)
        XCTAssertEqual(view.string, "  \"네\"")
    }

    func testEmptyClosingMarkJustTurnsOff() {
        setStyle { $0.opening = "— "; $0.closing = "" }
        controller.toggle(.dialogue, in: view)
        type("네")
        controller.toggle(.dialogue, in: view)
        XCTAssertEqual(view.string, "— 네")
        XCTAssertFalse(controller.isActive(.dialogue))
    }

    func testMarksNestIndependently() {
        controller.toggle(.dialogue, in: view)
        type("그가 ")
        controller.toggle(.quotation, in: view)
        type("가라")
        controller.toggle(.quotation, in: view)
        type("고 했어.")
        controller.toggle(.dialogue, in: view)
        XCTAssertEqual(view.string, "\"그가 '가라'고 했어.\"")
    }

    func testSelectionIsWrappedWithoutTurningOn() {
        view.string = "가나다"
        view.setSelectedRange(NSRange(location: 1, length: 1))
        controller.toggle(.dialogue, in: view)
        XCTAssertEqual(view.string, "가\"나\"다")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(controller.active.isEmpty)
    }

    func testCompositionIsCommittedBeforeTheMark() {
        view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.toggle(.dialogue, in: view)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string, "하\"")
    }

    func testResetTurnsOffWithoutClosing() {
        controller.toggle(.dialogue, in: view)
        controller.reset()
        XCTAssertEqual(view.string, "\"")
        XCTAssertTrue(controller.active.isEmpty)
    }

    func testChangeIsReported() {
        var reported: [[PunctuationKind]] = []
        controller.onChange = { reported.append($0) }
        controller.toggle(.dialogue, in: view)
        controller.toggle(.dialogue, in: view)
        XCTAssertEqual(reported, [[.dialogue], []])
    }

    func testUndoRemovesTheMarkSeparatelyFromTyping() throws {
        let undo = try XCTUnwrap(view.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        type("가")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        controller.toggle(.dialogue, in: view)
        undo.endUndoGrouping()
        undo.undo()
        XCTAssertEqual(view.string, "가")
    }

    // MARK: - Typed Sequences

    func testSequenceIsOffByDefault() {
        type(";;;")
        XCTAssertEqual(view.string, ";;;")
    }

    func testSequenceReplacesItselfAndToggles() {
        SettingsManager.shared.punctuationTriggersEnabled = true
        type("앞 ;;;")
        XCTAssertEqual(view.string, "앞 \"")
        type("네;;;뒤")
        XCTAssertEqual(view.string, "앞 \"네\"뒤")
        XCTAssertTrue(controller.active.isEmpty)
    }

    func testCustomSequence() {
        SettingsManager.shared.punctuationTriggersEnabled = true
        setStyle(.thought) { $0.trigger = "//"; $0.opening = "「"; $0.closing = "」" }
        type("//생각//")
        XCTAssertEqual(view.string, "「생각」")
    }

    func testOneCharacterSequenceIsIgnored() {
        SettingsManager.shared.punctuationTriggersEnabled = true
        setStyle { $0.trigger = ";" }
        type(";")
        XCTAssertEqual(view.string, ";")
    }

    func testPastedTextDoesNotTrigger() {
        SettingsManager.shared.punctuationTriggersEnabled = true
        view.insertText(";;;", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, ";;;")
    }

    func testSequenceDoesNotFireInsideCode() {
        SettingsManager.shared.punctuationTriggersEnabled = true
        view.textStorage?.setAttributedString(NSAttributedString(string: ";;", attributes: [.mdBlockType: "codeblock"]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        type(";")
        XCTAssertEqual(view.string, ";;;")
    }

    // MARK: - Return

    func testReturnKeepsMarkOpenByDefault() {
        controller.toggle(.dialogue, in: view)
        type("네")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "\"네\n")
        XCTAssertTrue(controller.isActive(.dialogue))
    }

    func testReturnClosesInnerMarkFirstWhenEnabled() {
        SettingsManager.shared.punctuationClosesOnReturn = true
        setStyle(.quotation) { $0.opening = "「"; $0.closing = "」" }
        controller.toggle(.dialogue, in: view)
        controller.toggle(.quotation, in: view)
        type("네")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "\"「네」\"\n")
        XCTAssertTrue(controller.active.isEmpty)
    }

    // MARK: - Double Shift

    func testDoubleShiftFiresOnSecondPress() {
        var detector = DoubleShiftDetector()
        XCTAssertFalse(detector.shiftChanged(isDown: true, at: 0))
        XCTAssertFalse(detector.shiftChanged(isDown: false, at: 0.1))
        XCTAssertTrue(detector.shiftChanged(isDown: true, at: 0.3))
    }

    func testSlowOrHeldShiftDoesNotFire() {
        var slow = DoubleShiftDetector()
        _ = slow.shiftChanged(isDown: true, at: 0)
        _ = slow.shiftChanged(isDown: false, at: 0.1)
        XCTAssertFalse(slow.shiftChanged(isDown: true, at: 1))

        var held = DoubleShiftDetector()
        _ = held.shiftChanged(isDown: true, at: 0)
        _ = held.shiftChanged(isDown: false, at: 0.8)
        XCTAssertFalse(held.shiftChanged(isDown: true, at: 0.9))
    }

    func testKeyBetweenShiftsCancels() {
        var detector = DoubleShiftDetector()
        _ = detector.shiftChanged(isDown: true, at: 0)
        _ = detector.shiftChanged(isDown: false, at: 0.1)
        detector.interrupt()
        XCTAssertFalse(detector.shiftChanged(isDown: true, at: 0.2))
    }

    func testDoubleShiftEventsToggleTheChosenMark() throws {
        SettingsManager.shared.punctuationShiftTarget = .thought
        func shift(_ down: Bool, _ time: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? .shift : [],
                                           timestamp: time, windowNumber: 0, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        }
        view.flagsChanged(with: try shift(true, 0))
        view.flagsChanged(with: try shift(false, 0.1))
        view.flagsChanged(with: try shift(true, 0.2))
        XCTAssertEqual(view.string, "'")
        XCTAssertTrue(controller.isActive(.thought))
    }

    // MARK: - Settings And Round Trip

    func testDefaultsAndPersistence() {
        XCTAssertEqual(SettingsManager.shared.punctuationStyle(for: .dialogue).opening, "\"")
        XCTAssertFalse(SettingsManager.shared.punctuationTriggersEnabled)
        XCTAssertFalse(SettingsManager.shared.punctuationClosesOnReturn)
        XCTAssertNil(SettingsManager.shared.punctuationShiftTarget)
        let style = PunctuationStyle(opening: "— ", closing: "", leadingSpaces: 2, trigger: "::")
        SettingsManager.shared.setPunctuationStyle(style, for: .quotation)
        XCTAssertEqual(SettingsManager.shared.punctuationStyle(for: .quotation), style)
    }

    func testIndentedDialogueSurvivesSavingAndOpening() {
        for line in ["  \"네\"", " '네'", "  - 네", "— 네"] {
            let parsed = MarkdownSerializer.parse(line + "\n\n다음\n")
            XCTAssertTrue(parsed.string.hasPrefix(line), line)
            XCTAssertEqual(MarkdownSerializer.serialize(parsed), line + "\n\n다음\n", line)
        }
    }

    func testAllTranslationsExist() {
        let original = SettingsManager.shared.language
        defer { SettingsManager.shared.language = original }
        let keys = PunctuationKind.allCases.flatMap { ["menu.format.punctuation.\($0.rawValue)", "punctuation.short.\($0.rawValue)"] }
            + ["settings.tab.punctuation", "punctuation.opening", "punctuation.closing", "punctuation.leadingSpaces",
               "punctuation.trigger", "punctuation.triggersEnabled", "punctuation.triggerHint", "punctuation.doubleShift",
               "punctuation.off", "punctuation.closesOnReturn", "punctuation.closingHint"]
        for language in SettingsManager.Language.allCases {
            SettingsManager.shared.language = language
            for key in keys { XCTAssertNotEqual(L10n.tr(key), key, "\(language) \(key)") }
        }
    }
}
