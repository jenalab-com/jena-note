import Foundation

public final class DocumentBackupStore {
    public struct Snapshot: Codable {
        public let id: UUID
        public let source: String
        public let createdAt: Date
        public let data: Data
        public var name: String? = nil
        public var parentID: UUID? = nil

        public init(id: UUID, source: String, createdAt: Date, data: Data, name: String? = nil, parentID: UUID? = nil) {
            self.id = id
            self.source = source
            self.createdAt = createdAt
            self.data = data
            self.name = name
            self.parentID = parentID
        }
    }
    public static let shared = DocumentBackupStore()
    public let directory: URL
    private let lock = NSRecursiveLock()
    private let limit: Int
    private var latestBySource: [String: Snapshot] = [:]
    public init(directory: URL? = nil, limit: Int = 100) {
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
        ContentDigest.sha256(data)
    }
    private func folder(for source: URL) throws -> URL {
        let catalog = directory.appendingPathComponent("documents.json")
        var identities = FileManager.default.fileExists(atPath: catalog.path)
            ? try JSONDecoder().decode([Identity].self, from: Data(contentsOf: catalog)) : []
        let path = source.standardizedFileURL.path
        let match = identities.firstIndex { identity in
            if identity.path == path { return true }
            #if canImport(Darwin)
            guard let bookmark = identity.bookmark else { return false }
            var stale = false
            return (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale))?.standardizedFileURL.path == path
            #else
            return false
            #endif
        }
        let index: Int
        if let match { index = match }
        else {
            identities.append(Identity(id: UUID(), path: path, bookmark: nil))
            index = identities.count - 1
        }
        identities[index].path = path
        #if canImport(Darwin)
        if let bookmark = try? source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            identities[index].bookmark = bookmark
        }
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(identities).write(to: catalog, options: .atomic)
        let result = directory.appendingPathComponent(identities[index].id.uuidString, isDirectory: true)
        let legacy = directory.appendingPathComponent(digest(Data(path.utf8)))
        if !FileManager.default.fileExists(atPath: result.path), FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.moveItem(at: legacy, to: result)
        }
        return result
    }
    /// For platforms without bookmarks: history stays with documents that moved inside the app.
    /// `source` may be a file or a folder.
    public func documentsMoved(from source: URL, to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let catalog = directory.appendingPathComponent("documents.json")
        guard FileManager.default.fileExists(atPath: catalog.path) else { return }
        var identities = try JSONDecoder().decode([Identity].self, from: Data(contentsOf: catalog))
        let from = source.standardizedFileURL.path
        let to = destination.standardizedFileURL.path
        for index in identities.indices {
            let path = identities[index].path
            if path == from {
                identities[index].path = to
            } else if path.hasPrefix(from + "/") {
                identities[index].path = to + path.dropFirst(from.count)
            }
        }
        latestBySource = latestBySource.filter { $0.key != from && !$0.key.hasPrefix(from + "/") }
        try JSONEncoder().encode(identities).write(to: catalog, options: .atomic)
    }
    public func snapshots(for source: URL) throws -> [Snapshot] {
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
    public func hasSnapshots(for source: URL) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if latestBySource[source.standardizedFileURL.path] != nil,
           FileManager.default.fileExists(atPath: try folder(for: source).path) { return true }
        let latest = try snapshots(for: source).first
        latestBySource[source.standardizedFileURL.path] = latest
        return latest != nil
    }
    public func record(_ data: Data, for source: URL, automatic: Bool = false, name: String? = nil, force: Bool = false, now: Date = Date()) throws {
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
