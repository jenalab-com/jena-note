import Foundation
import XCTest
@testable import JenaNoteKit

final class KiwiProofreadingTests: XCTestCase {
    func testNativeCorrectionsPreserveNamesAndLayout() async throws {
        let engine = KiwiProofreadingEngine.shared
        let examples = [
            ("오늘학교에갔다.", "오늘 학교에 갔다."),
            ("회의가 끝낫습니다.", "회의가 끝났습니다."),
            ("안녕 하세요.", "안녕하세요."),
            ("오늘학교에갓다.", "오늘 학교에 갔다."),
            ("선섕님", "선생님"),
            ("하연은 서준에게 책을 건넸다.", "하연은 서준에게 책을 건넸다."),
            ("  오늘학교에갔다.\r\n\r\n\t안녕 하세요.  😀", "  오늘 학교에 갔다.\r\n\r\n\t안녕하세요.  😀"),
            ("Hello world!", "Hello world!"),
            ("https://example.com/a?q=1 😀", "https://example.com/a?q=1 😀")
        ]
        for (source, expected) in examples {
            let start = Date()
            let result = try await engine.check(source)
            print("Kiwi sample: \(source.debugDescription) → \(result.debugDescription), \(Date().timeIntervalSince(start) * 1000) ms")
            XCTAssertEqual(result, expected, source)
        }
    }

    func testRepeatedChecksReuseModelAndReportWarmLatency() async throws {
        let engine = KiwiProofreadingEngine.shared
        _ = try await engine.check("오늘학교에갔다.")
        var elapsed: [Double] = []
        for _ in 0..<30 {
            let start = Date()
            let result = try await engine.check("회의가 끝낫습니다.")
            XCTAssertEqual(result, "회의가 끝났습니다.")
            elapsed.append(Date().timeIntervalSince(start) * 1000)
        }
        elapsed.sort()
        print("Kiwi warm 30 checks: median \(elapsed[15]) ms, p95 \(elapsed[28]) ms, max \(elapsed[29]) ms")
        // Timing is recorded, not a fragile CI threshold. Correctness must hold on every call.
    }

    func testMissingModelFailsWithoutAnyFallback() async {
        let engine = KiwiProofreadingEngine(modelURL: { nil })
        do {
            _ = try await engine.check("원문")
            XCTFail("A missing local model must be reported")
        } catch { XCTAssertEqual(error.localizedDescription, L10n.tr("proof.modelMissing")) }
    }

    func testSpacingCannotRewriteCharactersOrSplitProtectedWords() {
        let source = "서준에게 😀"
        XCTAssertEqual(KiwiProofreadingEngine.preserveProtectedSpacing(source: source, candidate: "서 준에게 😀", protected: [NSRange(location: 0, length: 1)]), source)
        XCTAssertEqual(KiwiProofreadingEngine.preserveProtectedSpacing(source: source, candidate: "서진에게 😀", protected: []), source)
    }

    func testDefaultProofreadingDoesNotWaitForWorkSummary() {
        let started = expectation(description: "summary started")
        let finished = expectation(description: "summary finished")
        let corrected = expectation(description: "independent check")
        var release: CheckedContinuation<String, Error>?
        _ = AILocalInferenceQueue.shared.enqueue(priority: .background, timeout: 10, operation: {
            try await withCheckedThrowingContinuation { release = $0; started.fulfill() }
        }) { _ in finished.fulfill() }
        wait(for: [started], timeout: 2)
        let service = AISelectionProofreader()
        _ = service.check("안녕 하세요.") { result in
            XCTAssertEqual(try? result.get(), "안녕하세요.")
            corrected.fulfill()
        }
        wait(for: [corrected], timeout: 5)
        release?.resume(returning: "summary")
        wait(for: [finished], timeout: 2)
    }
}
