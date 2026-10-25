import Foundation
import Darwin

/// Creates a single child without replacing any existing file or directory.
enum SidebarItemCreation {
    static func create(named rawName: String, in parent: URL, isDirectory: Bool) throws -> URL {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                          userInfo: [NSLocalizedDescriptionKey: L10n.tr("sidebar.create.invalidName")])
        }
        if !isDirectory && (name as NSString).pathExtension.lowercased() != "md" {
            name += ".md"
        }
        let url = parent.appendingPathComponent(name, isDirectory: isDirectory)
        if isDirectory {
            // mkdir fails with EEXIST even if another process creates this name concurrently.
            let result = url.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.mkdir($0, 0o755) } ?? -1
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSFilePathErrorKey: url.path])
            }
        } else {
            try Data().write(to: url, options: .withoutOverwriting)
        }
        return url
    }
}
