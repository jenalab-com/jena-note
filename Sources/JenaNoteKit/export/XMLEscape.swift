import Foundation

// MARK: - XML escape (docx/hwpx 공용)

enum XMLEscape {
    /// XML 텍스트 노드/속성 값에 안전하도록 특수문자를 이스케이프한다.
    static func text(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}
