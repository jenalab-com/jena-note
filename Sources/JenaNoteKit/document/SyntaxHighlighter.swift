import AppKit

// MARK: - Syntax Highlighter (JavaScript / General)
// VS Code Dark+ 테마 기반 색상

enum SyntaxHighlighter {

    // MARK: - Token Types

    private enum TokenType: CaseIterable {
        case comment        // // ... or /* ... */
        case string         // "..." '...' `...`
        case keyword        // const, let, if, function ...
        case literal        // true, false, null, undefined
        case number         // 42, 3.14, 0xFF
        case plain
    }

    // MARK: - Public Entry

    static func highlight(_ code: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let tokens = tokenize(code)

        for (text, type) in tokens {
            result.append(NSAttributedString(string: text, attributes: [
                .font: MemoFont.codeBlock,
                .foregroundColor: color(for: type)
            ]))
        }
        return result
    }

    // MARK: - Tokenizer

    private static func tokenize(_ code: String) -> [(String, TokenType)] {
        // 우선순위 순서로 정규식 패턴 정의
        let patterns: [(String, TokenType)] = [
            // 주석 (한 줄 / 여러 줄)
            ("//[^\n]*", .comment),
            ("/\\*[\\s\\S]*?\\*/", .comment),
            // 문자열
            ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
            ("'(?:[^'\\\\]|\\\\.)*'", .string),
            ("`(?:[^`\\\\]|\\\\.)*`", .string),
            // 숫자
            ("\\b(?:0x[0-9a-fA-F]+|\\d+\\.?\\d*(?:[eE][+-]?\\d+)?)\\b", .number),
            // 리터럴
            ("\\b(?:true|false|null|undefined|NaN|Infinity)\\b", .literal),
            // 키워드
            ("\\b(?:const|let|var|function|class|extends|if|else|for|while|do|switch|case|break|continue|return|new|this|super|import|export|from|as|default|async|await|try|catch|finally|throw|typeof|instanceof|in|of|delete|void|yield|static|get|set|type|interface|enum|namespace|abstract|implements|readonly|declare|module|require)\\b", .keyword),
        ]

        let ns = code as NSString
        let length = ns.length

        // 모든 매치 수집 후 비겹치는 토큰 목록 생성
        var tokenRanges: [(NSRange, TokenType)] = []

        for (pattern, type) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: code, range: NSRange(location: 0, length: length))
            for match in matches {
                let r = match.range
                // 이미 커버된 범위와 겹치면 스킵
                let overlaps = tokenRanges.contains { existing in
                    existing.0.location < r.location + r.length &&
                    existing.0.location + existing.0.length > r.location
                }
                if !overlaps { tokenRanges.append((r, type)) }
            }
        }

        tokenRanges.sort { $0.0.location < $1.0.location }

        // 토큰 사이 plain 텍스트 채우기
        var result: [(String, TokenType)] = []
        var cursor = 0

        for (range, type) in tokenRanges {
            if range.location > cursor {
                let plainRange = NSRange(location: cursor, length: range.location - cursor)
                result.append((ns.substring(with: plainRange), .plain))
            }
            result.append((ns.substring(with: range), type))
            cursor = range.location + range.length
        }

        if cursor < length {
            result.append((ns.substring(from: cursor), .plain))
        }

        return result
    }

    // MARK: - Colors (VS Code Dark+ style, dynamic light/dark)

    private static func color(for type: TokenType) -> NSColor {
        switch type {
        case .keyword:
            return NSColor(name: nil) { trait in
                isDark(trait)
                    ? NSColor(red: 0.337, green: 0.612, blue: 0.839, alpha: 1) // #569CD6
                    : NSColor(red: 0.0,   green: 0.0,   blue: 0.8,   alpha: 1) // #0000CC
            }
        case .string:
            return NSColor(name: nil) { trait in
                isDark(trait)
                    ? NSColor(red: 0.808, green: 0.569, blue: 0.471, alpha: 1) // #CE9178
                    : NSColor(red: 0.635, green: 0.082, blue: 0.082, alpha: 1) // #A21515
            }
        case .comment:
            return NSColor(name: nil) { trait in
                isDark(trait)
                    ? NSColor(red: 0.416, green: 0.600, blue: 0.333, alpha: 1) // #6A9955
                    : NSColor(red: 0.0,   green: 0.5,   blue: 0.0,   alpha: 1) // #008000
            }
        case .number:
            return NSColor(name: nil) { trait in
                isDark(trait)
                    ? NSColor(red: 0.710, green: 0.808, blue: 0.659, alpha: 1) // #B5CEA8
                    : NSColor(red: 0.035, green: 0.533, blue: 0.353, alpha: 1) // #098858
            }
        case .literal:
            return NSColor(name: nil) { trait in
                isDark(trait)
                    ? NSColor(red: 0.337, green: 0.612, blue: 0.839, alpha: 1) // #569CD6 (null/true/false)
                    : NSColor(red: 0.0,   green: 0.0,   blue: 0.8,   alpha: 1)
            }
        case .plain:
            return NSColor(name: nil) { trait in
                isDark(trait)
                    ? NSColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1) // #D4D4D4
                    : NSColor(red: 0.141, green: 0.161, blue: 0.180, alpha: 1) // #242930
            }
        }
    }

    private static func isDark(_ trait: NSAppearance) -> Bool {
        trait.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
