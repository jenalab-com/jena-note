import Foundation

public struct DictionaryWorkContext: Equatable {
    public let root: URL
    public let title: String

    public init(root: URL, title: String) {
        self.root = root
        self.title = title
    }
}

/// Main-thread owned personal exceptions; does not modify a work's context.json or Kiwi model.
public final class PersonalDictionaryStore {
    public struct Work: Codable, Equatable {
        public let id: UUID
        public var title: String
        public var path: String
        public var bookmark: Data?

        public init(id: UUID, title: String, path: String, bookmark: Data?) {
            self.id = id
            self.title = title
            self.path = path
            self.bookmark = bookmark
        }

        public func matches(_ root: URL) -> Bool {
            let path = root.standardizedFileURL.resolvingSymlinksInPath().path
            // Windows Foundation has no URL bookmarks, so a moved work folder is a new work there.
            #if canImport(Darwin)
            if let bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
                    return resolved.standardizedFileURL.resolvingSymlinksInPath().path == path
                }
                return false
            }
            #endif
            // Stored paths are as given; compare them in the same resolved form as the root.
            return URL(fileURLWithPath: self.path).standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }
    public struct Entry: Codable, Equatable, Identifiable {
        public let id: UUID
        public var term: String
        /// nil = all works, including documents outside a work; nonempty = explicit work IDs.
        public var workIDs: [UUID]?
        public var enabled: Bool

        public init(id: UUID, term: String, workIDs: [UUID]?, enabled: Bool) {
            self.id = id
            self.term = term
            self.workIDs = workIDs
            self.enabled = enabled
        }
    }
    private struct State: Codable {
        var version = 1
        var entries: [Entry] = []
        var works: [Work] = []
    }
    public static let shared = PersonalDictionaryStore()
    public static let changed = Notification.Name("JenaNotePersonalDictionaryChanged")
    private let fileURL: URL
    private var state = State()
    private(set) var loadError: Error?
    public var entries: [Entry] { state.entries }
    public var works: [Work] { state.works }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JenaNote/PersonalDictionary/dictionary.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: self.fileURL))
                guard decoded.version == 1,
                      Set(decoded.works.map(\.id)).count == decoded.works.count,
                      Set(decoded.entries.map(\.id)).count == decoded.entries.count,
                      decoded.entries.allSatisfy({ !$0.term.isEmpty && ($0.workIDs == nil || (!$0.workIDs!.isEmpty && $0.workIDs!.allSatisfy { id in decoded.works.contains { $0.id == id } })) }) else {
                    throw AIError(message: L10n.tr("dictionary.corrupt"))
                }
                state = decoded
            } catch { loadError = error }
        }
    }

    public func terms(for context: DictionaryWorkContext?) throws -> [String] {
        if loadError != nil { throw AIError(message: L10n.tr("dictionary.corrupt")) }
        let id = context.flatMap { context in state.works.first { $0.matches(context.root) }?.id }
        return state.entries.filter { entry in
            entry.enabled && (entry.workIDs == nil || (id.map { entry.workIDs!.contains($0) } ?? false))
        }.map(\.term)
    }

    public func work(for context: DictionaryWorkContext) -> Work {
        var work = state.works.first { $0.matches(context.root) }
            ?? Work(id: UUID(), title: context.title, path: context.root.path, bookmark: nil)
        work.title = context.title
        work.path = context.root.path
        #if canImport(Darwin)
        work.bookmark = (try? context.root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? work.bookmark
        #endif
        return work
    }

    @discardableResult
    public func save(id: UUID? = nil, term: String, selectedWorks: [Work]?, enabled: Bool = true) throws -> Entry {
        dispatchPrecondition(condition: .onQueue(.main))
        guard loadError == nil else { throw AIError(message: L10n.tr("dictionary.corrupt")) }
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !term.isEmpty, term.count <= 100, !term.contains(where: { $0.isNewline }), !term.contains("\0"), !term.contains("\u{fffc}"),
              selectedWorks == nil || !selectedWorks!.isEmpty else { throw AIError(message: L10n.tr("dictionary.invalid")) }
        var next = state
        for work in selectedWorks ?? [] {
            if let index = next.works.firstIndex(where: { $0.id == work.id }) { next.works[index] = work }
            else { next.works.append(work) }
        }
        var item = Entry(id: id ?? UUID(), term: term, workIDs: selectedWorks.map { Array(Set($0.map(\.id))) }, enabled: enabled)
        if let id, let index = next.entries.firstIndex(where: { $0.id == id }) {
            guard !next.entries.contains(where: { $0.id != id && $0.term == term }) else { throw AIError(message: L10n.tr("dictionary.duplicate")) }
            next.entries[index] = item
        } else if let index = next.entries.firstIndex(where: { $0.term == term }) {
            let previous = next.entries[index]
            item = Entry(id: previous.id, term: term,
                         workIDs: !previous.enabled ? item.workIDs : (previous.workIDs == nil || item.workIDs == nil ? nil : Array(Set(previous.workIDs! + item.workIDs!))), enabled: enabled)
            next.entries[index] = item
        } else { next.entries.append(item) }
        try persist(next)
        return item
    }

    public func remove(ids: Set<UUID>) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard loadError == nil else { throw AIError(message: L10n.tr("dictionary.corrupt")) }
        var next = state
        next.entries.removeAll { ids.contains($0.id) }
        guard next.entries.count != state.entries.count else { return }
        try persist(next)
    }

    private func persist(_ next: State) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let backups = directory.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fileURL, to: backups.appendingPathComponent(UUID().uuidString + ".json"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: fileURL, options: .atomic)
        state = next
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
