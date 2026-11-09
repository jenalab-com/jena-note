import AppKit

/// 작가가 부호를 정해 두는 글의 종류.
enum PunctuationKind: String, CaseIterable {
    case dialogue
    case quotation
    case thought

    var menuTitle: String { L10n.tr("menu.format.punctuation.\(rawValue)") }
    var shortTitle: String { L10n.tr("punctuation.short.\(rawValue)") }
    var shortcutLabel: String { "⌘\((Self.allCases.firstIndex(of: self) ?? 0) + 1)" }
}

/// 부호 하나의 작가 설정. 닫는 부호가 비어 있으면 대시처럼 여는 부호만 쓰는 방식이다.
struct PunctuationStyle: Equatable {
    static let leadingSpacesRange = 0...2
    /// 한 글자는 평범한 입력과 구별할 수 없다.
    static let minimumTriggerLength = 2

    var opening: String
    var closing: String
    var leadingSpaces: Int
    var trigger: String

    static func defaultStyle(for kind: PunctuationKind) -> PunctuationStyle {
        switch kind {
        case .dialogue:  return PunctuationStyle(opening: "\"", closing: "\"", leadingSpaces: 0, trigger: ";;;")
        case .quotation: return PunctuationStyle(opening: "'", closing: "'", leadingSpaces: 0, trigger: "'''")
        case .thought:   return PunctuationStyle(opening: "'", closing: "'", leadingSpaces: 0, trigger: "///")
        }
    }

    var openingText: String { String(repeating: " ", count: leadingSpaces) + opening }
}

/// Shift를 짧게 두 번 누른 순간을 찾는다. 사이에 다른 키가 끼면 처음부터 다시 센다.
struct DoubleShiftDetector {
    static let maximumHold: TimeInterval = 0.3
    static let maximumGap: TimeInterval = 0.35

    private var pressedAt: TimeInterval?
    private var firstTapEndedAt: TimeInterval?

    /// 두 번째 Shift가 눌린 순간에 true를 돌려준다.
    mutating func shiftChanged(isDown: Bool, at time: TimeInterval) -> Bool {
        if isDown {
            if let ended = firstTapEndedAt, time - ended <= Self.maximumGap {
                interrupt()
                return true
            }
            firstTapEndedAt = nil
            pressedAt = time
        } else {
            if let pressed = pressedAt, time - pressed <= Self.maximumHold {
                firstTapEndedAt = time
            } else {
                firstTapEndedAt = nil
            }
            pressedAt = nil
        }
        return false
    }

    mutating func interrupt() {
        pressedAt = nil
        firstTapEndedAt = nil
    }
}

/// 창 하나의 부호 입력 상태.
///
/// 켜면 여는 부호만, 끄면 닫는 부호만 넣는다 — 닫는 부호를 미리 넣어 두지 않는다.
/// 부호는 일반 타이핑과 같은 경로로 넣어 글자 속성·조판·실행 취소가 입력과 똑같이 동작한다.
final class PunctuationController {
    /// 켠 순서대로. 대사 안의 인용처럼 겹쳐 쓸 수 있고, 한꺼번에 닫을 때는 거꾸로 닫는다.
    private(set) var active: [PunctuationKind] = [] {
        didSet { if active != oldValue { onChange?(active) } }
    }
    var onChange: (([PunctuationKind]) -> Void)?
    /// 페이지 조판은 조합 확정 중 문서 동기화를 막아야 해서 창이 대신 처리한다.
    var finishComposition: (() -> Void)?

    private var isInserting = false
    private var shiftDetector = DoubleShiftDetector()

    func isActive(_ kind: PunctuationKind) -> Bool { active.contains(kind) }

    /// 문서가 바뀌면 이어 쓸 자리가 사라지므로 닫는 부호 없이 끈다.
    func reset() { active = [] }

    func toggle(_ kind: PunctuationKind, in textView: NSTextView) {
        commitComposition(in: textView)
        let selection = textView.selectedRange()
        if selection.length > 0 {
            wrap(selection, with: SettingsManager.shared.punctuationStyle(for: kind), in: textView)
        } else {
            flip(kind, replacing: selection, in: textView)
        }
    }

    // MARK: - Text View Hooks

    /// 연속 입력의 마지막 글자를 만나면 친 글자를 지우고 토글한다. 처리했으면 true.
    func handleTyped(_ string: Any, replacementRange: NSRange, in textView: NSTextView) -> Bool {
        let settings = SettingsManager.shared
        guard !isInserting, settings.punctuationTriggersEnabled, !textView.hasMarkedText() else { return false }
        shiftDetector.interrupt()
        // 키보드는 한 글자씩 들어온다. 그보다 긴 입력은 붙여넣기다.
        guard let typed = (string as? String) ?? (string as? NSAttributedString)?.string, typed.count == 1 else { return false }
        let caret = textView.selectedRange()
        guard caret.length == 0,
              replacementRange.location == NSNotFound || replacementRange == caret else { return false }
        let text = textView.string as NSString
        for kind in PunctuationKind.allCases {
            let trigger = settings.punctuationStyle(for: kind).trigger
            guard trigger.count >= PunctuationStyle.minimumTriggerLength, trigger.hasSuffix(typed) else { continue }
            let typedBefore = (trigger as NSString).length - (typed as NSString).length
            guard caret.location >= typedBefore else { continue }
            let range = NSRange(location: caret.location - typedBefore, length: typedBefore)
            guard text.substring(with: range) == (trigger as NSString).substring(to: typedBefore),
                  !isCode(at: caret.location - 1, in: textView) else { continue }
            flip(kind, replacing: range, in: textView)
            return true
        }
        return false
    }

    /// 설정을 켠 작가에게만 Enter가 켜진 부호를 닫는다.
    func handleNewline(in textView: NSTextView) {
        guard SettingsManager.shared.punctuationClosesOnReturn, !active.isEmpty else { return }
        commitComposition(in: textView)
        for kind in active.reversed() {
            flip(kind, replacing: textView.selectedRange(), in: textView)
        }
    }

    func noteKeyDown() { shiftDetector.interrupt() }

    func handleFlagsChanged(_ event: NSEvent, in textView: NSTextView) {
        guard let kind = SettingsManager.shared.punctuationShiftTarget else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 56 || event.keyCode == 60,
              flags.subtracting([.shift, .capsLock]).isEmpty else {
            shiftDetector.interrupt()
            return
        }
        if shiftDetector.shiftChanged(isDown: flags.contains(.shift), at: event.timestamp) {
            toggle(kind, in: textView)
        }
    }

    // MARK: - Editing

    private func flip(_ kind: PunctuationKind, replacing range: NSRange, in textView: NSTextView) {
        let style = SettingsManager.shared.punctuationStyle(for: kind)
        if let index = active.firstIndex(of: kind) {
            insert(style.closing, replacing: range, in: textView)
            active.remove(at: index)
        } else {
            insert(style.openingText, replacing: range, in: textView)
            active.append(kind)
        }
    }

    private func wrap(_ selection: NSRange, with style: PunctuationStyle, in textView: NSTextView) {
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        insert(style.closing, replacing: NSRange(location: NSMaxRange(selection), length: 0), in: textView)
        insert(style.openingText, replacing: NSRange(location: selection.location, length: 0), in: textView)
        undo?.endUndoGrouping()
        let added = (style.openingText as NSString).length + (style.closing as NSString).length
        textView.setSelectedRange(NSRange(location: NSMaxRange(selection) + added, length: 0))
    }

    private func insert(_ text: String, replacing range: NSRange, in textView: NSTextView) {
        guard !text.isEmpty || range.length > 0 else { return }
        isInserting = true
        defer { isInserting = false }
        textView.breakUndoCoalescing()
        textView.setSelectedRange(range)
        textView.insertText(text, replacementRange: range)
        textView.breakUndoCoalescing()
    }

    private func commitComposition(in textView: NSTextView) {
        finishComposition?()
        guard textView.hasMarkedText() else { return }
        textView.unmarkText()
        textView.inputContext?.discardMarkedText()
    }

    private func isCode(at location: Int, in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage, location >= 0, location < storage.length else { return false }
        let attributes = storage.attributes(at: location, effectiveRange: nil)
        return attributes[.mdBlockType] as? String == "codeblock" || attributes[.mdInlineCode] as? Bool == true
    }
}
