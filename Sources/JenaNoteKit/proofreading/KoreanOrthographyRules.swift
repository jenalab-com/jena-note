import Foundation

/// Narrow spelling rules, not a context-aware grammar checker. Suggestions still require approval.
enum KoreanOrthographyRules {
    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
        init(_ pattern: String, _ replacement: String) {
            self.regex = try! NSRegularExpression(pattern: pattern)
            self.replacement = replacement
        }
    }
    // Bound noun replacements to a complete word or an explicit Korean particle/ending.
    private static let start = #"(?<![\p{L}\p{N}_])"#
    private static let end = #"(?![\p{L}\p{N}_])"#
    private static let particles = #"(에(?:는|도|서)?|은|는|이|가|을|를|의|도|만|부터|까지|이나|이면|이다|이야|입니다)?"#
    /// Every Hangul syllable whose final consonant is ㄹ, except `껄` itself (`껄껄 웃다`).
    private static let rieulFinalSyllables = String(String.UnicodeScalarView((0..<399).compactMap { Unicode.Scalar(0xAC00 + $0 * 28 + 8) })).replacingOccurrences(of: "껄", with: "")
    private static let rules = [
        Rule(start + "오랫만" + particles + end, "오랜만$1"),
        Rule(start + "몇 ?일" + particles + end, "며칠$1"),
        Rule(start + "않 ?되요" + end, "안 돼요"),
        Rule(start + "되요" + end, "돼요"),
        Rule(start + "안되요" + end, "안 돼요"),
        // `됬` is never a standard syllable: 되었 contracts to 됐 (제35항 붙임 2).
        Rule("됬", "됐"),
        // 제53항: the ending `-ㄹ걸` is written with a plain ㄱ (`그럴껄` → `그럴걸`).
        Rule("([" + rieulFinalSyllables + "])껄(요)?" + end, "$1걸$2"),
        Rule(start + "눈꼽" + particles + end, "눈곱$1"),
        Rule(start + "머릿말" + particles + end, "머리말$1"),
        Rule(start + "웬지" + end, "왠지"),
        Rule(start + "할께요" + end, "할게요")
    ]

    static func correct(_ text: String, excluding protected: [NSRange] = []) -> String {
        // Gather against the original string so protected ranges remain valid after replacement.
        var edits: [(NSRange, String)] = []
        for rule in rules {
            for match in rule.regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      !edits.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
                edits.append((match.range, rule.regex.replacementString(for: match, in: text, offset: 0, template: rule.replacement)))
            }
        }
        let output = NSMutableString(string: text)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            output.replaceCharacters(in: range, with: replacement)
        }
        return output as String
    }
}
