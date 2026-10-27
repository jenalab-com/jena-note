import AppKit
import Foundation

struct AIWorkFile: Equatable, Hashable {
    let relativePath: String   // settings: root-relative, episodes: writing-folder-relative ("/" separated)
    let url: URL
    let byteCount: Int
}

struct AIResolvedWorkContext {
    let context: AIWorkContext
    let settings: [AIWorkFile]
    let excludedSettings: [AIWorkFile]
    let unreadable: [AIWorkFile]
    let episodes: [AIWorkFile]
    let currentIndex: Int?

    var previousEpisodes: [AIWorkFile] {
        guard let index = currentIndex else { return [] }
        return Array(episodes[..<index])
    }
    var previousEpisode: AIWorkFile? {
        context.config.includePreviousEpisode ? previousEpisodes.last : nil
    }
    var isOutsideWritingFolder: Bool { currentIndex == nil }
}

enum AIWorkContextResolver {
    static let allowedExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Injectable for tests.
    static var openDocuments: () -> [MarkdownDocument] = {
        NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
    }

    static func resolve(_ context: AIWorkContext, currentFile: URL) -> AIResolvedWorkContext {
        // Settings: keep source order, natural sort within a source, root-relative paths.
        var all: [AIWorkFile] = []
        var seen = Set<String>()
        for source in context.settingsSourceURLs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }
            var items: [AIWorkFile]
            if isDir.boolValue {
                items = files(under: source, recursive: true)
            } else if isAllowed(source), !isSymlink(source) {
                items = [AIWorkFile(relativePath: source.lastPathComponent, url: source, byteCount: byteCount(source))]
            } else {
                items = []
            }
            items = items.compactMap { file in
                guard let rel = AIWorkContext.relativePath(of: file.url, to: context.rootURL) else { return nil }
                return AIWorkFile(relativePath: rel, url: file.url, byteCount: file.byteCount)
            }
            for file in naturalSort(items) where seen.insert(file.relativePath).inserted {
                all.append(file)
            }
        }
        let excludedKeys = Set(context.config.excludedSettings)
        var settings: [AIWorkFile] = []
        var excluded: [AIWorkFile] = []
        var unreadable: [AIWorkFile] = []
        for file in all {
            if excludedKeys.contains(file.relativePath) {
                excluded.append(file)
            } else if (try? readText(file)) == nil {
                unreadable.append(file)
            } else {
                settings.append(file)
            }
        }

        let episodes = naturalSort(files(under: context.writingFolderURL, recursive: true))
        var currentIndex: Int?
        if let currentRel = AIWorkContext.relativePath(of: currentFile, to: context.rootURL) {
            currentIndex = episodes.firstIndex {
                AIWorkContext.relativePath(of: $0.url, to: context.rootURL) == currentRel
            }
        }
        return AIResolvedWorkContext(context: context, settings: settings, excludedSettings: excluded,
                                     unreadable: unreadable, episodes: episodes, currentIndex: currentIndex)
    }

    static func files(under base: URL, recursive: Bool) -> [AIWorkFile] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .isHiddenKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys, options: options) else { return [] }
        let basePath = base.standardizedFileURL.pathComponents
        var result: [AIWorkFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true, isAllowed(url) else { continue }
            let comps = url.standardizedFileURL.pathComponents
            guard comps.count > basePath.count, Array(comps.prefix(basePath.count)) == basePath else { continue }
            let rel = comps.dropFirst(basePath.count).joined(separator: "/")
            result.append(AIWorkFile(relativePath: rel, url: url, byteCount: values?.fileSize ?? 0))
        }
        return result
    }

    static func naturalSort(_ files: [AIWorkFile]) -> [AIWorkFile] {
        files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func readText(_ file: AIWorkFile) throws -> String {
        guard let data = try? Data(contentsOf: file.url),
              let text = String(data: data, encoding: .utf8)
        else { throw AIError(message: L10n.tr("ai.work.unreadable")) }
        return normalize(text)
    }

    static func readSettingText(_ file: AIWorkFile) throws -> String {
        let target = file.url.standardizedFileURL.resolvingSymlinksInPath()
        for doc in openDocuments() where doc.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == target {
            return normalize(doc.content.string)
        }
        return try readText(file)
    }

    private static func isAllowed(_ url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func byteCount(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
