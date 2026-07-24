import Foundation

/// 읽던 위치를 가리키는 표시-독립 좌표 (ADR-0008).
///
/// 페이지 번호나 스크롤 y 는 폰트 배율·패밀리·행간·컬럼 폭·페이지 모드·창 크기가
/// 바뀌는 순간 의미를 잃는다. 반면 문자 오프셋은 이 모두와 무관하다 —
/// `ReaderMetrics.styled` 는 속성만 바꾸고 문자를 넣거나 빼지 않으므로
/// 원본 content 와 표시본의 문자 인덱스가 1:1 로 보존되기 때문이다.
/// (이미지 첨부도 U+FFFC 한 글자라 셈이 어긋나지 않는다.)
///
/// 오프셋만으로는 문서가 편집되면 밀리므로, 재동기화용 문맥 스니펫을 함께 들고 다닌다.
struct ReadingAnchor: Codable, Equatable {

    /// 문서 시작부터의 문자 오프셋 (NSString 기준 = UTF-16).
    var characterOffset: Int

    /// 오프셋 지점부터의 원문 조각. 편집으로 오프셋이 밀렸을 때 위치를 되찾는 데 쓴다.
    var contextSnippet: String

    /// 앵커를 찍을 당시 문서 전체 길이. 변경 여부 빠른 판별용.
    var contentLength: Int

    var updatedAt: Date

    // MARK: - Tuning

    /// 스니펫 길이. 짧으면 중복 매치가 늘고, 길면 작은 편집에도 매치가 깨진다.
    static let snippetLength = 32

    /// 1차 재탐색 반경. 이 안에서 찾으면 문서 앞부분이 조금 늘거나 준 정도로 본다.
    static let searchRadius = 2048

    // MARK: - Creation

    /// `text` 의 `offset` 지점을 가리키는 앵커를 만든다. 오프셋은 길이 안으로 클램프된다.
    static func make(offset: Int, in text: String) -> ReadingAnchor {
        let ns = text as NSString
        let clamped = min(max(0, offset), ns.length)
        let snippetLen = min(snippetLength, ns.length - clamped)
        let snippet = ns.substring(with: NSRange(location: clamped, length: snippetLen))
        return ReadingAnchor(characterOffset: clamped,
                             contextSnippet: snippet,
                             contentLength: ns.length,
                             updatedAt: Date())
    }

    // MARK: - Resolution

    /// 현재 문서에서 이 앵커가 가리키는 실제 오프셋을 찾는다.
    ///
    /// 3단계 폴백:
    /// 1. 저장된 오프셋에 스니펫이 그대로 있으면 그 자리 (편집 없음 — 대부분의 경우)
    /// 2. 오프셋 ±`searchRadius` 안에서 스니펫 재탐색 (앞쪽이 조금 바뀜)
    /// 3. 문서 전체에서 재탐색, 그래도 없으면 오프셋을 길이 안으로 클램프
    ///
    /// 2·3단계에서 매치가 여럿이면 원래 오프셋에 가장 가까운 것을 고른다.
    func resolve(in text: String) -> Int {
        let ns = text as NSString
        guard ns.length > 0 else { return 0 }

        let snippet = contextSnippet as NSString
        // 스니펫이 없는 앵커(문서 끝에서 찍힘)는 재탐색할 단서가 없다.
        guard snippet.length > 0 else { return min(characterOffset, ns.length) }

        // 1) 제자리 확인 — 길이가 같아도 치환 편집이 있을 수 있으므로 내용까지 본다.
        if characterOffset >= 0, characterOffset + snippet.length <= ns.length {
            let here = NSRange(location: characterOffset, length: snippet.length)
            if ns.substring(with: here) == contextSnippet { return characterOffset }
        }

        // 2) 근처 재탐색
        let lower = max(0, characterOffset - ReadingAnchor.searchRadius)
        let upper = min(ns.length, characterOffset + ReadingAnchor.searchRadius + snippet.length)
        if upper > lower,
           let near = ReadingAnchor.nearestOccurrence(
                of: contextSnippet, in: ns,
                near: characterOffset,
                within: NSRange(location: lower, length: upper - lower)) {
            return near
        }

        // 3) 전체 재탐색
        if let far = ReadingAnchor.nearestOccurrence(
                of: contextSnippet, in: ns,
                near: characterOffset,
                within: NSRange(location: 0, length: ns.length)) {
            return far
        }

        return min(max(0, characterOffset), ns.length)
    }

    // MARK: - Preview

    /// 책갈피 목록에 보여줄 한 줄 미리보기.
    /// 저장해 두지 않고 매번 현재 본문에서 뜬다 — 문서가 편집돼도 실제로 보이는 문장과 어긋나지 않는다.
    static func previewText(at offset: Int, in text: String, maxLength: Int = 60) -> String {
        let ns = text as NSString
        guard ns.length > 0 else { return "" }
        let start = min(max(0, offset), ns.length)

        // 줄바꿈·연속 공백을 한 칸으로 눌러 한 줄로 만든다.
        let raw = ns.substring(with: NSRange(location: start, length: min(maxLength * 2, ns.length - start)))
        let flattened = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !flattened.isEmpty else { return "" }

        let flat = flattened as NSString
        if flat.length <= maxLength { return flattened }
        return flat.substring(to: maxLength) + "…"
    }

    /// `range` 안에서 `needle` 이 나오는 위치 중 `target` 에 가장 가까운 것.
    /// 앞뒤로 한 번씩만 훑으므로 매치가 아무리 많아도 탐색은 두 번이다.
    private static func nearestOccurrence(of needle: String,
                                          in haystack: NSString,
                                          near target: Int,
                                          within range: NSRange) -> Int? {
        guard !needle.isEmpty, range.length > 0 else { return nil }
        let needleLen = (needle as NSString).length

        // target 이하에서 가장 뒤쪽 매치
        var backward: Int?
        let backEnd = min(NSMaxRange(range), min(target, haystack.length - needleLen) + needleLen)
        if backEnd > range.location {
            let backRange = NSRange(location: range.location, length: backEnd - range.location)
            let r = haystack.range(of: needle, options: [.backwards, .literal], range: backRange)
            if r.location != NSNotFound { backward = r.location }
        }

        // target 이후에서 가장 앞쪽 매치
        var forward: Int?
        let fwdStart = max(range.location, min(target, NSMaxRange(range)))
        if NSMaxRange(range) > fwdStart {
            let fwdRange = NSRange(location: fwdStart, length: NSMaxRange(range) - fwdStart)
            let r = haystack.range(of: needle, options: [.literal], range: fwdRange)
            if r.location != NSNotFound { forward = r.location }
        }

        switch (backward, forward) {
        case (nil, nil):        return nil
        case let (b?, nil):     return b
        case let (nil, f?):     return f
        case let (b?, f?):      return abs(b - target) <= abs(f - target) ? b : f
        }
    }
}
