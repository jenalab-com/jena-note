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
}

enum AIWorkContextValidationError: Equatable {
    case noSettingsSources, settingsOutsideRoot(String), writingFolderOutsideRoot
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

    var writingFolderURL: URL {
        guard Self.isSafeRelative(config.writingFolder) else { return rootURL }
        let url = Self.resolve(config.writingFolder, in: rootURL)
        return contains(url) ? url : rootURL
    }

    var settingsSourceURLs: [URL] {
        config.settingsSources.compactMap { path in
            guard Self.isSafeRelative(path) else { return nil }
            let url = Self.resolve(path, in: rootURL)
            return contains(url) ? url : nil
        }
    }

    // MARK: Normalization

    private static func norm(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

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
        let file = norm(fileURL)
        if file.pathComponents.contains(folderName) { return nil }
        var dir = file.deletingLastPathComponent()
        for _ in 0...maxAncestorLevels {
            if isBoundary(dir) { return nil }
            let candidate = dir.appendingPathComponent(folderName).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try? load(rootURL: dir)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func load(rootURL: URL) throws -> AIWorkContext {
        let url = rootURL.appendingPathComponent(folderName).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIWorkContextError.notFound }
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AIWorkContextConfig.self, from: data)
        else { throw AIWorkContextError.corrupt }
        var context = AIWorkContext(rootURL: rootURL, config: config, invalidPaths: [])
        var invalid: [String] = []
        for path in config.settingsSources {
            if !isSafeRelative(path) || !context.contains(resolve(path, in: rootURL)) { invalid.append(path) }
        }
        let writing = config.writingFolder
        if !isSafeRelative(writing) || !context.contains(resolve(writing, in: rootURL)) { invalid.append(writing) }
        context.invalidPaths = invalid
        return context
    }

    func save() throws {
        let dir = rootURL.appendingPathComponent(Self.folderName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    /// True when url resolves (symlinks followed) to a location under rootURL.
    /// A symlink inside the root that points outside therefore returns false.
    func contains(_ url: URL) -> Bool {
        Self.relativePath(of: url, to: rootURL) != nil
    }

    static func relativePath(of url: URL, to root: URL) -> String? {
        let target = norm(url).pathComponents
        let base = norm(root).pathComponents
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else { return nil }
        return target.dropFirst(base.count).joined(separator: "/")
    }

    static func validate(rootURL: URL, settingsSources: [URL], writingFolder: URL) -> [AIWorkContextValidationError] {
        var errors: [AIWorkContextValidationError] = []
        if settingsSources.isEmpty { errors.append(.noSettingsSources) }
        for source in settingsSources where relativePath(of: source, to: rootURL) == nil {
            errors.append(.settingsOutsideRoot(source.path))
        }
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
        let folder = fileURL.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
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
