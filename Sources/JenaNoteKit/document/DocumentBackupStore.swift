import Foundation
import CryptoKit

final class DocumentBackupStore {
    struct Snapshot: Codable {
        let id: UUID
        let source: String
        let createdAt: Date
        let data: Data
        var name: String? = nil
        var parentID: UUID? = nil
    }
    static let shared = DocumentBackupStore()
    let directory: URL
    private let lock = NSRecursiveLock()
    private let limit: Int
    private var latestBySource: [String: Snapshot] = [:]
    init(directory: URL? = nil, limit: Int = 100) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JenaNote/Backups", isDirectory: true)
        self.limit = max(1, limit)
    }
    private struct Identity: Codable {
        let id: UUID
        var path: String
        var bookmark: Data?
    }
    private struct Revision: Codable {
        let id: UUID
        let createdAt: Date
        let hash: String
        let name: String?
        let parentID: UUID?
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func folder(for source: URL) throws -> URL {
        let catalog = directory.appendingPathComponent("documents.json")
        var identities = FileManager.default.fileExists(atPath: catalog.path)
            ? try JSONDecoder().decode([Identity].self, from: Data(contentsOf: catalog)) : []
        let path = source.standardizedFileURL.path
        let match = identities.firstIndex { identity in
            if identity.path == path { return true }
            guard let bookmark = identity.bookmark else { return false }
            var stale = false
            return (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale))?.standardizedFileURL.path == path
        }
        let index: Int
        if let match { index = match }
        else {
            identities.append(Identity(id: UUID(), path: path, bookmark: nil))
            index = identities.count - 1
        }
        identities[index].path = path
        if let bookmark = try? source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            identities[index].bookmark = bookmark
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(identities).write(to: catalog, options: .atomic)
        let result = directory.appendingPathComponent(identities[index].id.uuidString, isDirectory: true)
        let legacy = directory.appendingPathComponent(digest(Data(path.utf8)))
        if !FileManager.default.fileExists(atPath: result.path), FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.moveItem(at: legacy, to: result)
        }
        return result
    }
    func snapshots(for source: URL) throws -> [Snapshot] {
        lock.lock(); defer { lock.unlock() }
        let folder = try folder(for: source)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Snapshot? in
                let data = try Data(contentsOf: url)
                if let item = try? JSONDecoder().decode(Snapshot.self, from: data) {
                    guard url.lastPathComponent == item.id.uuidString + ".json" else { return nil }
                    return Snapshot(id: item.id, source: source.standardizedFileURL.path, createdAt: item.createdAt, data: item.data, name: item.name, parentID: item.parentID)
                }
                let item = try JSONDecoder().decode(Revision.self, from: data)
                guard url.lastPathComponent == item.id.uuidString + ".json",
                      item.hash.count == 64, item.hash.allSatisfy({ $0.isHexDigit }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let body = try Data(contentsOf: directory.appendingPathComponent("objects").appendingPathComponent(item.hash))
                guard digest(body) == item.hash else { throw CocoaError(.fileReadCorruptFile) }
                return Snapshot(id: item.id, source: source.standardizedFileURL.path, createdAt: item.createdAt, data: body, name: item.name, parentID: item.parentID)
            }.sorted { $0.createdAt > $1.createdAt }
    }
    func hasSnapshots(for source: URL) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if latestBySource[source.standardizedFileURL.path] != nil,
           FileManager.default.fileExists(atPath: try folder(for: source).path) { return true }
        let latest = try snapshots(for: source).first
        latestBySource[source.standardizedFileURL.path] = latest
        return latest != nil
    }
    func record(_ data: Data, for source: URL, automatic: Bool = false, name: String? = nil, force: Bool = false, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let key = source.standardizedFileURL.path
        if !FileManager.default.fileExists(atPath: try folder(for: source).path) { latestBySource[key] = nil }
        let latest = try latestBySource[key] ?? snapshots(for: source).first
        if let latest, name == nil, !force {
            if latest.data == data { return }
            if automatic && now.timeIntervalSince(latest.createdAt) < 300 { return }
        }
        let previous = try snapshots(for: source)
        let folder = try folder(for: source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = Snapshot(id: UUID(), source: source.standardizedFileURL.path, createdAt: now, data: data, name: name, parentID: latest?.id)
        let hash = digest(data)
        let objects = directory.appendingPathComponent("objects", isDirectory: true)
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        let object = objects.appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: object.path) {
            try data.write(to: object, options: .atomic)
        } else if try Data(contentsOf: object) != data { throw CocoaError(.fileReadCorruptFile) }
        let revision = Revision(id: entry.id, createdAt: now, hash: hash, name: name, parentID: latest?.id)
        try JSONEncoder().encode(revision).write(to: folder.appendingPathComponent(entry.id.uuidString + ".json"), options: .atomic)
        latestBySource[key] = entry
        // Only prune after the new snapshot is safely on disk.
        for item in previous.filter({ $0.name == nil }).dropFirst(name == nil ? limit - 1 : limit) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(item.id.uuidString + ".json"))
        }
    }
}
