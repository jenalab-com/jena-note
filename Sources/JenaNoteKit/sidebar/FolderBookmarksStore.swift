import Foundation

/// 사이드바에 등록된 폴더 URL 목록을 UserDefaults에 영속 보관한다.
///
/// 비-샌드박스 배포 가정 (ADR-0005). MAS 배포 전환 시 security-scoped bookmark로 마이그레이션 필요.
/// 변경 시 `.folderBookmarksDidChange` 알림을 발행한다.
final class FolderBookmarksStore {

    static let shared = FolderBookmarksStore()

    private let defaultsKey = "com.jenalab.jenanote.sidebar.bookmarks"

    private(set) var folders: [URL] = []

    private init() {
        load()
    }

    // MARK: - Public API

    func addFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        if folders.contains(where: { $0.standardizedFileURL == standardized }) { return }
        folders.append(standardized)
        save()
        notifyChange()
    }

    func removeFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        folders.removeAll { $0.standardizedFileURL == standardized }
        save()
        notifyChange()
    }

    /// 디스크 접근 가능 여부 — 외부 볼륨 분리/삭제 감지
    func isAccessible(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // MARK: - Persistence

    private func load() {
        guard let paths = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else { return }
        folders = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func save() {
        let paths = folders.map { $0.path }
        UserDefaults.standard.set(paths, forKey: defaultsKey)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .folderBookmarksDidChange, object: self)
    }
}

extension Notification.Name {
    /// 등록된 폴더 목록이 추가/제거되었을 때 발행됨
    static let folderBookmarksDidChange = Notification.Name("FolderBookmarksDidChange")

    /// 감시 중인 폴더의 디스크 내용이 변경되었을 때 발행됨 (object: 변경된 루트 URL 또는 nil)
    static let folderContentsDidChange = Notification.Name("FolderContentsDidChange")
}
