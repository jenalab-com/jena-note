// Compile this harness together with Sources/JenaNoteKit/ai/AIWorkLocalSummarizer.swift.
// Lightweight domain stubs let the unchanged production adapter run outside the app.
import Foundation
struct AIIndexedPassage { let text: String; let isSetting: Bool }
struct AIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func tr(_ key: String) -> String { key } }

@main struct Smoke {
    @MainActor static func main() async {
        let availability = AIWorkLocalSummarizer.availability()
        print("availability: \(availability)")
        guard availability == .available else { return }
        let cases = [
            ("setting", "하연은 별빛 도서관의 사서다. 도서관은 월요일에 쉬며, 화요일부터 일요일까지 오전 아홉 시에 문을 연다. 서준은 하연의 동생이다. 하연은 손님에게 존댓말을 쓰지만 서준에게는 반말을 쓴다. 책은 한 사람당 세 권까지 빌릴 수 있다. 단, 연구원은 다섯 권까지 빌릴 수 있다.", true),
            ("episode", "서준은 화요일 아침 도서관에 갔다. 하연은 서준에게 푸른 표지의 책을 건넸다. 서준은 책 사이에서 별 모양 책갈피를 발견했다. 하연은 그 책갈피가 할머니의 선물이라고 말했다. 서준은 책갈피를 하연에게 돌려주고, 책만 빌려 나왔다.", false)
        ]
        for (name, text, setting) in cases {
            let start = Date()
            let result: Result<AIIndexSummary, Error> = await withCheckedContinuation { continuation in
                _ = AIWorkLocalSummarizer.shared.generate(AIIndexedPassage(text: text, isSetting: setting)) {
                    continuation.resume(returning: $0)
                }
            }
            print("case: \(name), elapsed: \(Date().timeIntervalSince(start))")
            switch result {
            case .success(let summary): print("origin: \(summary.origin), issue: \(summary.issue ?? "none")\n\(summary.text)")
            case .failure(let error): print("error: \(error)")
            }
        }
    }
}
