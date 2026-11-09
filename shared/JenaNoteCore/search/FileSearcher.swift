import Foundation

// MARK: - Result Types (NSOutlineView 아이템으로 쓰이므로 참조 타입)

/// 전체 검색에서 한 파일 안의 매치 한 건.
public final class FileSearchHit {
    public let lineNumber: Int          // 1-based
    public let lineText: String         // 매치가 포함된 줄 원문
    public let matchRangeInLine: NSRange
    public let ordinalInFile: Int       // 파일 내 매치 순번 (0-based) — 에디터 점프용

    public init(lineNumber: Int, lineText: String, matchRangeInLine: NSRange, ordinalInFile: Int) {
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.matchRangeInLine = matchRangeInLine
        self.ordinalInFile = ordinalInFile
    }
}

/// 한 파일의 검색 결과 묶음.
public final class FileSearchResult {
    public let fileURL: URL
    public let hits: [FileSearchHit]

    public init(fileURL: URL, hits: [FileSearchHit]) {
        self.fileURL = fileURL
        self.hits = hits
    }
}

/// 취소 토큰 — 새 검색이 시작되면 이전 검색을 무효화한다.
public final class FileSearchToken {
    private let lock = NSLock()
    private var cancelled = false

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

// MARK: - FileSearcher

/// 등록 폴더의 .md 파일 전체를 검색하는 인프라 컴포넌트. AppKit 의존 금지.
public final class FileSearcher {

    public static let maxFileSizeBytes = 2 * 1024 * 1024
    public static let maxTotalHits = 500
    public static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private let queue = DispatchQueue(label: "com.jenalab.jenanote.filesearch", qos: .userInitiated)
    private var token: FileSearchToken?

    public init() {}

    /// 메인 스레드에서 호출한다. completion도 메인 스레드에서 불린다.
    /// 새 검색이 시작되면 진행 중이던 이전 검색은 취소되고 그 completion은 불리지 않는다.
    public func search(query: String, in folders: [URL],
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

    public func cancel() {
        token?.cancel()
    }

    // MARK: - Sync Core (단위 테스트 대상)

    public static func searchSync(query: String, folders: [URL],
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
    public static func markdownFiles(in folders: [URL]) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for folder in folders {
            guard let enumerator = fm.enumerator(at: folder,
                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                // Windows does not treat a leading dot as hidden, and folders like .git hold documents too.
                if url.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                } else if url.pathExtension.lowercased() == "md" {
                    files.append(url)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 파일 내용에서 줄 단위로 매치를 수집한다. limit 도달 시 중단.
    public static func findHits(query: String, in content: String,
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

    public struct SearchSnippet: Equatable {
        public let text: String
        public let highlight: NSRange
    }

    /// 결과 행에 표시할 한 줄 스니펫을 만든다 — 앞 공백 제거, 긴 줄은 매치 주변 윈도우 + '…'.
    public static func makeSnippet(lineText: String, matchRange: NSRange,
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
public enum SearchMatchLocator {
    public static func range(ofOccurrence ordinal: Int, query: String, in text: String) -> NSRange? {
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
