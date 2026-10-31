import AppKit
import XCTest
@testable import JenaNoteKit

final class AIProofreadingTests: XCTestCase {
    func testInteractiveRequestPassesQueuedSummariesWithoutInterruptingCurrentJob() {
        let queue = AILocalInferenceQueue()
        let started = expectation(description: "first running"), done = expectation(description: "all finished")
        done.expectedFulfillmentCount = 3
        var release: CheckedContinuation<String, Error>?
        var order: [String] = []
        _ = queue.enqueue(priority: .background, timeout: 5, operation: {
            order.append("active")
            return try await withCheckedThrowingContinuation { release = $0; started.fulfill() }
        }) { _ in done.fulfill() }
        wait(for: [started], timeout: 2)
        _ = queue.enqueue(priority: .background, timeout: 5, operation: { order.append("summary"); return "s" }) { _ in done.fulfill() }
        _ = queue.enqueue(priority: .interactive, timeout: 5, operation: { order.append("proofread"); return "p" }) { _ in done.fulfill() }
        XCTAssertEqual(order, ["active"])
        release?.resume(returning: "a")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(order, ["active", "proofread", "summary"])
    }

    func testTimeoutReportsImmediatelyButDoesNotOverlapUncooperativeInference() {
        let queue = AILocalInferenceQueue()
        let started = expectation(description: "started"), timedOut = expectation(description: "timeout"), next = expectation(description: "next")
        var release: CheckedContinuation<String, Error>?
        var nextStarted = false
        var callbacks = 0
        _ = queue.enqueue(priority: .interactive, timeout: 0.03, operation: {
            try await withCheckedThrowingContinuation { release = $0; started.fulfill() }
        }) { result in
            callbacks += 1
            if case .failure(let error) = result { XCTAssertTrue(error is AILocalInferenceQueue.Failure) }
            else { XCTFail("Must time out") }
            timedOut.fulfill()
        }
        wait(for: [started], timeout: 2)
        _ = queue.enqueue(priority: .background, timeout: 5, operation: { nextStarted = true; return "next" }) { _ in next.fulfill() }
        wait(for: [timedOut], timeout: 2)
        XCTAssertFalse(nextStarted, "Cancelled Foundation Models work still owns the inference slot until it returns")
        release?.resume(returning: "late correction")
        wait(for: [next], timeout: 2)
        XCTAssertEqual(callbacks, 1)
    }

    func testProofreadingQueueWaitCountsTowardTimeoutAndNeverCallsModelAfterExpiry() {
        let queue = AILocalInferenceQueue()
        let started = expectation(description: "summary running"), timedOut = expectation(description: "check expired"), finished = expectation(description: "released")
        var release: CheckedContinuation<String, Error>?
        _ = queue.enqueue(priority: .background, timeout: 5, operation: {
            try await withCheckedThrowingContinuation { release = $0; started.fulfill() }
        }) { _ in finished.fulfill() }
        wait(for: [started], timeout: 2)
        let service = AISelectionProofreader(queue: queue, timeout: 0.02, availability: { .available }, infer: { _ in
            XCTFail("Expired queued check must not run")
            return "unused"
        })
        _ = service.check("오늘학교에갔다.") { result in
            XCTAssertEqual((try? result.get()), nil)
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 2)
        release?.resume(returning: "summary")
        wait(for: [finished], timeout: 2)
    }

    func testSelectionLimitsAndUnavailableModelDoNotInvokeInference() {
        var calls = 0
        let service = AISelectionProofreader(availability: { .unavailable("proof.modelMissing") }, infer: { text in calls += 1; return text })
        for text in ["", " \n ", String(repeating: "가", count: 501), "원문\0숨김", "이미지\u{fffc}", "오늘 학교에 갔다."] {
            var failed = false
            _ = service.check(text) { if case .failure = $0 { failed = true } }
            XCTAssertTrue(failed)
        }
        XCTAssertEqual(calls, 0)
        XCTAssertNoThrow(try AISelectionProofreader.validate(String(repeating: "가", count: 500)))
        XCTAssertThrowsError(try AISelectionProofreader.validate(String(repeating: "👨‍👩‍👧‍👦", count: 100)))
    }

    func testEmptyCorrectionIsAFailureNotADeletionSuggestion() {
        let done = expectation(description: "invalid output")
        let service = AISelectionProofreader(queue: AILocalInferenceQueue(), availability: { .available }, infer: { _ in "\n " })
        _ = service.check("원문") { result in
            if case .success = result { XCTFail("An empty response must never delete selected text") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}

final class AIProofreadingEditorTests: XCTestCase {
    private var oldMode: SettingsManager.ReadingPageMode!

    override func setUp() {
        _ = NSApplication.shared
        oldMode = SettingsManager.shared.readingPageMode
        SettingsManager.shared.readingPageMode = .scroll
    }
    override func tearDown() { SettingsManager.shared.readingPageMode = oldMode }

    private func makeEditor() -> (MarkdownDocument, EditorWindowController) {
        let doc = MarkdownDocument()
        doc.content = NSMutableAttributedString(attributedString: MarkdownSerializer.parse("앞 **강조** 오늘학교에갓다. 뒤 😀"))
        doc.undoManager?.groupsByEvent = false
        let editor = EditorWindowController()
        doc.addWindowController(editor)
        editor.window?.isReleasedWhenClosed = false
        editor.window?.makeKeyAndOrderFront(nil)
        editor.selectDocumentRange((doc.content.string as NSString).range(of: "오늘학교에갓다."))
        addTeardownBlock {
            editor.proofreadingController?.cancel()
            doc.updateChangeCount(.changeCleared)
            editor.window?.close()
            doc.removeWindowController(editor)
        }
        return (doc, editor)
    }

    private func waitUntil(_ description: String, _ predicate: @escaping () -> Bool) {
        let done = expectation(description: description)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if predicate() { timer.invalidate(); done.fulfill() }
        }
        defer { timer.invalidate() }
        wait(for: [done], timeout: 3)
    }

    func testComparisonDoesNotEditUntilApplyAndOneUndoRestoresOriginalWithFormatting() throws {
        let (doc, editor) = makeEditor()
        let original = NSAttributedString(attributedString: doc.content)
        var inputs: [String] = []
        editor.proofreadingService = AISelectionProofreader(queue: AILocalInferenceQueue(), availability: { .available }, infer: { text in
            inputs.append(text)
            return "오늘 학교에 갔다."
        })
        editor.proofreadSelection(nil)
        let sheet = try XCTUnwrap(editor.proofreadingController)
        waitUntil("suggestion") { sheet.suggestion != nil }
        XCTAssertEqual(inputs, ["오늘학교에갓다."])
        XCTAssertTrue(doc.content.isEqual(to: original))
        XCTAssertTrue(sheet.alert.buttons[0].isEnabled)
        let view = try XCTUnwrap(sheet.alert.window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/jena-proofreading.png"))
        sheet.alert.buttons[0].performClick(nil)
        waitUntil("applied") { editor.proofreadingController == nil }
        XCTAssertEqual(doc.content.string, original.string.replacingOccurrences(of: "오늘학교에갓다.", with: "오늘 학교에 갔다."))
        doc.undoManager?.undo()
        XCTAssertTrue(doc.content.isEqual(to: original), "Undo preserves source formatting and selection-external content")
    }

    func testPagedSelectionUsesDocumentRangeAndChangedDocumentRejectsApplication() throws {
        SettingsManager.shared.readingPageMode = .paged
        let (doc, editor) = makeEditor()
        XCTAssertNotNil(editor.readerVC)
        let range = editor.documentSelection
        let snapshot = AIEditSnapshot(document: doc, selection: range)
        XCTAssertEqual(snapshot.content.attributedSubstring(from: snapshot.range).string, "오늘학교에갓다.")
        doc.content.append(NSAttributedString(string: " 외부 수정"))
        let changed = NSAttributedString(attributedString: doc.content)
        XCTAssertThrowsError(try editor.applyProofreading("오늘 학교에 갔다.", snapshot: snapshot))
        XCTAssertTrue(doc.content.isEqual(to: changed))
    }

    func testNoSelectionDisablesInspectionAndCancelLeavesSourceUnchanged() throws {
        let (doc, editor) = makeEditor()
        let original = NSAttributedString(attributedString: doc.content)
        let started = expectation(description: "inference started")
        var release: CheckedContinuation<String, Error>?
        editor.proofreadingService = AISelectionProofreader(queue: AILocalInferenceQueue(), availability: { .available }, infer: { _ in
            try await withCheckedThrowingContinuation { release = $0; started.fulfill() }
        })
        editor.proofreadSelection(nil)
        wait(for: [started], timeout: 2)
        let sheet = try XCTUnwrap(editor.proofreadingController)
        sheet.cancel()
        release?.resume(returning: "늦은 결과")
        waitUntil("closed") { editor.proofreadingController == nil }
        XCTAssertTrue(doc.content.isEqual(to: original))
        editor.selectDocumentRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(editor.canProofreadSelection)
        editor.proofreadSelection(nil)
        XCTAssertNil(editor.proofreadingController)
    }

    func testUnchangedResultDoesNotEnableApply() throws {
        let (doc, editor) = makeEditor()
        let original = NSAttributedString(attributedString: doc.content)
        editor.proofreadingService = AISelectionProofreader(queue: AILocalInferenceQueue(), availability: { .available }, infer: { $0 })
        editor.proofreadSelection(nil)
        let sheet = try XCTUnwrap(editor.proofreadingController)
        waitUntil("no correction") { sheet.suggestion != nil }
        XCTAssertFalse(sheet.alert.buttons[0].isEnabled)
        XCTAssertTrue(doc.content.isEqual(to: original))
        sheet.cancel()
        waitUntil("closed") { editor.proofreadingController == nil }
    }
}
