import Foundation

struct AIWorkContextConfig: Codable, Equatable {
    var version: Int = 1
    var title: String
    var settingsSources: [String]          // relative to the work root ("/" separators)
    var excludedSettings: [String] = []
    var summarizedSettings: [String] = []
    var writingFolder: String              // relative to the work root
    var includePreviousEpisode: Bool = true
    var enabled: Bool = true
    /// True when the user switched the context off by hand (as opposed to "off because there are
    /// no sources"); keeps `normalizeEnabled` from re-enabling it when a source is added.
    var disabledByUser: Bool = false

    init(title: String, settingsSources: [String], excludedSettings: [String] = [],
         summarizedSettings: [String] = [], writingFolder: String, includePreviousEpisode: Bool = true,
         enabled: Bool = true, disabledByUser: Bool = false) {
        self.title = title
        self.settingsSources = settingsSources
        self.excludedSettings = excludedSettings
        self.summarizedSettings = summarizedSettings
        self.writingFolder = writingFolder
        self.includePreviousEpisode = includePreviousEpisode
        self.enabled = enabled
        self.disabledByUser = disabledByUser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        title = try c.decode(String.self, forKey: .title)
        settingsSources = try c.decode([String].self, forKey: .settingsSources)
        excludedSettings = try c.decodeIfPresent([String].self, forKey: .excludedSettings) ?? []
        summarizedSettings = try c.decodeIfPresent([String].self, forKey: .summarizedSettings) ?? []
        writingFolder = try c.decode(String.self, forKey: .writingFolder)
        includePreviousEpisode = try c.decodeIfPresent(Bool.self, forKey: .includePreviousEpisode) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        disabledByUser = try c.decodeIfPresent(Bool.self, forKey: .disabledByUser) ?? false
    }
}

enum AIWorkContextValidationError: Error, Equatable {
    case noSettingsSources, settingsOutsideRoot(String), settingsIsRoot, writingFolderOutsideRoot
}

enum AIWorkContextError: Error { case corrupt, notFound }

struct AIWorkContext: Equatable {
    static let folderName = ".jenanote"
    static let fileName = "context.json"
    /// The file's own folder is level 0; the root may sit up to 6 folders above it.
    /// e.g. root/집필/a/b/c/d/e/07화.md is found (e is level 0, root is level 6);
    /// one folder deeper is not.
    static let maxAncestorLevels = 6

    let rootURL: URL
    var config: AIWorkContextConfig
    var invalidPaths: [String]

    var configURL: URL {
        rootURL.appendingPathComponent(Self.folderName).appendingPathComponent(Self.fileName)
    }

    /// The writing folder, the root itself for `""`/`"."` (flat layout), or nil when the entry is
    /// invalid (absolute, `..`, outside the root): an invalid entry is ignored (spec §6.6) and the
    /// work behaves as "settings only" — it is never silently widened to the whole root.
    var writingFolderURL: URL? {
        if Self.isRootPath(config.writingFolder) { return rootURL }
        guard Self.isSafeRelative(config.writingFolder) else { return nil }
        let url = Self.resolve(config.writingFolder, in: rootURL)
        return contains(url) ? url : nil
    }

    var settingsSourceURLs: [URL] {
        config.settingsSources.compactMap { path in
            guard Self.isSafeRelative(path) else { return nil }
            let url = Self.resolve(path, in: rootURL)
            return contains(url) ? url : nil
        }
    }

    // MARK: Normalization

    /// Standardizes and resolves symlinks through the deepest existing ancestor,
    /// then re-appends the non-existent trailing components. (`resolvingSymlinksInPath`
    /// alone leaves the whole path untouched when the leaf does not exist.)
    fileprivate static func norm(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: existing.path)) == nil {
            let parent = existing.deletingLastPathComponent()
            if parent == existing { break }
            rest.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    /// `""` and `"."` name the work root itself (writing folder == root).
    private static func isRootPath(_ path: String) -> Bool { path.isEmpty || path == "." }

    private static func isSafeRelative(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func resolve(_ relative: String, in root: URL) -> URL {
        relative.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Home directory and volume roots are never searched.
    fileprivate static func isBoundary(_ dir: URL) -> Bool {
        let resolved = norm(dir)
        let comps = resolved.pathComponents
        if comps.count <= 1 { return true }
        if comps.count == 3, comps[1] == "Volumes" { return true }
        return resolved == norm(FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: Discovery

    static func locate(from fileURL: URL) -> AIWorkContext? {
        try? locateResult(from: fileURL).get()
    }

    /// Same search as `locate`, but surfaces a `context.json` that exists and fails to load
    /// (`AIWorkContextError.corrupt`) instead of treating it as "no work". `.success(nil)` means
    /// no `context.json` was found within range. Used by the AI panel's work context bar.
    static func locateResult(from fileURL: URL) -> Result<AIWorkContext?, Error> {
        let file = norm(fileURL)
        if file.pathComponents.contains(folderName) { return .success(nil) }
        var dir = file.deletingLastPathComponent()
        for _ in 0...maxAncestorLevels {
            if isBoundary(dir) { return .success(nil) }
            let candidate = dir.appendingPathComponent(folderName).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                do { return .success(try load(rootURL: dir)) } catch { return .failure(error) }
            }
            dir = dir.deletingLastPathComponent()
        }
        return .success(nil)
    }

    /// A `context.json` reached through a symlink (`.jenanote` or the file itself) or resolving outside
    /// the root is treated as missing (`notFound`); `locateResult` surfaces that as a failure.
    static func load(rootURL: URL) throws -> AIWorkContext {
        let url = rootURL.appendingPathComponent(folderName).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIWorkContextError.notFound }
        guard isSafeInsideRoot(url, root: rootURL) else { throw AIWorkContextError.notFound }
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AIWorkContextConfig.self, from: data)
        else { throw AIWorkContextError.corrupt }
        var context = AIWorkContext(rootURL: rootURL, config: config, invalidPaths: [])
        var invalid: [String] = []
        for path in config.settingsSources {
            if !isSafeRelative(path) || !context.contains(resolve(path, in: rootURL)) { invalid.append(path) }
        }
        let writing = config.writingFolder
        if !isRootPath(writing), !isSafeRelative(writing) || !context.contains(resolve(writing, in: rootURL)) {
            invalid.append(writing)
        }
        context.invalidPaths = invalid
        return context
    }

    /// Refuses (throws) to write through a symlinked `.jenanote` / `context.json` or outside the root.
    func save() throws {
        let dir = rootURL.appendingPathComponent(Self.folderName)
        try Self.ensureSafeInsideRoot(dir, root: rootURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.ensureSafeInsideRoot(configURL, root: rootURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    // MARK: Containment for app-owned files (.jenanote/...)

    /// True when `url` resolves under `root` AND no existing path component between the root and the
    /// leaf (e.g. `.jenanote`, `summaries`, sub-folders, the leaf itself) is a symbolic link.
    /// `url` must be built from `root` (same lexical prefix); anything else is rejected.
    /// Spec §3 / ADR-0014: reads stay under the root and never follow symlinks.
    static func isSafeInsideRoot(_ url: URL, root: URL) -> Bool {
        guard relativePath(of: url, to: root) != nil else { return false }
        let base = root.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else { return false }
        var current = root.standardizedFileURL
        for component in target.dropFirst(base.count) {
            current.appendPathComponent(component)
            // attributesOfItem does not follow a symlink at the leaf (lstat semantics).
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path) else {
                break // nothing exists from here on, so nothing below can be a link
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return false }
        }
        return true
    }

    /// Throwing form of `isSafeInsideRoot` for writes.
    static func ensureSafeInsideRoot(_ url: URL, root: URL) throws {
        guard isSafeInsideRoot(url, root: root) else {
            throw AIError(message: String(format: L10n.tr("ai.work.errorOutsideRoot"), url.path))
        }
    }

    /// True when url resolves (symlinks followed) to a location under rootURL.
    /// A symlink inside the root that points outside therefore returns false.
    func contains(_ url: URL) -> Bool {
        Self.relativePath(of: url, to: rootURL) != nil
    }

    static func relativePath(of url: URL, to root: URL) -> String? {
        // A raw ".." would be collapsed lexically before symlinks are resolved
        // (root/link/../x -> root/x) while the OS follows the link first. Reject.
        if url.pathComponents.contains("..") || root.pathComponents.contains("..") { return nil }
        let target = norm(url).pathComponents
        let base = norm(root).pathComponents
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else { return nil }
        return target.dropFirst(base.count).joined(separator: "/")
    }

    static func validate(rootURL: URL, settingsSources: [URL], writingFolder: URL) -> [AIWorkContextValidationError] {
        var errors: [AIWorkContextValidationError] = []
        if settingsSources.isEmpty { errors.append(.noSettingsSources) }
        for source in settingsSources {
            guard let rel = relativePath(of: source, to: rootURL) else {
                errors.append(.settingsOutsideRoot(source.path))
                continue
            }
            // The root itself has an empty relative path, which `isSafeRelative` rejects later.
            if rel.isEmpty { errors.append(.settingsIsRoot) }
        }
        // A writing folder equal to the root is allowed: it falls back to the root anyway.
        if relativePath(of: writingFolder, to: rootURL) == nil { errors.append(.writingFolderOutsideRoot) }
        return errors
    }
}

struct AIWorkContextSuggestion: Equatable {
    let rootURL: URL
    let settingsSourceURL: URL?            // `설정`/`settings` child folder, nil if none
    let writingFolderURL: URL              // the file's folder
    let title: String

    private static let settingsNames: Set<String> = ["설정", "settings"]

    static func make(for fileURL: URL) -> AIWorkContextSuggestion {
        let folder = AIWorkContext.norm(fileURL).deletingLastPathComponent()
        var dir = folder
        for _ in 0...AIWorkContext.maxAncestorLevels {
            if AIWorkContext.isBoundary(dir) { break }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            let match = children.first { child in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let name = child.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                return isDir && settingsNames.contains(name)
            }
            if let match = match {
                return AIWorkContextSuggestion(rootURL: dir, settingsSourceURL: match,
                                               writingFolderURL: folder, title: dir.lastPathComponent)
            }
            dir = dir.deletingLastPathComponent()
        }
        return AIWorkContextSuggestion(rootURL: folder, settingsSourceURL: nil,
                                       writingFolderURL: folder, title: folder.lastPathComponent)
    }
}
