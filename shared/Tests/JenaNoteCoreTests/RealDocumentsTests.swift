import XCTest
@testable import JenaNoteCore

/// The project's own Markdown files, which use far more of the format than short test inputs.
final class RealDocumentsTests: XCTestCase {
    private var documents: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("docs")
        let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
        return found + ["README.md", "README.ko.md", "README.en.md"].map { root.appendingPathComponent($0) }
    }

    private func normalized(_ url: URL) throws -> String {
        try String(decoding: Data(contentsOf: url), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }

    func testSavingTwiceGivesTheSameFile() throws {
        XCTAssertGreaterThan(documents.count, 10, "The documents were not found")
        for url in documents {
            let once = MarkdownWriter.write(MarkdownParser.parse(try normalized(url)))
            XCTAssertEqual(MarkdownWriter.write(MarkdownParser.parse(once)), once, url.lastPathComponent)
        }
    }

    /// Saving may tidy how something is written, but every word of the document must remain.
    func testSavingKeepsEveryWord() throws {
        func words(_ text: String) -> [String: Int] {
            var counts: [String: Int] = [:]
            let ignored = CharacterSet(charactersIn: "*_`|-:#>+").union(.whitespacesAndNewlines)
            for word in text.components(separatedBy: ignored) where !word.isEmpty { counts[word, default: 0] += 1 }
            return counts
        }
        for url in documents {
            let source = try normalized(url)
            XCTAssertEqual(words(MarkdownWriter.write(MarkdownParser.parse(source))), words(source), url.lastPathComponent)
        }
    }
}
