import Foundation
import Kiwi
struct AIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func tr(_ key: String) -> String { key } }
extension Bundle { static var module: Bundle { .main } }
@main struct T { static func main() async throws {
    let p = CommandLine.arguments[1]
    let e = KiwiProofreadingEngine(modelURL: { URL(fileURLWithPath: p, isDirectory: true) })
    for s in ["책상위에 책이 있다.", "학교앞에서 만났다.", "집안에 들어갔다.", "강물이 흐른다.", "그는 산위에 올랐다.", "오늘밤 비가 온다.", "물한병 주세요.",
              "카셀리온이검을뽑았다.", "서준은학교에갔다.", "엘라드린과미르세아는숲으로들어갔다.", "국립국어원 기획연수부", "만성골수성백혈병 환자",
              "먹어보았다.", "도와드린다.", "그는 먹고 싶어한다.", "아기를 예뻐한다.", "낙서가 지워진다.", "그릇을 깨뜨려버렸다.", "생산력이 늘었다.", "합격률이 높다.", "성공율이 낮다.", "에너지량을 쟀다.", "힘 력이 세다."] {
        print("\(s) → \(try await e.check(s))")
    }
}}
