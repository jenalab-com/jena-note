import Foundation

/// 문서별 책갈피 목록을 영속 보관한다 (ADR-0008).
///
/// 이어읽기(`ReadingProgressStore`)와 같은 `ReadingAnchor` 를 쓰되, 문서당 1개가 아니라
/// N개를 문서 순서(오프셋 오름차순)로 들고 있다는 점만 다르다.
/// 표시용 스니펫은 저장하지 않는다 — 목록을 그릴 때 현재 본문에서 직접 떠야
/// 문서가 편집된 뒤에도 실제로 보이는 문장과 어긋나지 않는다.
final class BookmarkStore {

    static let shared = BookmarkStore()

    /// 문서당 상한. 넘으면 가장 오래된 것부터 버린다.
    static let maxPerDocument = 100

    private let defaultsKey = "com.jenalab.jenanote.reading.bookmarks"
    private let defaults: UserDefaults

    private var bookmarks: [String: [ReadingAnchor]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Public API

    /// 문서의 책갈피 — 항상 문서 순서(오프셋 오름차순).
    func bookmarks(for url: URL) -> [ReadingAnchor] {
        bookmarks[key(for: url)] ?? []
    }

    /// 책갈피를 추가한다. 같은 오프셋이 이미 있으면 아무것도 하지 않는다.
    func add(_ anchor: ReadingAnchor, for url: URL) {
        let k = key(for: url)
        var list = bookmarks[k] ?? []
        guard !list.contains(where: { $0.characterOffset == anchor.characterOffset }) else { return }
        list.append(anchor)
        list.sort { $0.characterOffset < $1.characterOffset }
        if list.count > Self.maxPerDocument {
            // 오래된 것부터 버리되, 남는 것은 다시 문서 순서로.
            list = list.sorted { $0.updatedAt > $1.updatedAt }
                       .prefix(Self.maxPerDocument)
                       .sorted { $0.characterOffset < $1.characterOffset }
        }
        bookmarks[k] = list
        save()
    }

    /// 주어진 범위 안에 있는 책갈피를 모두 지운다. 지운 게 있으면 true.
    /// "지금 보이는 화면에 이미 책갈피가 있으면 해제"라는 토글 동작에 쓴다.
    @discardableResult
    func removeBookmarks(in range: NSRange, for url: URL) -> Bool {
        let k = key(for: url)
        guard var list = bookmarks[k] else { return false }
        let before = list.count
        list.removeAll { NSLocationInRange($0.characterOffset, range) }
        guard list.count != before else { return false }
        bookmarks[k] = list.isEmpty ? nil : list
        save()
        return true
    }

    func removeBookmark(atOffset offset: Int, for url: URL) {
        let k = key(for: url)
        guard var list = bookmarks[k] else { return }
        list.removeAll { $0.characterOffset == offset }
        bookmarks[k] = list.isEmpty ? nil : list
        save()
    }

    func removeAll(for url: URL) {
        bookmarks.removeValue(forKey: key(for: url))
        save()
    }

    // MARK: - Persistence

    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [ReadingAnchor]].self, from: data) else { return }
        bookmarks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
