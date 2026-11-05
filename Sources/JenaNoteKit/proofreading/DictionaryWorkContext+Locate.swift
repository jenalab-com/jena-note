import Foundation

extension DictionaryWorkContext {
    static func locate(documentURL: URL?) -> Self? {
        guard let documentURL, let context = AIWorkContext.locate(from: documentURL) else { return nil }
        return Self(root: context.rootURL.standardizedFileURL.resolvingSymlinksInPath(), title: context.config.title)
    }
}
