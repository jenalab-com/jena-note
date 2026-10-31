import Foundation
import Kiwi
struct AIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func tr(_ key: String) -> String { key } }
extension Bundle { static var module: Bundle { .main } }
@main struct G { static func main() async throws {
    let p = CommandLine.arguments[1]
    let e = KiwiProofreadingEngine(modelURL: { URL(fileURLWithPath: p, isDirectory: true) })
    let cases = [
      // targets
      "내가 갈께.", "먹을께요.", "먹을께.", "갈께요.", "그럴껄 그랬다.", "할껄요.", "올찌 모르겠다.", "볼쑤록 좋다.", "갈찌라도 간다.",
      "깨끗히 씻었다.", "따뜻히 입어라.", "반듯히 놓아라.", "버젓히 살았다.", "일일히 확인했다.", "번번히 졌다.", "틈틈히 읽었다.", "곰곰히 생각했다.",
      "더욱히 좋다.", "일찍히 떠났다.", "겹겹히 쌓였다.", "곳곳히 피었다.", "많히 먹어라.", "헛되히 보냈다.",
      "솔직이 말해라.", "꼼꼼이 살폈다.", "엄격이 다뤘다.", "간편이 했다.", "나른이 누웠다.", "섭섭이 여겼다.", "도저이 못 하겠다.",
      // guards: must stay
      "김치찌개를 먹었다.", "살이 찐다.", "칼로 찌른다.", "죽을 쑤었다.", "허리가 쑤신다.", "선생님께 드렸다.", "아들께 여쭈었다.", "할아버지께서 오셨다.",
      "같이 가자.", "높이 날았다.", "깊이 생각했다.", "깨끗이 씻었다.", "조용히 해라.", "급히 갔다.", "특히 좋다.", "익히 안다.", "솔직히 말해라.",
      "일찍이 떠났다.", "더욱이 좋다.", "곰곰이 생각했다.", "오뚝이처럼 섰다.", "깊숙이 묻었다.", "끔찍이 아꼈다.", "넉넉히 줘라.", "가만히 있어라.",
      "꾸준히 했다.", "굳이 왜?", "겹겹이 쌓였다.", "틈틈이 읽었다.", "번번이 졌다.", "일일이 셌다.", "반듯이 놓아라.", "반드시 온다.", "뚜렷이 보인다.",
      "따뜻이 입어라.", "섭섭히 여겼다.", "이따가 갈게.", "그럴걸 그랬다.", "할걸요.", "올지 모르겠다.", "볼수록 좋다.", "그가 웃을까?", "어디 갈꼬?",
      "껄껄 웃었다.", "그 얼굴이 굳히었다.", "급이 다르다.", "속이 쓰리다.", "가만이 아니다.", "물이 깊이 고였다.", "특이한 사람이다."]
    for s in cases { print("\(s) → \(try await e.check(s))") }
}}
