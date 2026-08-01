import Foundation

/// 문서별 "마지막으로 읽던 위치"를 영속 보관한다 (ADR-0008).
///
/// 키는 파일 경로 — 비-샌드박스 배포 가정(ADR-0005)에 따라 `FolderBookmarksStore` 와
/// 같은 관례를 쓴다. MAS 전환 시 security-scoped bookmark 로 함께 마이그레이션한다.
final class ReadingProgressStore {

    static let shared = ReadingProgressStore()

    /// 보관 상한. 넘으면 오래 안 본 문서부터 버린다 (UserDefaults 비대화 방지).
    static let maxEntries = 300

    private let defaultsKey = "com.jenalab.jenanote.reading.progress"
    private let defaults: UserDefaults

    private var anchors: [String: ReadingAnchor] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Public API

    func anchor(for url: URL) -> ReadingAnchor? {
        anchors[key(for: url)]
    }

    func setAnchor(_ anchor: ReadingAnchor, for url: URL) {
        anchors[key(for: url)] = anchor
        prune()
        save()
    }

    func clearAnchor(for url: URL) {
        anchors.removeValue(forKey: key(for: url))
        save()
    }

    /// 저장된 위치가 문서 맨 앞이면 복원할 게 없다 — 굳이 앵커를 남기지 않는다.
    func setAnchorOrClear(_ anchor: ReadingAnchor, for url: URL) {
        if anchor.characterOffset <= 0 {
            clearAnchor(for: url)
        } else {
            setAnchor(anchor, for: url)
        }
    }

    // MARK: - Persistence

    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func prune() {
        guard anchors.count > Self.maxEntries else { return }
        let sorted = anchors.sorted { $0.value.updatedAt > $1.value.updatedAt }
        anchors = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxEntries).map { ($0.key, $0.value) })
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ReadingAnchor].self, from: data) else { return }
        anchors = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(anchors) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
