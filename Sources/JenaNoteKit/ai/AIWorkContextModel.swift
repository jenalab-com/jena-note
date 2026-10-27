import Foundation

/// Pure logic behind the work context views (settings/episode rows, budget, source management,
/// folder drafts). No AppKit views here, so everything is unit-testable.
enum AIWorkContextModel {
    struct SettingRow: Equatable {
        let file: AIWorkFile
        var included: Bool
        var summarized: Bool
        let unreadable: Bool
    }

    struct EpisodeRow: Equatable {
        let file: AIWorkFile
        let state: AISummaryState
    }

    /// Every settings file the sources yield — included, excluded and unreadable — in natural path order.
    static func settingRows(_ resolved: AIResolvedWorkContext) -> [SettingRow] {
        let config = resolved.context.config
        let excluded = Set(config.excludedSettings)
        let summarized = Set(config.summarizedSettings)
        let unreadable = Set(resolved.unreadable.map(\.relativePath))
        let all = AIWorkContextResolver.naturalSort(resolved.settings + resolved.unreadable + resolved.excludedSettings)
        return all.map { file in
            SettingRow(file: file, included: !excluded.contains(file.relativePath),
                       summarized: summarized.contains(file.relativePath),
                       unreadable: unreadable.contains(file.relativePath))
        }
    }

    /// Settings files above this size get a warning (spec §6.6); they stay includable.
    static let largeFileThreshold = 200_000

    static func isLarge(_ file: AIWorkFile) -> Bool { file.byteCount > largeFileThreshold }

    /// Warning line for `context.json` paths that were ignored (outside the root etc., spec §6.7).
    static func invalidPathsText(_ context: AIWorkContext) -> String? {
        guard !context.invalidPaths.isEmpty else { return nil }
        return String(format: L10n.tr("ai.work.invalidPaths"), context.invalidPaths.joined(separator: ", "))
    }

    static func episodeRows(_ resolved: AIResolvedWorkContext, store: AIEpisodeSummaryStore) -> [EpisodeRow] {
        let index = store.snapshotIndex()
        return resolved.previousEpisodes.map { EpisodeRow(file: $0, state: store.state(of: $0, isSetting: false, index: index)) }
    }

    static func stateText(_ state: AISummaryState) -> String {
        switch state {
        case .ready: return L10n.tr("ai.work.stateReady")
        case .missing: return L10n.tr("ai.work.stateMissing")
        case .stale: return L10n.tr("ai.work.stateStale")
        case .manuallyEdited(let sourceChanged):
            return L10n.tr(sourceChanged ? "ai.work.stateManualSourceChanged" : "ai.work.stateManual")
        }
    }

    /// Unchecking a settings file adds it to `excludedSettings`; checking it again removes it.
    static func toggleIncluded(_ config: inout AIWorkContextConfig, path: String) {
        if let index = config.excludedSettings.firstIndex(of: path) {
            config.excludedSettings.remove(at: index)
        } else {
            config.excludedSettings.append(path)
        }
    }

    static func toggleSummarized(_ config: inout AIWorkContextConfig, path: String) {
        if let index = config.summarizedSettings.firstIndex(of: path) {
            config.summarizedSettings.remove(at: index)
        } else {
            config.summarizedSettings.append(path)
        }
    }

    /// UTF-8 bytes per budget segment; the three add up to `payload.contextByteCount`.
    static func budgetSegments(_ payload: AIWorkPayload) -> (settings: Int, summaries: Int, previous: Int) {
        (payload.settings.reduce(0) { $0 + $1.text.utf8.count },
         payload.previousSummaries.reduce(0) { $0 + $1.summary.utf8.count },
         payload.previousEpisode?.text.utf8.count ?? 0)
    }

    // MARK: - Sources

    struct SourceRow: Equatable {
        let relativePath: String
        let url: URL
        let isDirectory: Bool
        let fileCount: Int?      // folders: allowed text files, recursively
        let byteCount: Int?      // files: size
    }

    /// One row per configured source, in config order. Sources that no longer exist still appear
    /// (count 0 / nil) so the user can remove them.
    static func sourceRows(_ resolved: AIResolvedWorkContext) -> [SourceRow] {
        let root = resolved.context.rootURL
        return resolved.context.config.settingsSources.map { path in
            let url = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists, isDir.boolValue {
                return SourceRow(relativePath: path, url: url, isDirectory: true,
                                 fileCount: AIWorkContextResolver.files(under: url, recursive: true).count,
                                 byteCount: nil)
            }
            let size = exists ? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) : nil
            return SourceRow(relativePath: path, url: url, isDirectory: false,
                             fileCount: exists ? nil : 0, byteCount: size)
        }
    }

    enum FileSort { case sizeDescending, name }

    static func sortedSettingRows(_ rows: [SettingRow], by sort: FileSort) -> [SettingRow] {
        switch sort {
        case .name:
            return rows.sorted { $0.file.relativePath.localizedStandardCompare($1.file.relativePath) == .orderedAscending }
        case .sizeDescending:
            return rows.sorted {
                if $0.file.byteCount != $1.file.byteCount { return $0.file.byteCount > $1.file.byteCount }
                return $0.file.relativePath.localizedStandardCompare($1.file.relativePath) == .orderedAscending
            }
        }
    }

    /// One fact line: room left → "Settings 180KB + summaries 40KB = 220KB / 500KB"; over the limit
    /// → the same sum plus the limit and how much to cut.
    static func budgetFactLine(_ payload: AIWorkPayload) -> String {
        let segments = budgetSegments(payload)
        let total = payload.contextByteCount
        let format = AIWorkContextBar.formatBytes
        let limit = AIPrompt.maximumBytes
        if total > limit {
            return String(format: L10n.tr("ai.work.budget.over"), format(segments.settings), format(segments.summaries),
                          format(total), format(limit), format(total - limit))
        }
        return String(format: L10n.tr("ai.work.budget.under"), format(segments.settings), format(segments.summaries),
                      format(total), format(limit))
    }

    /// Adds a settings source (file or folder) as a root-relative path, then normalizes `enabled`.
    /// Adding one already present is a no-op.
    static func addingSource(_ url: URL, to config: inout AIWorkContextConfig, root: URL) throws {
        guard let rel = AIWorkContext.relativePath(of: url, to: root) else {
            throw AIWorkContextValidationError.settingsOutsideRoot(url.path)
        }
        if rel.isEmpty { throw AIWorkContextValidationError.settingsIsRoot }
        let hadSources = !config.settingsSources.isEmpty
        if !config.settingsSources.contains(rel) { config.settingsSources.append(rel) }
        normalizeEnabled(&config, previouslyHadSources: hadSources)
    }

    /// Excluded/summarized lists are left untouched so re-adding the source restores the choices.
    static func removingSource(_ relativePath: String, from config: inout AIWorkContextConfig) {
        let hadSources = !config.settingsSources.isEmpty
        config.settingsSources.removeAll { $0 == relativePath }
        normalizeEnabled(&config, previouslyHadSources: hadSources)
    }

    /// No sources → off. First source after "none" → on, unless the user switched it off by hand.
    static func normalizeEnabled(_ config: inout AIWorkContextConfig, previouslyHadSources: Bool) {
        if config.settingsSources.isEmpty {
            config.enabled = false
        } else if !previouslyHadSources && !config.disabledByUser {
            config.enabled = true
        }
    }

    // MARK: - Folders

    struct FoldersDraft: Equatable {
        var rootURL: URL
        var writingFolder: URL
        var title: String
        var errors: [AIWorkContextValidationError]
        var canApply: Bool

        init(rootURL: URL, writingFolder: URL, title: String) {
            self.rootURL = rootURL
            self.writingFolder = writingFolder
            self.title = title
            // Sources are managed separately; only the writing folder is checked here.
            self.errors = AIWorkContext.validate(rootURL: rootURL, settingsSources: [], writingFolder: writingFolder)
                .filter { $0 != .noSettingsSources }
            self.canApply = errors.isEmpty && !title.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static func foldersDraft(from context: AIWorkContext) -> FoldersDraft {
        // An ignored (invalid) writing folder entry is shown as the root until the user picks one.
        FoldersDraft(rootURL: context.rootURL, writingFolder: context.writingFolderURL ?? context.rootURL,
                     title: context.config.title)
    }

    /// First-time setup: root, writing folder and title as `AIWorkContextSuggestion` guesses them.
    static func foldersDraft(suggestionFor fileURL: URL) -> FoldersDraft {
        let suggestion = AIWorkContextSuggestion.make(for: fileURL)
        return FoldersDraft(rootURL: suggestion.rootURL, writingFolder: suggestion.writingFolderURL,
                            title: suggestion.title)
    }

    /// Writes title and writing folder (root-relative; `""` for the root) into a copy of `config`.
    static func applying(_ draft: FoldersDraft, to config: AIWorkContextConfig) -> AIWorkContextConfig {
        var result = config
        result.title = draft.title
        result.writingFolder = AIWorkContext.relativePath(of: draft.writingFolder, to: draft.rootURL) ?? ""
        return result
    }

    /// Names of the first visible entries of a folder (for the writing-folder preview).
    static func folderPreview(_ url: URL, limit: Int = 5) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Array(children.map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(limit))
    }
}
