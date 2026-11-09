import Foundation

/// Changes to a work context that every platform's settings window makes the same way.
public enum AIWorkContextEdits {
    /// Unchecking a settings file adds it to `excludedSettings`; checking it again removes it.
    public static func toggleIncluded(_ config: inout AIWorkContextConfig, path: String) {
        if let index = config.excludedSettings.firstIndex(of: path) {
            config.excludedSettings.remove(at: index)
        } else {
            config.excludedSettings.append(path)
        }
    }

    /// Adds a settings source (file or folder) as a root-relative path, then normalizes `enabled`.
    /// Adding one already present is a no-op.
    public static func addingSource(_ url: URL, to config: inout AIWorkContextConfig, root: URL) throws {
        guard let rel = AIWorkContext.relativePath(of: url, to: root) else {
            throw AIWorkContextValidationError.settingsOutsideRoot(url.path)
        }
        if rel.isEmpty { throw AIWorkContextValidationError.settingsIsRoot }
        let hadSources = !config.settingsSources.isEmpty
        if !config.settingsSources.contains(rel) { config.settingsSources.append(rel) }
        normalizeEnabled(&config, previouslyHadSources: hadSources)
    }

    /// Excluded/summarized lists are left untouched so re-adding the source restores the choices.
    public static func removingSource(_ relativePath: String, from config: inout AIWorkContextConfig) {
        let hadSources = !config.settingsSources.isEmpty
        config.settingsSources.removeAll { $0 == relativePath }
        normalizeEnabled(&config, previouslyHadSources: hadSources)
    }

    /// No sources → off. First source after "none" → on, unless the user switched it off by hand.
    public static func normalizeEnabled(_ config: inout AIWorkContextConfig, previouslyHadSources: Bool) {
        if config.settingsSources.isEmpty {
            config.enabled = false
        } else if !previouslyHadSources && !config.disabledByUser {
            config.enabled = true
        }
    }

    public static func rebase(_ path: String, from oldRoot: URL, to newRoot: URL) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path != ".", !path.hasPrefix("/"), !path.hasPrefix("~"), !parts.contains(".."),
              !AIWorkContext.isDrivePath(path) else {
            return path
        }
        let absolute = parts.reduce(oldRoot) { $0.appendingPathComponent(String($1)) }
        if let rel = AIWorkContext.relativePath(of: absolute, to: newRoot), !rel.isEmpty { return rel }
        return absolute.path
    }

    /// `invalidPaths` for an in-memory context, matching what `load` would report.
    public static func withInvalidPaths(_ context: AIWorkContext) -> AIWorkContext {
        var result = context
        var invalid = context.config.settingsSources.filter { path in
            var single = context
            single.config.settingsSources = [path]
            return single.settingsSourceURLs.isEmpty
        }
        if context.writingFolderURL == nil { invalid.append(context.config.writingFolder) }
        result.invalidPaths = invalid
        return result
    }
}
