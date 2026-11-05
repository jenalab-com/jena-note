import Foundation
import JenaNoteCoreTestSupport

// Writes the Markdown corpus as JSON so the Windows app can run it through the real editor.
// Usage: corpus-dump <output file>

struct Case: Encodable {
    let name: String
    let input: String
    let expected: String
}

let cases = MarkdownCorpus.cases.map { Case(name: $0.name, input: $0.input, expected: $0.expected) }
let data = try JSONEncoder().encode(cases)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
