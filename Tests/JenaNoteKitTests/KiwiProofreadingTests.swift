import Foundation
import XCTest
@testable import JenaNoteKit

final class KiwiProofreadingTests: XCTestCase {
    func testNativeCorrectionsPreserveNamesAndLayout() async throws {
        let engine = KiwiProofreadingEngine.shared
        let examples = [
            ("그제야 리에느가 빵을 받았다.", "그제야 리에느가 빵을 받았다."),
            ("😀 그제야 리에느가 빵을 받았다.", "😀 그제야 리에느가 빵을 받았다."),
            ("나는 학교 에 갔다.", "나는 학교에 갔다."),
            ("오랫만에 친구를 만났다.", "오랜만에 친구를 만났다."),
            ("몇일 동안 기다렸다.", "며칠 동안 기다렸다."),
            ("몇 일 동안 기다렸다.", "며칠 동안 기다렸다."),
            ("이건 않되요.", "이건 안 돼요."),
            ("서준은학교에갔다.", "서준은 학교에 갔다."),
            ("오늘  학교에갔다.", "오늘 학교에 갔다."),
            ("오늘학교에갔다.", "오늘 학교에 갔다."),
            ("회의가 끝낫습니다.", "회의가 끝났습니다."),
            ("안녕 하세요.", "안녕하세요."),
            ("오늘학교에갓다.", "오늘 학교에 갔다."),
            ("선섕님", "선생님"),
            ("하연은 서준에게 책을 건넸다.", "하연은 서준에게 책을 건넸다."),
            ("  오늘학교에갔다.\r\n\r\n\t안녕 하세요.  😀", "  오늘 학교에 갔다.\r\n\r\n\t안녕하세요. 😀"),
            ("  오늘학교에갔다.  ", "  오늘 학교에 갔다.  "),
            ("   ", "   "),
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

    /// 한글 맞춤법 제47항(보조 용언 붙여 씀 허용)과 한자어 접미 명사는 띄우라고 제안하지 않는다.
    func testPermittedJoinedSpellingIsNotSplit() async throws {
        let engine = KiwiProofreadingEngine.shared
        let examples = [
            ("불이 꺼져간다.", "불이 꺼져간다."),
            ("먹어보았다.", "먹어보았다."),
            ("어머니를 도와드린다.", "어머니를 도와드린다."),
            ("그릇을 깨뜨려버렸다.", "그릇을 깨뜨려버렸다."),
            ("수출량을 늘렸다.", "수출량을 늘렸다."),
            ("생산력이 늘었다.", "생산력이 늘었다."),
            // Spacing that the rules require is still suggested.
            ("불이 꺼져 간다.", "불이 꺼져 간다."),
            ("책상위에 책이 있다.", "책상 위에 책이 있다."),
            ("떠난 지 사흘만에 돌아왔다.", "떠난 지 사흘 만에 돌아왔다."),
            ("국장겸 과장이다.", "국장 겸 과장이다."),
            ("홍길동씨가 왔다.", "홍길동 씨가 왔다."),
            ("그는 먹고 싶어 한다.", "그는 먹고 싶어 한다.")
        ]
        for (source, expected) in examples {
            let result = try await engine.check(source)
            XCTAssertEqual(result, expected, source)
        }
    }

    /// 공백 정책이 규정상 붙여야 하거나(제42·47항) 띄워야 하는(제47항 구 + -어 하다) 자리를 따른다.
    func testRequiredSpacingFollowsOrthographyRules() async throws {
        let engine = KiwiProofreadingEngine.shared
        let examples = [
            ("낙서가 지워 진다.", "낙서가 지워진다."),
            ("아기를 예뻐 한다.", "아기를 예뻐한다."),
            ("남자 뿐이다.", "남자뿐이다."),
            ("약속 대로 하자.", "약속대로 하자."),
            ("그는 먹고 싶어한다.", "그는 먹고 싶어 한다."),
            ("그는 마음에 들어한다.", "그는 마음에 들어 한다."),
            // The same forms after a modifier stay bound nouns.
            ("웃을 뿐이다.", "웃을 뿐이다."),
            ("아는 대로 말한다.", "아는 대로 말한다."),
            ("그는 행복해한다.", "그는 행복해한다.")
        ]
        for (source, expected) in examples {
            let result = try await engine.check(source)
            XCTAssertEqual(result, expected, source)
        }
    }

    /// 제40항 붙임 2(하 탈락/축약)와 제35항 붙임 2(됬 → 됐).
    func testContractedHaAndDoeEndingsFollowOrthography() async throws {
        let engine = KiwiProofreadingEngine.shared
        let examples = [
            ("넉넉치 않다.", "넉넉지 않다."),
            ("깨끗치 않은 물.", "깨끗지 않은 물."),
            ("섭섭치 않게 대했다.", "섭섭지 않게 대했다."),
            ("생각컨대 옳다.", "생각건대 옳다."),
            ("흔지 않다.", "흔치 않다."),
            ("간편게 했다.", "간편케 했다."),
            ("일이 잘 됬다.", "일이 잘 됐다."),
            // Already correct: aspirate after a sonorant, full `하`, lexicalized adverbs.
            ("흔치 않다.", "흔치 않다."),
            ("만만치 않다.", "만만치 않다."),
            ("회상컨대 좋았다.", "회상컨대 좋았다."),
            ("청컨대 들어주오.", "청컨대 들어주오."),
            ("넉넉하지 않다.", "넉넉하지 않다."),
            ("생각지도 몰랐다.", "생각지도 몰랐다."),
            ("요컨대 옳다.", "요컨대 옳다."),
            ("결코 아니다.", "결코 아니다.")
        ]
        for (source, expected) in examples {
            let result = try await engine.check(source)
            XCTAssertEqual(result, expected, source)
        }
    }

    func testContractedHaEditsUseStemFinal() {
        func edits(_ text: String, _ tokens: [(String, String, Int, Int)]) -> [String] {
            KiwiProofreadingEngine.contractedHaEdits(tokens.map { ($0.0, $0.1, NSRange(location: $0.2, length: $0.3)) }, in: text).map(\.text)
        }
        XCTAssertEqual(edits("넉넉치", [("넉넉", "XR", 0, 2), ("하", "XSA", 2, 1), ("지", "EC", 2, 1)]), ["지"])
        XCTAssertEqual(edits("흔지", [("흔", "XR", 0, 1), ("하", "XSA", 1, 0), ("지", "EC", 1, 1)]), ["치"])
        XCTAssertEqual(edits("넉넉하지", [("넉넉", "XR", 0, 2), ("하", "XSA", 2, 1), ("지", "EC", 3, 1)]), [])
    }

    /// 제51항(-이/-히 부사)과 제53항(-ㄹ게·-ㄹ지·-ㄹ수록·-ㄹ걸 예사소리).
    func testAdverbSuffixAndPlainEndingsFollowOrthography() async throws {
        let engine = KiwiProofreadingEngine.shared
        let examples = [
            ("깨끗히 씻었다.", "깨끗이 씻었다."),
            ("따뜻히 입어라.", "따뜻이 입어라."),
            ("틈틈히 읽었다.", "틈틈이 읽었다."),
            ("일찍히 떠났다.", "일찍이 떠났다."),
            ("많히 먹어라.", "많이 먹어라."),
            ("솔직이 말해라.", "솔직히 말해라."),
            ("꼼꼼이 살폈다.", "꼼꼼히 살폈다."),
            ("간편이 했다.", "간편히 했다."),
            ("내가 갈께.", "내가 갈게."),
            ("먹을께요.", "먹을게요."),
            ("올찌 모르겠다.", "올지 모르겠다."),
            ("볼쑤록 좋다.", "볼수록 좋다."),
            ("그럴껄 그랬다.", "그럴걸 그랬다."),
            ("할껄요.", "할걸요."),
            // Standard spellings and look-alikes stay.
            ("깊숙이 묻었다.", "깊숙이 묻었다."),
            ("넉넉히 줘라.", "넉넉히 줘라."),
            ("더욱이 좋다.", "더욱이 좋다."),
            ("특히 좋다.", "특히 좋다."),
            ("급이 다르다.", "급이 다르다."),
            ("선생님께 드렸다.", "선생님께 드렸다."),
            ("김치찌개를 먹었다.", "김치찌개를 먹었다."),
            ("죽을 쑤었다.", "죽을 쑤었다."),
            ("껄껄 웃었다.", "껄껄 웃었다."),
            ("그럴걸 그랬다.", "그럴걸 그랬다."),
            ("먹을 걸 사 왔다.", "먹을 걸 사 왔다.")
        ]
        for (source, expected) in examples {
            let result = try await engine.check(source)
            XCTAssertEqual(result, expected, source)
        }
    }

    func testAdverbSuffixEditsNeedRuleAndDictionary() {
        func edits(_ text: String, _ tokens: [(String, String, Int, Int)], adverbs: Set<String>, roots: Set<String>) -> [String] {
            KiwiProofreadingEngine.adverbSuffixEdits(tokens.map { ($0.0, $0.1, NSRange(location: $0.2, length: $0.3)) }, in: text,
                                                     isAdverb: adverbs.contains, takesHada: roots.contains).map(\.text)
        }
        // ㅅ final → 이, confirmed by the dictionary.
        XCTAssertEqual(edits("따뜻히", [("따뜻", "XR", 0, 2), ("히", "XSM", 2, 1)], adverbs: ["따뜻이"], roots: ["따뜻"]), ["이"])
        // Unlisted result: no edit for an ㄱ-final root, rule alone for other `-하다` roots.
        XCTAssertEqual(edits("깊숙히", [("깊숙", "XR", 0, 2), ("히", "XSM", 2, 1)], adverbs: [], roots: ["깊숙"]), [])
        XCTAssertEqual(edits("간편이", [("간편", "XR", 0, 2), ("이", "XSM", 2, 1)], adverbs: [], roots: ["간편"]), ["히"])
        // A repeated mimetic root is not a repeated noun: 꼼꼼 takes `-하다`, so 히.
        XCTAssertEqual(edits("꼼꼼이", [("꼼꼼", "MAG", 0, 2), ("이", "XSM", 2, 1)], adverbs: ["꼼꼼히"], roots: ["꼼꼼"]), ["히"])
    }

    func testOrthographySpacingFollowsAuxiliaryAndParticleRules() {
        func rules(_ text: String, _ tokens: [(String, String, Int, Int)]) -> (joins: Set<Int>, splits: Set<Int>) {
            KiwiProofreadingEngine.orthographySpacing(tokens.map { ($0.0, $0.1, NSRange(location: $0.2, length: $0.3)) }, in: text)
        }
        // 예쁘/VA 어/EC 하/VX: adjective + `-어 하다` is joined, spaced or not (제47항).
        XCTAssertEqual(rules("예뻐 한다", [("예쁘", "VA", 0, 2), ("어", "EC", 1, 1), ("하", "VX", 3, 1), ("ᆫ다", "EF", 3, 2)]).joins, [2])
        // 싶/VX 어/EC 하/VX: a phrase + `-어 하다` requires a space.
        let phrase = rules("싶어한다", [("싶", "VX", 0, 1), ("어", "EC", 1, 1), ("하", "VX", 2, 1), ("ᆫ다", "EF", 2, 2)])
        XCTAssertEqual(phrase.joins, [])
        XCTAssertEqual(phrase.splits, [2])
        // Other auxiliaries: an attached source is kept, a spaced source is left alone.
        XCTAssertEqual(rules("꺼져간다", [("꺼지", "VV", 0, 2), ("어", "EC", 1, 1), ("가", "VX", 2, 1), ("ᆫ다", "EF", 2, 2)]).joins, [2])
        XCTAssertEqual(rules("꺼져 간다", [("꺼지", "VV", 0, 2), ("어", "EC", 1, 1), ("가", "VX", 3, 1), ("ᆫ다", "EF", 3, 2)]).joins, [])
        // `뿐` after a noun is a particle, after a modifier a bound noun (제42항).
        XCTAssertEqual(rules("남자 뿐", [("남자", "NNG", 0, 2), ("뿐", "NNB", 3, 1)]).joins, [2])
        XCTAssertEqual(rules("웃을 뿐", [("웃", "VV", 0, 1), ("을", "ETM", 1, 1), ("뿐", "NNB", 3, 1)]).joins, [])
    }

    func testCorrectSentenceWithUnfamiliarNameHasNoTooltipSuggestion() async throws {
        let source = "그제야 리에느가 빵을 받았다."
        let corrected = try await KiwiProofreadingEngine.shared.check(source)
        XCTAssertTrue(ProofreadingSuggestion.suggestions(source: source, corrected: corrected).isEmpty)
    }

    func testRulesPreserveValidWordsAndDoNotReplaceNameSubstrings() {
        for text in ["오랜만에", "오랫동안", "몇일리아", "눈꼽나라", "웬일", "안 되나요", "되지 않는다", "일이 안돼서 걱정이다"] {
            XCTAssertEqual(KoreanOrthographyRules.correct(text), text)
        }
        XCTAssertEqual(KoreanOrthographyRules.correct("눈꼽이 머릿말을 할께요"), "눈곱이 머리말을 할게요")
        let source = "https://example.com/오랫만"
        XCTAssertEqual(KoreanOrthographyRules.correct(source, excluding: [NSRange(location: 0, length: source.utf16.count)]), source)
    }

    func testDictionarySuppressesRuleCorrectionWithoutHidingOtherErrors() async throws {
        let source = "오랫만에 몇일 동안 기다렸다."
        let corrected = try await KiwiProofreadingEngine.shared.check(source)
        XCTAssertEqual(ProofreadingSuggestion.filteredText(source: source, corrected: corrected, terms: ["오랫만"]),
                       "오랫만에 며칠 동안 기다렸다.")
    }

    func testNameProtectionLeavesFollowingSentenceSpacingEditable() {
        XCTAssertEqual(KiwiProofreadingEngine.preserveProtectedSpacing(source: "서준은학교에갔다.", candidate: "서 준은 학교에 갔다.", protected: [NSRange(location: 0, length: 3)]), "서준은 학교에 갔다.")
        XCTAssertEqual(KiwiProofreadingEngine.preserveProtectedSpacing(source: "😀서준은학교", candidate: "😀 서 준은 학교", protected: [NSRange(location: 2, length: 3)]), "😀 서준은 학교")
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
        XCTAssertEqual(KiwiProofreadingEngine.preserveProtectedSpacing(source: source, candidate: "서 준에게 😀", protected: [NSRange(location: 0, length: 4)]), source)
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
