import Foundation
import Kiwi
struct AIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func tr(_ key: String) -> String { key } }
extension Bundle { static var module: Bundle { .main } }
@main struct G { static func main() async throws {
    let p = CommandLine.arguments[1]
    let e = KiwiProofreadingEngine(modelURL: { URL(fileURLWithPath: p, isDirectory: true) })
    for s in ["익숙치 않다.", "답답치 않다.", "갑갑치 않다.", "거북치 않다.", "편치 않다.", "편지 않다.", "무능타.", "정결타.", "생각타 못해 왔다.", "연구토록 했다.", "연구도록 했다.",
              "깨끗하게 씻어라.", "깨끗게 씻어라.", "깨끗케 씻어라.", "그는 착하지 않다.", "넉넉지 않다.", "섭섭지 않게", "만만찮다.", "변변찮다.", "아무렇지 않다.",
              "아니하다.", "가지 않는다.", "같지 않다.", "괜찮다.", "편하게 쉬어라.", "다행지 않다.", "넉넉치 않은 살림에 섭섭치 않게 챙겼다.", "됬어요.", "안 됬다.", "되었다."] {
        print("\(s) → \(try await e.check(s))")
    }
}}
