// Compile alongside the production KiwiProofreadingEngine; no user documents are read.
import Foundation
import Kiwi
struct AIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func tr(_ key: String) -> String { key } }
// SwiftPM generates this accessor in the app. The standalone probe injects its model path.
extension Bundle { static var module: Bundle { .main } }

@main struct KiwiSmoke {
    static func main() async throws {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/JenaNoteKit/Resources/KiwiModel"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let engine = KiwiProofreadingEngine(modelURL: { url })
        print("Kiwi \(String(cString: kiwi_version()))")
        let samples = ["오늘학교에갔다.", "회의가 끝낫습니다.", "안녕 하세요.", "하연은 서준에게 책을 건넸다.", "오늘학교에갓다.", "선섕님", "  안녕 하세요.\r\n\t오늘학교에갔다.  😀", "되요.", "업습니다."]
        for text in samples {
            let started = Date()
            let output = try await engine.check(text)
            print("\(text.debugDescription) → \(output.debugDescription) (\(Date().timeIntervalSince(started) * 1000) ms)")
        }
        var elapsed: [Double] = []
        for _ in 0..<30 {
            let start = Date()
            _ = try await engine.check("회의가 끝낫습니다.")
            elapsed.append(Date().timeIntervalSince(start) * 1000)
        }
        elapsed.sort()
        print("Warm 30 checks: median \(elapsed[15]) ms, p95 \(elapsed[28]) ms, max \(elapsed[29]) ms")
    }
}
