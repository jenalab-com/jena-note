import AppKit

/// Filesystem operations shared by sidebar actions; never overwrite a destination.
enum SidebarItemOperations {
    static func relocatedURL(_ url: URL, from source: URL, to destination: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let root = source.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return nil }
        let suffix = String(path.dropFirst(root.count))
        return URL(fileURLWithPath: destination.path + suffix)
    }

    static func rename(_ source: URL, to rawName: String) throws -> URL {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"),
              !name.contains(":"), !name.contains("\0") else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                          userInfo: [NSLocalizedDescriptionKey: L10n.tr("sidebar.create.invalidName")])
        }
        let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if !isDirectory, source.pathExtension.lowercased() == "md", (name as NSString).pathExtension.lowercased() != "md" {
            name += ".md"
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        guard destination != source else { return source }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
}

/// Retained by the sheet callback while NSDocument asks about unsaved changes.
final class SidebarDocumentCloseCheck: NSObject {
    private var documents: [NSDocument]
    private let completion: (Bool) -> Void

    init(documents: [NSDocument], completion: @escaping (Bool) -> Void) {
        self.documents = documents
        self.completion = completion
    }

    func start() {
        guard !documents.isEmpty else { completion(true); return }
        let document = documents.removeFirst()
        document.canClose(withDelegate: self, shouldClose: #selector(checked(_:shouldClose:contextInfo:)),
                          contextInfo: Unmanaged.passRetained(self).toOpaque())
    }

    @objc private func checked(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo = contextInfo else { return }
        let retained = Unmanaged<SidebarDocumentCloseCheck>.fromOpaque(contextInfo).takeRetainedValue()
        if shouldClose { retained.start() } else { retained.completion(false) }
    }
}
