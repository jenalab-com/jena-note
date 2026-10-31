import AppKit
import XCTest
@testable import JenaNoteKit

final class LiveProofreadingTests: XCTestCase {
    func testOnlyChangedSourceCharactersAreMarked() {
        let source = "회의가 끝낫습니다."
        let ranges = ProofreadingAnnotations.ranges(source: source, corrected: "회의가 끝났습니다.")
        XCTAssertEqual(ranges.map { (source as NSString).substring(with: $0) }, ["낫"])
        XCTAssertTrue(ProofreadingAnnotations.ranges(source: source, corrected: source).isEmpty)
        let emoji = "😀학교에갔다."
        let spacing = ProofreadingAnnotations.ranges(source: emoji, corrected: "😀학교에 갔다.")
        XCTAssertEqual(spacing.map { (emoji as NSString).substring(with: $0) }, ["에갔"])
    }

    func testChunksRespectNativeLimitsAndUnicodeBoundaries() {
        let source = String(repeating: "가😀", count: 800) + "\n이미지\u{fffc}\n끝."
        let chunks = ProofreadingAnnotations.chunks(source, in: NSRange(location: 0, length: source.utf16.count))
        XCTAssertGreaterThan(chunks.count, 1)
        for (range, text) in chunks {
            XCTAssertLessThanOrEqual(text.count, 500)
            XCTAssertLessThanOrEqual(text.utf8.count, 1500)
            XCTAssertEqual((source as NSString).substring(with: range), text)
            XCTAssertFalse(text.contains("\u{fffc}"))
        }
        XCTAssertEqual(chunks.last?.1, "끝.")
    }

    private func view(_ text: String) -> (NSWindow, NSTextView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.textContainer?.replaceLayoutManager(ProofreadingLayoutManager())
        view.string = text
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        addTeardownBlock { window.close() }
        return (window, view)
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) {
        let done = expectation(description: "annotation ready")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if predicate() { timer.invalidate(); done.fulfill() }
        }
        defer { timer.invalidate() }
        wait(for: [done], timeout: 6)
    }

    func testAnnotationsDoNotChangeStorageOrUndoAndClearAfterCorrection() {
        let (_, view) = view("회의가 끝낫습니다.")
        view.textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.double.rawValue, range: NSRange(location: 0, length: 2))
        let original = NSAttributedString(attributedString: view.textStorage!)
        let canUndo = view.undoManager?.canUndo
        let controller = LiveProofreadingController(textView: view, delay: 0.01, check: { $0.replacingOccurrences(of: "낫", with: "났") })
        defer { controller.stop() }
        waitUntil { !controller.markedRanges.isEmpty }
        XCTAssertTrue(view.textStorage!.isEqual(to: original))
        XCTAssertEqual(view.undoManager?.canUndo, canUndo)
        let mark = controller.markedRanges[0]
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.underlineColor, atCharacterIndex: mark.location, effectiveRange: nil))
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/jena-inline-proofreading.png"))
        }
        view.textStorage?.replaceCharacters(in: mark, with: "났")
        waitUntil { controller.markedRanges.isEmpty }
        XCTAssertEqual(view.string, "회의가 끝났습니다.")
        XCTAssertEqual(view.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.double.rawValue)
    }

    func testMarkedTextDefersCheckingUntilCompositionEnds() {
        let (_, view) = view("낫")
        view.setMarkedText("낫", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        XCTAssertTrue(view.hasMarkedText())
        let duringComposition = expectation(description: "no check during composition")
        duringComposition.isInverted = true
        let controller = LiveProofreadingController(textView: view, delay: 0.01, check: { _ in
            let composing = await MainActor.run { view.hasMarkedText() }
            if composing { duringComposition.fulfill() }
            return "났"
        })
        defer { controller.stop() }
        wait(for: [duringComposition], timeout: 0.1)
        XCTAssertTrue(controller.markedRanges.isEmpty)
        view.unmarkText()
        controller.schedule()
        waitUntil { !controller.markedRanges.isEmpty }
        XCTAssertEqual(view.string, "낫")
    }

    func testLateResultsCannotAnnotateChangedText() {
        let (_, view) = view("틀린 문장.")
        let started = expectation(description: "check started")
        var continuation: CheckedContinuation<String, Error>?
        var calls = 0
        let controller = LiveProofreadingController(textView: view, delay: 0.01, check: { text in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() } }
            return text
        })
        defer { controller.stop() }
        wait(for: [started], timeout: 3)
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: view.string.utf16.count), with: "새 원문.")
        continuation?.resume(returning: "다른 제안.")
        waitUntil { calls >= 2 }
        XCTAssertTrue(controller.markedRanges.isEmpty)
        XCTAssertEqual(view.string, "새 원문.")
    }

    func testScrollingEditorAutomaticallyChecksWithoutSelection() throws {
        try verifyAutomaticEditor(mode: .scroll)
    }

    func testPagedEditorAutomaticallyChecksWithoutSelection() throws {
        try verifyAutomaticEditor(mode: .paged)
    }

    private func verifyAutomaticEditor(mode: SettingsManager.ReadingPageMode) throws {
        _ = NSApplication.shared
        let previous = SettingsManager.shared.readingPageMode
        SettingsManager.shared.readingPageMode = mode
        defer { SettingsManager.shared.readingPageMode = previous }
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(string: "회의가 끝낫습니다.")
        let editor = EditorWindowController()
        doc.addWindowController(editor)
        editor.window?.isReleasedWhenClosed = false
        editor.window?.makeKeyAndOrderFront(nil)
        defer {
            doc.updateChangeCount(.changeCleared)
            editor.window?.close(); doc.removeWindowController(editor)
        }
        let original = NSAttributedString(attributedString: doc.content)
        let index = (doc.content.string as NSString).range(of: "낫").location
        waitUntil {
            let view: NSTextView? = mode == .scroll ? editor.editorVC.textView : editor.readerVC?.visiblePageTextViews.first
            return view?.layoutManager?.temporaryAttribute(.underlineColor, atCharacterIndex: index, effectiveRange: nil) != nil
        }
        XCTAssertTrue(doc.content.isEqual(to: original))
        XCTAssertFalse(doc.isDocumentEdited)
    }
}
