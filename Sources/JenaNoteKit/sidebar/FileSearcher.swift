import Foundation

// MARK: - Result Types (NSOutlineView 아이템으로 쓰이므로 참조 타입)

/// 전체 검색에서 한 파일 안의 매치 한 건.
final class FileSearchHit {
    let lineNumber: Int          // 1-based
    let lineText: String         // 매치가 포함된 줄 원문
    let matchRangeInLine: NSRange
    let ordinalInFile: Int       // 파일 내 매치 순번 (0-based) — 에디터 점프용

    init(lineNumber: Int, lineText: String, matchRangeInLine: NSRange, ordinalInFile: Int) {
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.matchRangeInLine = matchRangeInLine
        self.ordinalInFile = ordinalInFile
    }
}

/// 한 파일의 검색 결과 묶음.
final class FileSearchResult {
    let fileURL: URL
    let hits: [FileSearchHit]

    init(fileURL: URL, hits: [FileSearchHit]) {
        self.fileURL = fileURL
        self.hits = hits
    }
}

/// 취소 토큰 — 새 검색이 시작되면 이전 검색을 무효화한다.
final class FileSearchToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

// MARK: - FileSearcher

/// 등록 폴더의 .md 파일 전체를 검색하는 인프라 컴포넌트. AppKit 의존 금지.
final class FileSearcher {

    static let maxFileSizeBytes = 2 * 1024 * 1024
    static let maxTotalHits = 500
    static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private let queue = DispatchQueue(label: "com.jenalab.jenanote.filesearch", qos: .userInitiated)
    private var token: FileSearchToken?

    /// 메인 스레드에서 호출한다. completion도 메인 스레드에서 불린다.
    /// 새 검색이 시작되면 진행 중이던 이전 검색은 취소되고 그 completion은 불리지 않는다.
    func search(query: String, in folders: [URL],
                completion: @escaping (_ results: [FileSearchResult], _ truncated: Bool) -> Void) {
        token?.cancel()
        let newToken = FileSearchToken()
        token = newToken
        queue.async {
            let (results, truncated) = FileSearcher.searchSync(query: query, folders: folders, token: newToken)
            DispatchQueue.main.async {
                guard !newToken.isCancelled else { return }
                completion(results, truncated)
            }
        }
    }

    func cancel() {
        token?.cancel()
    }

    // MARK: - Sync Core (단위 테스트 대상)

    static func searchSync(query: String, folders: [URL],
                           token: FileSearchToken? = nil) -> ([FileSearchResult], Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], false) }

        var results: [FileSearchResult] = []
        var totalHits = 0
        var truncated = false

        for fileURL in markdownFiles(in: folders) {
            if token?.isCancelled == true { return ([], false) }
            if totalHits >= maxTotalHits { truncated = true; break }

            guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= maxFileSizeBytes,
                  let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let (hits, reachedLimit) = findHits(query: trimmed, in: content,
                                                limit: maxTotalHits - totalHits)
            if reachedLimit { truncated = true }
            if !hits.isEmpty {
                results.append(FileSearchResult(fileURL: fileURL, hits: hits))
                totalHits += hits.count
            }
        }
        return (results, truncated)
    }

    /// 폴더들을 재귀 순회해 .md 파일 URL을 경로순으로 반환한다 (결과 순서 결정성).
    static func markdownFiles(in folders: [URL]) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for folder in folders {
            guard let enumerator = fm.enumerator(at: folder,
                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 파일 내용에서 줄 단위로 매치를 수집한다. limit 도달 시 중단.
    static func findHits(query: String, in content: String,
                         limit: Int) -> (hits: [FileSearchHit], reachedLimit: Bool) {
        var hits: [FileSearchHit] = []
        var ordinal = 0
        let lines = content.components(separatedBy: "\n")

        outer: for (index, line) in lines.enumerated() {
            var searchStart = line.startIndex
            while searchStart < line.endIndex,
                  let r = line.range(of: query, options: searchOptions,
                                     range: searchStart..<line.endIndex) {
                if hits.count >= limit { return (hits, true) }
                hits.append(FileSearchHit(lineNumber: index + 1,
                                          lineText: line,
                                          matchRangeInLine: NSRange(r, in: line),
                                          ordinalInFile: ordinal))
                ordinal += 1
                searchStart = r.upperBound
                if searchStart >= line.endIndex { continue outer }
            }
        }
        return (hits, false)
    }

    // MARK: - Snippet

    struct SearchSnippet: Equatable {
        let text: String
        let highlight: NSRange
    }

    /// 결과 행에 표시할 한 줄 스니펫을 만든다 — 앞 공백 제거, 긴 줄은 매치 주변 윈도우 + '…'.
    static func makeSnippet(lineText: String, matchRange: NSRange,
                            maxLength: Int = 80) -> SearchSnippet {
        let ns = lineText as NSString

        // 앞쪽 공백 제거 (매치 시작은 침범하지 않음)
        var start = 0
        while start < matchRange.location, start < ns.length,
              let scalar = Unicode.Scalar(ns.character(at: start)),
              CharacterSet.whitespaces.contains(scalar) {
            start += 1
        }

        // 매치가 뒤쪽에 있으면 매치 앞 문맥 일부만 남기고 자른다
        var snippetStart = start
        if matchRange.location + matchRange.length - snippetStart > maxLength {
            snippetStart = max(start, matchRange.location - maxLength / 4)
        }
        let snippetEnd = min(ns.length, snippetStart + maxLength)
        var text = ns.substring(with: NSRange(location: snippetStart,
                                              length: max(0, snippetEnd - snippetStart)))
        var highlightLocation = matchRange.location - snippetStart
        if snippetStart > start {
            text = "…" + text
            highlightLocation += 1
        }
        if snippetEnd < ns.length {
            text += "…"
        }
        let textLength = (text as NSString).length
        let safeLocation = max(0, min(highlightLocation, textLength))
        let safeLength = max(0, min(matchRange.length, textLength - safeLocation))
        return SearchSnippet(text: text,
                             highlight: NSRange(location: safeLocation, length: safeLength))
    }
}

// MARK: - SearchMatchLocator

/// 에디터에 로드된 텍스트에서 검색어의 n번째 occurrence 위치를 찾는다 (점프용 순번 매칭).
enum SearchMatchLocator {
    static func range(ofOccurrence ordinal: Int, query: String, in text: String) -> NSRange? {
        guard !query.isEmpty, ordinal >= 0 else { return nil }
        var count = 0
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let r = text.range(of: query, options: FileSearcher.searchOptions,
                                 range: searchStart..<text.endIndex) {
            if count == ordinal { return NSRange(r, in: text) }
            count += 1
            searchStart = r.upperBound
        }
        return nil
    }
}
