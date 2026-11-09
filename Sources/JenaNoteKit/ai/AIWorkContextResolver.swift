import AppKit
import Foundation

// The resolver itself is shared. Here it learns about the documents open in this app.
private var openDocumentsProvider: () -> [MarkdownDocument] = {
    NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
}

extension AIWorkContextResolver {
    /// Injectable for tests.
    static var openDocuments: () -> [MarkdownDocument] {
        get { openDocumentsProvider }
        set {
            openDocumentsProvider = newValue
            useOpenDocuments()
        }
    }

    /// Connects the shared resolver to this app's documents. The app calls this as it starts.
    static func useOpenDocuments() {
        openDocumentText = { url in
            let target = url.standardizedFileURL.resolvingSymlinksInPath()
            return openDocumentsProvider().first {
                $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == target
            }?.content.string
        }
    }
}
