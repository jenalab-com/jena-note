// Can Kiwi itself flag non-standard forms if we block them and add typo rules?
import Foundation
import Kiwi

func analyze(_ h: OpaquePointer, _ text: String, typos: OpaquePointer, block: OpaquePointer?) -> String {
    var o = kiwi_analyze_option_t()
    o.match_options = Int32(KIWI_MATCH_ALL | KIWI_MATCH_OOV_CHR_MODEL)
    o.typo_transformer = typos; o.typo_threshold = 2.5; o.blocklist = block
    guard let r = kiwi_analyze(h, text, 1, o, nil) else { return "ERR \(String(cString: kiwi_error()))" }
    defer { kiwi_res_close(r) }
    let n = kiwi_res_word_num(r, 0)
    let toks = (0..<n).map { i in "\(String(cString: kiwi_res_form(r, 0, i)))/\(String(cString: kiwi_res_tag(r, 0, i)))" + (kiwi_res_typo_cost(r, 0, i) > 0 ? "*" : "") }
    let j = kiwi_new_joiner(h, 0)!; defer { kiwi_joiner_close(j) }
    for i in 0..<n where String(cString: kiwi_res_tag(r, 0, i)) != "SF" { _ = kiwi_joiner_add(j, kiwi_res_form(r, 0, i), kiwi_res_tag(r, 0, i), 0) }
    return toks.joined(separator: " ") + "  ⇒ " + String(cString: kiwi_joiner_get(j))
}

@main struct BlockProbe {
    static func main() {
        let path = CommandLine.arguments[1]
        let h = kiwi_init(path, 1, Int32(KIWI_BUILD_LOAD_DEFAULT_DICT | KIWI_BUILD_LOAD_MULTI_DICT), 0)!
        let custom = kiwi_typo_copy(kiwi_typo_get_default(Int32(KIWI_TYPO_BASIC_TYPO_SET)))!
        func add(_ orig: String, _ err: String, _ cost: Float) {
            var o = [strdup(orig)], e = [strdup(err)]
            let rc = o.withUnsafeMutableBufferPointer { op in e.withUnsafeMutableBufferPointer { ep in
                op.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: 1) { opp in
                    ep.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: 1) { epp in
                        kiwi_typo_add(custom, opp, 1, epp, 1, cost, 0) } } } }
            print("typo_add \(orig)←\(err): \(rc)")
        }
        add("게", "께", 1.5); add("지", "찌", 1.5); add("수", "쑤", 1.5); add("걸", "껄", 1.5)
        add("이", "히", 1.5); add("히", "이", 1.5)
        let base = kiwi_typo_prepare(kiwi_typo_get_default(Int32(KIWI_TYPO_BASIC_TYPO_SET)))!
        let prepared = kiwi_typo_prepare(custom)!
        let block = kiwi_new_morphset(h)!
        for (f, t) in [("ᆯ께", "EF"), ("ᆯ께", "EC"), ("깨끗히", "MAG"), ("솔직이", "MAG"), ("꼼꼼", "MAG")] {
            print("block \(f)/\(t): \(kiwi_morphset_add(block, f, t))")
        }
        let samples = ["내가 갈께.", "그럴껄 그랬다.", "올찌 모르겠다.", "볼쑤록 좋다.", "깨끗히 씻었다.", "솔직이 말해라.", "꼼꼼이 살폈다.",
                       // over-correction guards: these must stay unchanged
                       "선생님께 드렸다.", "같이 가자.", "깨끗이 씻었다.", "조용히 해라.", "높이 날았다.", "급히 갔다.", "이따가 갈게.", "그럴걸 그랬다."]
        for s in samples {
            print("• \(s)")
            print("  base           : \(analyze(h, s, typos: base, block: nil))")
            print("  custom+block   : \(analyze(h, s, typos: prepared, block: block))")
        }
    }
}
