// Compile with the production queue, summarizer and proofreading service. No user files are read.
import Foundation
struct AIIndexedPassage { let text: String; let isSetting: Bool }
struct AIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func tr(_ key: String) -> String { key } }

@main struct ProofreadingSmoke {
    @MainActor static func main() async {
        print("availability: \(AIWorkLocalSummarizer.availability())")
        guard AIWorkLocalSummarizer.availability() == .available else { return }
        let service = AISelectionProofreader()
        let samples = ["오늘학교에갔다.", "회의가 끝낫습니다.", "안녕 하세요.", "하연은 서준에게 책을 건넸다."]
        for text in samples {
            let started = Date()
            let result: Result<String, Error> = await withCheckedContinuation { continuation in
                _ = service.check(text) { continuation.resume(returning: $0) }
            }
            print("input: \(text)")
            print("seconds: \(Date().timeIntervalSince(started))")
            switch result {
            case .success(let corrected): print("output: \(corrected)")
            case .failure(let error): print("error: \(error.localizedDescription)")
            }
        }
    }
}
