import Foundation
import Kiwi
struct AIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func tr(_ key: String) -> String { key } }
extension Bundle { static var module: Bundle { .main } }
@main struct G { static func main() async throws {
    let p = CommandLine.arguments[1]
    let e = KiwiProofreadingEngine(modelURL: { URL(fileURLWithPath: p, isDirectory: true) })
    for s in ["그녀는 슬퍼한다.", "그는 좋아한다.", "그는 싫어한다.", "그는 미안해했다.", "고마워한다.", "몹시 부러워했다.", "어려워한다.", "힘들어한다.",
              "궁금해한다.", "가고 싶어했다.", "먹어 보고 싶어 한다.", "아파한다.", "그뿐만 아니라 다른 것도 있다.", "그것뿐이다.", "이것만큼은 지킨다.",
              "너 만큼 했다.", "그 사람 대로 산다.", "고칠 대로 고쳤다.", "물건이 놓여 진다.", "문이 열려 진다.", "갈 뿐 아니라", "그는 바빠 한다.",
              "할 수 있을 만큼 했다.", "나 뿐이다.", "셋 뿐이다.", "그는 졸려 한다.", "추워 한다."] {
        print("\(s) → \(try await e.check(s))")
    }
}}
