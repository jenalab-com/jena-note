import XCTest
@testable import JenaNoteKit

final class AIWorkLocalSummarizerTests: XCTestCase {
    private func passage(_ text: String = "부활은 불가능하다. 치료만 가능하다.") -> AIIndexedPassage {
        AIWorkIndex.split(text: text, path: "rules.md", isSetting: true)[0]
    }

    func testLocalSuccessAndFailurePreserveProvenanceAndOriginal() {
        let success = expectation(description: "local"), fallback = expectation(description: "excerpt")
        let original = passage()
        let local = AIWorkLocalSummarizer(infer: { _ in "  부활 불가, 치료 가능  " })
        _ = local.generate(original) { result in
            do {
                let summary = try result.get()
                XCTAssertEqual(summary.origin, .apple)
                XCTAssertEqual(summary.text, "부활 불가, 치료 가능")
                XCTAssertNil(summary.issue)
            } catch { XCTFail("\(error)") }
            success.fulfill()
        }
        let failed = AIWorkLocalSummarizer(infer: { _ in throw AIError(message: "model refusal") })
        _ = failed.generate(original) { result in
            do {
                let summary = try result.get()
                XCTAssertEqual(summary.origin, .excerpt)
                XCTAssertEqual(summary.text, original.text)
                XCTAssertEqual(summary.issue, "ai.index.localFailed")
            } catch { XCTFail("\(error)") }
            fallback.fulfill()
        }
        wait(for: [success, fallback], timeout: 5)
    }

    func testTimeoutFallsBackButExplicitCancellationDoesNotPublishSummary() {
        let timeout = expectation(description: "timeout"), cancelled = expectation(description: "cancelled")
        let slow: AIWorkLocalSummarizer.Infer = { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "should never arrive"
        }
        let local = AIWorkLocalSummarizer(timeoutSeconds: 0.02, infer: slow)
        _ = local.generate(passage()) { result in
            XCTAssertEqual(try? result.get().issue, "ai.index.localTimeout")
            timeout.fulfill()
        }
        let cancel = local.generate(passage()) { result in
            if case .success = result { XCTFail("Cancelled jobs must not publish excerpts or AI summaries") }
            cancelled.fulfill()
        }
        cancel()
        wait(for: [timeout, cancelled], timeout: 5)
    }

    func testMultipleWorksShareSequentialInferenceAndCancelledQueueEntryIsSkipped() {
        var started: [String] = []
        var active = 0, maximumActive = 0
        let done = expectation(description: "all jobs")
        done.expectedFulfillmentCount = 3
        let local = AIWorkLocalSummarizer(infer: { passage in
            started.append(passage.text)
            active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            try await Task.sleep(nanoseconds: 20_000_000)
            return passage.text
        })
        _ = local.generate(passage("first")) { _ in done.fulfill() }
        let cancel = local.generate(passage("cancelled")) { _ in done.fulfill() }
        _ = local.generate(passage("last")) { _ in done.fulfill() }
        cancel()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(started, ["first", "last"])
        XCTAssertEqual(maximumActive, 1)
    }

    func testCancellingRunningInferencePropagatesToTheModel() {
        let started = expectation(description: "started"), done = expectation(description: "cancelled")
        var observedCancellation = false
        let local = AIWorkLocalSummarizer(infer: { _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { observedCancellation = true; throw error }
            return "late"
        })
        let cancel = local.generate(passage()) { result in
            if case .success = result { XCTFail("Cancellation is not a summary failure fallback") }
            done.fulfill()
        }
        wait(for: [started], timeout: 2)
        cancel()
        wait(for: [done], timeout: 2)
        XCTAssertTrue(observedCancellation)
    }

    func testEmptyResponseIsAnExcerptNotAFalseSuccessfulSummary() {
        let done = expectation(description: "empty")
        let local = AIWorkLocalSummarizer(infer: { _ in " \n " })
        _ = local.generate(passage()) { result in
            XCTAssertEqual(try? result.get().origin, .excerpt)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
