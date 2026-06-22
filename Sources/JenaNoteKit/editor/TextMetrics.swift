import Foundation

/// 문서 글자수 계산 — 순수 함수 모음. 화면(상태바)과 분리되어 단위 테스트가 가능하다.
/// (조판 계산을 분리한 `ReaderMetrics` 와 같은 패턴.)
enum TextMetrics {

    /// 이미지 첨부 등 텍스트 첨부가 차지하는 자리 표시 문자(object replacement character).
    private static let objectReplacement: Character = "\u{FFFC}"

    /// 글자 수를 두 가지로 센다.
    /// - noSpaces: 공백·탭·개행·이미지 첨부를 **제외**한 순수 글자 수.
    /// - withSpaces: 공백·탭은 **포함**하되 개행·이미지 첨부는 제외한 글자 수.
    ///
    /// 글자 단위는 `Character`(grapheme cluster) — 결합 이모지·한글 자모 결합도 한 글자로 센다.
    static func counts(for text: String) -> (noSpaces: Int, withSpaces: Int) {
        var noSpaces = 0
        var withSpaces = 0
        for ch in text {
            // 개행과 이미지 첨부는 양쪽 모두에서 빠진다.
            if ch.isNewline || ch == objectReplacement { continue }
            withSpaces += 1
            // 공백·탭 등 화이트스페이스는 noSpaces 에서만 빠진다.
            if ch.isWhitespace { continue }
            noSpaces += 1
        }
        return (noSpaces, withSpaces)
    }

    /// 천 단위 콤마 포맷 — 로케일에 맞춰 구분 기호를 적용한다.
    static func formatted(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}
