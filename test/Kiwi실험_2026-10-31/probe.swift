// Kiwi engine experiments: analysis option drift, pretokenized protection, builder addWord.
// Compile alongside the production KiwiProofreadingEngine; no user documents are read.
import Foundation
import Kiwi
struct AIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum L10n { static func tr(_ key: String) -> String { key } }
extension Bundle { static var module: Bundle { .main } }

func lastError() -> String { kiwi_error().map { String(cString: $0) } ?? "?" }

func dump(_ h: OpaquePointer, _ text: String, _ opt: kiwi_analyze_option_t, pt: OpaquePointer? = nil) -> String {
    let u16 = Array(text.utf16) + [0]
    guard let r = u16.withUnsafeBufferPointer({ kiwi_analyze_w(h, $0.baseAddress, 1, opt, pt) }) else { return "ERR \(lastError())" }
    defer { kiwi_res_close(r) }
    return (0..<kiwi_res_word_num(r, 0)).map { i in
        let f = String(cString: kiwi_res_form(r, 0, i)), t = String(cString: kiwi_res_tag(r, 0, i))
        let c = kiwi_res_typo_cost(r, 0, i)
        return c > 0 ? "\(f)/\(t)(typo \(c))" : "\(f)/\(t)"
    }.joined(separator: " ") + "  [score \(kiwi_res_prob(r, 0))]"
}

func space(_ h: OpaquePointer, _ text: String, reset: Bool) -> String {
    guard let s = kiwi_space(h, text, reset ? 1 : 0) else { return "ERR \(lastError())" }
    defer { kiwi_free_string(s) }
    return String(cString: s)
}

@main struct Probe {
    static func main() async throws {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/JenaNoteKit/Resources/KiwiModel"
        let samples = [
            "그제야 리에느가 빵을 받았다.",
            "그제야리에느가빵을받았다.",
            "리에느가 빵을 받앗다.",
            "카셀리온이 검을 뽑았다.",
            "엘라드린과 미르세아는 숲으로 들어갔다.",
            "하연은 서준에게 책을 건넸다.",
            "오늘학교에갔다.",
        ]
        let flags = Int32(KIWI_BUILD_LOAD_DEFAULT_DICT | KIWI_BUILD_LOAD_MULTI_DICT)
        guard let base = kiwi_init(path, 1, flags, 0) else { fatalError(lastError()) }
        guard let typos = kiwi_typo_prepare(kiwi_typo_get_default(Int32(KIWI_TYPO_BASIC_TYPO_SET))) else { fatalError(lastError()) }

        var app = kiwi_analyze_option_t()
        app.match_options = Int32(KIWI_MATCH_ALL | KIWI_MATCH_OOV_CHR_MODEL)
        app.typo_transformer = typos
        app.typo_threshold = 2.5
        app.dialect_cost = 3
        var spaceInternal = kiwi_analyze_option_t()   // what Kiwi::space uses: Match::all only
        spaceInternal.match_options = Int32(KIWI_MATCH_ALL)

        print("== E1/E2: app analysis vs kiwi_space-internal analysis, raw kiwi_space, app final ==")
        let engine = KiwiProofreadingEngine(modelURL: { URL(fileURLWithPath: path, isDirectory: true) })
        for s in samples {
            print("• \(s)")
            print("  app     : \(dump(base, s, app))")
            print("  spaceOpt: \(dump(base, s, spaceInternal))")
            print("  space r0: \(space(base, s, reset: false))")
            print("  space r1: \(space(base, s, reset: true))")
            print("  engine  : \(try await engine.check(s))")
        }

        print("\n== E1b: dialect_cost effect (allowed_dialects=0) ==")
        var noDialect = app; noDialect.dialect_cost = 0
        for s in samples.prefix(3) {
            let a = dump(base, s, app), b = dump(base, s, noDialect)
            print("• \(s): \(a == b ? "identical" : "DIFFERENT\n  3: \(a)\n  0: \(b)")")
        }

        print("\n== E3: pretokenized 리에느/NNP (UTF-16 offsets) ==")
        for s in samples.prefix(3) {
            let ns = s as NSString
            let r = ns.range(of: "리에느")
            guard let pt = kiwi_pt_init() else { fatalError(lastError()) }
            let span = kiwi_pt_add_span(pt, Int32(r.location), Int32(NSMaxRange(r)))
            _ = kiwi_pt_add_token_to_span(pt, span, "리에느", "NNP", 0, Int32(r.length))
            print("• \(s)")
            print("  app+pt  : \(dump(base, s, app, pt: pt))")
            kiwi_pt_close(pt)
        }

        print("\n== E4: builder + add_word(NNP) for invented names ==")
        guard let b = kiwi_builder_init(path, 1, flags, 0) else { fatalError(lastError()) }
        for w in ["리에느", "카셀리온", "엘라드린", "미르세아"] {
            print("  add_word \(w): \(kiwi_builder_add_word(b, w, "NNP", 0))")
        }
        let t0 = Date()
        guard let custom = kiwi_builder_build(b, nil, 0) else { fatalError(lastError()) }
        print("  build: \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        kiwi_builder_close(b)
        for s in samples {
            print("• \(s)")
            print("  app     : \(dump(custom, s, app))")
            print("  space r1: \(space(custom, s, reset: true))")
        }

        kiwi_close(custom)
        kiwi_prepared_typo_close(typos)
        kiwi_close(base)
    }
}
