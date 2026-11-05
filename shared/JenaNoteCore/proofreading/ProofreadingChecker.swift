import Foundation

/// Checks whole passages: splits them into sentences, reuses recent results and reports
/// suggestions in the passage's own UTF-16 offsets. Personal dictionary terms stay outside the
/// cache, so changing the dictionary takes effect without running the engine again.
public final class ProofreadingChecker: @unchecked Sendable {
    public typealias Check = @Sendable (String) async throws -> String

    private static let cacheLimit = 64
    private let check: Check
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    public init(check: @escaping Check) {
        self.check = check
    }

    public func suggestions(in text: String, terms: [String]) async throws -> [ProofreadingSuggestion] {
        var result: [ProofreadingSuggestion] = []
        let whole = NSRange(location: 0, length: text.utf16.count)
        for (range, input) in ProofreadingAnnotations.chunks(text, in: whole) {
            try Task.checkCancellation()
            let corrected = try await correction(of: input)
            for item in ProofreadingSuggestion.suggestions(source: input, corrected: corrected, terms: terms) {
                result.append(ProofreadingSuggestion(
                    range: NSRange(location: range.location + item.range.location, length: item.range.length),
                    original: item.original,
                    replacement: item.replacement,
                    marks: item.marks.map { NSRange(location: range.location + $0.location, length: $0.length) }))
            }
        }
        return result
    }

    private func correction(of input: String) async throws -> String {
        if let cached = lock.withLock({ cache[input] }) { return cached }
        let corrected = try await check(input)
        lock.withLock {
            if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[input] = corrected
        }
        return corrected
    }
}
