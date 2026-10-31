// Run examples from the NIKL orthography/standard-language commentary (2018) through the real engine.
// Each case: (rule, input, expected). Compile alongside KiwiProofreadingEngine like probe.swift.
import Foundation
import Kiwi
struct AIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func tr(_ key: String) -> String { key } }
extension Bundle { static var module: Bundle { .main } }

let cases: [(String, String, String)] = [
    // 띄어쓰기
    ("41 조사", "꽃 이나마 피었다.", "꽃이나마 피었다."),
    ("41 조사", "학교 에서처럼 해라.", "학교에서처럼 해라."),
    ("42 의존명사 것", "아는것이 힘이다.", "아는 것이 힘이다."),
    ("42 의존명사 수", "나도 할수 있다.", "나도 할 수 있다."),
    ("42 만큼(의존)", "먹을만큼 먹어라.", "먹을 만큼 먹어라."),
    ("42 만큼(조사)", "키가 전봇대 만큼 크다.", "키가 전봇대만큼 크다."),
    ("42 뿐(의존)", "웃을뿐이다.", "웃을 뿐이다."),
    ("42 뿐(조사)", "남자 뿐이다.", "남자뿐이다."),
    ("42 대로(의존)", "아는대로 말한다.", "아는 대로 말한다."),
    ("42 대로(조사)", "약속 대로 하자.", "약속대로 하자."),
    ("42 만(의존)", "떠난 지 사흘만에 돌아왔다.", "떠난 지 사흘 만에 돌아왔다."),
    ("42 지(의존)", "그를 만난지 한 달이 지났다.", "그를 만난 지 한 달이 지났다."),
    ("42 지(어미)", "어떻게 할 지 모르겠다.", "어떻게 할지 모르겠다."),
    ("42 듯(의존)", "그가 먹은듯 보였다.", "그가 먹은 듯 보였다."),
    ("43 단위", "소 한마리를 샀다.", "소 한 마리를 샀다."),
    ("43 숫자+단위(허용)", "사과 10개를 샀다.", "사과 10개를 샀다."),
    ("45 겸", "국장겸 과장이다.", "국장 겸 과장이다."),
    ("45 등", "사과, 배등이 있다.", "사과, 배 등이 있다."),
    ("47 -어 지다", "낙서가 지워 진다.", "낙서가 지워진다."),
    ("47 -어 하다", "아기를 예뻐 한다.", "아기를 예뻐한다."),
    ("47 구+-어 하다", "그는 먹고 싶어 한다.", "그는 먹고 싶어 한다."),
    ("47 구+-어 하다", "그는 마음에 들어 한다.", "그는 마음에 들어 한다."),
    ("47 종결어미+보조", "그가 밥을 먹나보다.", "그가 밥을 먹나 보다."),
    ("47 허용(유지)", "불이 꺼져 간다.", "불이 꺼져 간다."),
    ("47 허용(유지)", "불이 꺼져간다.", "불이 꺼져간다."),
    ("47 조사 개입", "직접 먹어도보았다.", "직접 먹어도 보았다."),
    ("48 호칭", "홍길동씨가 왔다.", "홍길동 씨가 왔다."),
    ("48 성명(유지)", "김양수 선생이 왔다.", "김양수 선생이 왔다."),
    // 형태·그 밖의 것
    ("35 되어→돼", "그렇게 되서 반갑다.", "그렇게 돼서 반갑다."),
    ("35 됬→됐", "일이 잘 됬다.", "일이 잘 됐다."),
    ("35 돼→되(어간)", "부자가 돼고 싶다.", "부자가 되고 싶다."),
    ("39 -잖-", "그렇쟎아.", "그렇잖아."),
    ("40 -지(하 탈락)", "넉넉치 않다.", "넉넉지 않다."),
    ("40 -지(하 탈락)", "깨끗치 않은 물.", "깨끗지 않은 물."),
    ("40 -건대", "생각컨대 옳다.", "생각건대 옳다."),
    ("40 않/안", "밥을 않 먹었다.", "밥을 안 먹었다."),
    ("40 않/안", "밥을 먹지 안았다.", "밥을 먹지 않았다."),
    ("51 -이", "깨끗히 씻었다.", "깨끗이 씻었다."),
    ("51 -이", "일일히 확인했다.", "일일이 확인했다."),
    ("51 -히", "솔직이 말해라.", "솔직히 말해라."),
    ("51 -히", "꼼꼼이 살폈다.", "꼼꼼히 살폈다."),
    ("53 -ㄹ게", "내가 갈께.", "내가 갈게."),
    ("53 -ㄹ걸", "그럴껄 그랬다.", "그럴걸 그랬다."),
    ("53 -ㄹ지", "올찌 모르겠다.", "올지 모르겠다."),
    ("53 -ㄹ수록", "볼쑤록 좋다.", "볼수록 좋다."),
    ("54 -꾼", "그는 일군이다.", "그는 일꾼이다."),
    ("54 -깔", "빛갈이 곱다.", "빛깔이 곱다."),
    ("54 -빼기", "곱배기로 주세요.", "곱빼기로 주세요."),
    ("54 -쩍다", "멋적게 웃었다.", "멋쩍게 웃었다."),
    ("56 -던(과거)", "얼마나 놀랐든지 몰라.", "얼마나 놀랐던지 몰라."),
    ("56 -든지(선택)", "가던지 오던지 해라.", "가든지 오든지 해라."),
    ("57 맞히다", "정답을 맞췄다.", "정답을 맞혔다."),
    ("57 맞추다(유지)", "친구와 답을 맞춰 보았다.", "친구와 답을 맞춰 보았다."),
    ("57 받치다(유지)", "우산을 받치고 간다.", "우산을 받치고 간다."),
    ("57 바치다(유지)", "목숨을 바쳤다.", "목숨을 바쳤다."),
    ("57 늘리다", "수출량을 늘인다.", "수출량을 늘린다."),
    ("57 로써", "대화로서 해결했다.", "대화로써 해결했다."),
    ("57 로서(유지)", "교사로서 말한다.", "교사로서 말한다."),
    // 사이시옷·표준어
    ("30 사이시옷", "윗층에 산다.", "위층에 산다."),
    ("30 사이시옷", "갯수를 세라.", "개수를 세라."),
    ("30 사이시옷", "촛점이 맞다.", "초점이 맞다."),
    ("표준어 설거지", "설겆이를 했다.", "설거지를 했다."),
    ("표준어 오뚝이", "오뚜기처럼 일어났다.", "오뚝이처럼 일어났다."),
    ("표준어 수-", "숫소가 운다.", "수소가 운다."),
    ("표준어 -구려", "좋구료.", "좋구려."),
]

func dump(_ h: OpaquePointer, _ typos: OpaquePointer, _ text: String) -> String {
    var o = kiwi_analyze_option_t()
    o.match_options = Int32(KIWI_MATCH_ALL | KIWI_MATCH_OOV_CHR_MODEL)
    o.typo_transformer = typos; o.typo_threshold = 2.5
    guard let r = kiwi_analyze(h, text, 1, o, nil) else { return "ERR" }
    defer { kiwi_res_close(r) }
    return (0..<kiwi_res_word_num(r, 0)).map { i in
        let c = kiwi_res_typo_cost(r, 0, i)
        return "\(String(cString: kiwi_res_form(r, 0, i)))/\(String(cString: kiwi_res_tag(r, 0, i)))" + (c > 0 ? "*" : "")
    }.joined(separator: " ")
}

@main struct RulesProbe {
    static func main() async throws {
        let path = CommandLine.arguments[1]
        let engine = KiwiProofreadingEngine(modelURL: { URL(fileURLWithPath: path, isDirectory: true) })
        let h = kiwi_init(path, 1, Int32(KIWI_BUILD_LOAD_DEFAULT_DICT | KIWI_BUILD_LOAD_MULTI_DICT), 0)!
        let typos = kiwi_typo_prepare(kiwi_typo_get_default(Int32(KIWI_TYPO_BASIC_TYPO_SET)))!
        var pass = 0
        for (rule, input, expected) in cases {
            let out = try await engine.check(input)
            let mark = out == expected ? "PASS" : (out == input ? "MISS" : "WRONG")
            if mark == "PASS" { pass += 1 }
            print("[\(mark)] \(rule) | \(input) → \(out)" + (mark == "PASS" ? "" : "  (기대: \(expected))"))
            if mark != "PASS" {
                let s = kiwi_space(h, input, 1).map { p -> String in defer { kiwi_free_string(p) }; return String(cString: p) } ?? "ERR"
                print("        tokens: \(dump(h, typos, input))")
                print("        raw kiwi_space: \(s)")
            }
        }
        print("\n\(pass)/\(cases.count) PASS  (MISS=변경 없음, WRONG=다르게 변경)")
    }
}
