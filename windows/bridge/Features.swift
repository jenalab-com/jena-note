import Foundation
import JenaNoteCore

// Proofreading, personal dictionary and export for the Windows app. See Bridge.swift for the
// conventions. The dictionary store belongs to the main thread, so call those functions from the
// UI thread. Proofreading finishes on a background thread through the callback.

public typealias JenaResultCallback = @convention(c) (
    _ result: UnsafePointer<CChar>?, _ error: UnsafePointer<CChar>?, _ context: UInt
) -> Void

private func encode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func message(for error: Error) -> String {
    (error as? AIError)?.message ?? String(describing: error)
}

private func decodeTerms(_ json: UnsafePointer<CChar>) throws -> [String] {
    try JSONDecoder().decode([String].self, from: Data(String(cString: json).utf8))
}

private func document(_ path: UnsafePointer<CChar>?) -> URL? {
    path.map { URL(fileURLWithPath: String(cString: $0)) }
}

private func run(_ body: () throws -> String,
                 _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                 _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        result.pointee = duplicate(try body())
        return 0
    } catch let failure {
        error.pointee = duplicate(message(for: failure))
        return -1
    }
}

// MARK: - Proofreading

private struct ProofreadItem: Decodable {
    let id: Int
    let text: String
}

private struct SuggestionDTO: Encodable {
    struct Span: Encodable {
        let location: Int
        let length: Int
        init(_ range: NSRange) {
            location = range.location
            length = range.length
        }
    }

    let range: Span
    let original: String
    let replacement: String
    let marks: [Span]

    init(_ suggestion: ProofreadingSuggestion) {
        range = Span(suggestion.range)
        original = suggestion.original
        replacement = suggestion.replacement
        marks = suggestion.marks.map(Span.init)
    }
}

private struct ProofreadResult: Encodable {
    let id: Int
    let suggestions: [SuggestionDTO]
}

private var engine: KiwiProofreadingEngine?
private var checker: ProofreadingChecker?

/// The model folder ships beside the app, so the engine never looks for a SwiftPM resource bundle.
@_cdecl("jena_proofreading_configure")
public func jena_proofreading_configure(_ modelDirectory: UnsafePointer<CChar>) {
    let url = URL(fileURLWithPath: String(cString: modelDirectory), isDirectory: true)
    let created = KiwiProofreadingEngine(modelURL: { url })
    engine = created
    checker = ProofreadingChecker(check: { try await created.check($0) })
}

/// `items`: `[{"id", "text"}]`. `terms`: `["..."]`. The result is `[{"id", "suggestions"}]`, with
/// offsets in UTF-16. An item that fails stops the request, and the error reaches the callback.
@_cdecl("jena_proofread")
public func jena_proofread(_ items: UnsafePointer<CChar>, _ terms: UnsafePointer<CChar>,
                           _ callback: JenaResultCallback, _ context: UInt) {
    let itemsJSON = String(cString: items)
    let termsJSON = String(cString: terms)
    let current = checker
    Task.detached {
        do {
            guard let current else { throw AIError(message: L10n.tr("proof.engineFailed")) }
            let decoded = try JSONDecoder().decode([ProofreadItem].self, from: Data(itemsJSON.utf8))
            let allowed = try JSONDecoder().decode([String].self, from: Data(termsJSON.utf8))
            var results: [ProofreadResult] = []
            for item in decoded {
                let suggestions = try await current.suggestions(in: item.text, terms: allowed)
                if !suggestions.isEmpty {
                    results.append(ProofreadResult(id: item.id, suggestions: suggestions.map(SuggestionDTO.init)))
                }
            }
            try encode(results).withCString { callback($0, nil, context) }
        } catch {
            message(for: error).withCString { callback(nil, $0, context) }
        }
    }
}

/// Checks one selected passage on request. The result is the corrected text.
@_cdecl("jena_proofread_selection")
public func jena_proofread_selection(_ text: UnsafePointer<CChar>, _ terms: UnsafePointer<CChar>,
                                     _ callback: JenaResultCallback, _ context: UInt) {
    let source = String(cString: text)
    let termsJSON = String(cString: terms)
    let current = engine
    Task.detached {
        do {
            guard let current else { throw AIError(message: L10n.tr("proof.engineFailed")) }
            try AISelectionProofreader.validate(source)
            let allowed = try JSONDecoder().decode([String].self, from: Data(termsJSON.utf8))
            let corrected = try await current.check(source)
            let filtered = ProofreadingSuggestion.filteredText(source: source, corrected: corrected, terms: allowed)
            filtered.withCString { callback($0, nil, context) }
        } catch {
            message(for: error).withCString { callback(nil, $0, context) }
        }
    }
}

// MARK: - File search

private struct SearchResponse: Encodable {
    struct Hit: Encodable {
        let line: Int
        let text: String
        let start: Int
        let length: Int
        let ordinal: Int
    }
    struct File: Encodable {
        let path: String
        let hits: [Hit]
    }
    let truncated: Bool
    let results: [File]
}

private var currentSearch: FileSearchToken?

/// `folders` is `["path"]`. A new search cancels the running one, whose callback still arrives.
@_cdecl("jena_search_files")
public func jena_search_files(_ query: UnsafePointer<CChar>, _ folders: UnsafePointer<CChar>,
                              _ callback: JenaResultCallback, _ context: UInt) {
    let text = String(cString: query)
    let foldersJSON = String(cString: folders)
    currentSearch?.cancel()
    let token = FileSearchToken()
    currentSearch = token
    Task.detached {
        do {
            let paths = try JSONDecoder().decode([String].self, from: Data(foldersJSON.utf8))
            let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let (results, truncated) = FileSearcher.searchSync(query: text, folders: urls, token: token)
            let files = results.map { result in
                // URL.path has a leading slash on Windows, which no Windows program can open.
                let path = result.fileURL.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? result.fileURL.path
                return SearchResponse.File(path: path, hits: result.hits.map { hit in
                    let snippet = FileSearcher.makeSnippet(lineText: hit.lineText, matchRange: hit.matchRangeInLine)
                    return SearchResponse.Hit(line: hit.lineNumber, text: snippet.text, start: snippet.highlight.location,
                                              length: snippet.highlight.length, ordinal: hit.ordinalInFile)
                })
            }
            try encode(SearchResponse(truncated: truncated, results: files)).withCString { callback($0, nil, context) }
        } catch {
            message(for: error).withCString { callback(nil, $0, context) }
        }
    }
}

// MARK: - Personal dictionary

private var dictionary = PersonalDictionaryStore.shared

/// For tests: keeps them away from the author's real dictionary.
@_cdecl("jena_dictionary_use_file")
public func jena_dictionary_use_file(_ path: UnsafePointer<CChar>) {
    dictionary = PersonalDictionaryStore(fileURL: URL(fileURLWithPath: String(cString: path)))
}

@_cdecl("jena_dictionary_terms")
public func jena_dictionary_terms(_ documentPath: UnsafePointer<CChar>?,
                                  _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                  _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    run({ try encode(try dictionary.terms(for: DictionaryWorkContext.locate(documentURL: document(documentPath)))) }, result, error)
}

private struct DictionaryListDTO: Encodable {
    struct Entry: Encodable {
        let id: String
        let term: String
        let enabled: Bool
        let allWorks: Bool
        let works: [String]
    }

    let currentWork: String?
    let entries: [Entry]
}

@_cdecl("jena_dictionary_list")
public func jena_dictionary_list(_ documentPath: UnsafePointer<CChar>?,
                                 _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                 _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    run({
        if let failure = dictionary.loadError { throw failure }
        let context = DictionaryWorkContext.locate(documentURL: document(documentPath))
        let works = dictionary.works
        let entries = dictionary.entries.map { entry in
            DictionaryListDTO.Entry(id: entry.id.uuidString, term: entry.term, enabled: entry.enabled,
                                    allWorks: entry.workIDs == nil,
                                    works: (entry.workIDs ?? []).compactMap { id in works.first { $0.id == id }?.title })
        }
        return try encode(DictionaryListDTO(currentWork: context?.title, entries: entries))
    }, result, error)
}

/// With `useCurrentWork` and a document inside a work, the term applies to that work only.
@_cdecl("jena_dictionary_add")
public func jena_dictionary_add(_ term: UnsafePointer<CChar>, _ documentPath: UnsafePointer<CChar>?, _ useCurrentWork: Int32,
                                _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        var works: [PersonalDictionaryStore.Work]?
        if useCurrentWork != 0, let context = DictionaryWorkContext.locate(documentURL: document(documentPath)) {
            works = [dictionary.work(for: context)]
        }
        try dictionary.save(term: String(cString: term), selectedWorks: works)
        return 0
    } catch let failure {
        error.pointee = duplicate(message(for: failure))
        return -1
    }
}

@_cdecl("jena_dictionary_remove")
public func jena_dictionary_remove(_ ids: UnsafePointer<CChar>,
                                   _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let decoded = try decodeTerms(ids).compactMap(UUID.init(uuidString:))
        try dictionary.remove(ids: Set(decoded))
        return 0
    } catch let failure {
        error.pointee = duplicate(message(for: failure))
        return -1
    }
}

// MARK: - Export

@_cdecl("jena_free_bytes")
public func jena_free_bytes(_ pointer: UnsafeMutablePointer<UInt8>?) {
    pointer?.deallocate()
}

/// `format` is "docx" or "hwpx". `skipped` counts images left out of the file.
@_cdecl("jena_export")
public func jena_export(_ blocks: UnsafePointer<CChar>, _ format: UnsafePointer<CChar>, _ baseFolder: UnsafePointer<CChar>?,
                        _ bodySize: Double, _ letterSpacing: Double,
                        _ data: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                        _ length: UnsafeMutablePointer<Int>,
                        _ skipped: UnsafeMutablePointer<Int32>,
                        _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let model = try MarkdownJSON.decode(String(cString: blocks))
        let folder = baseFolder.map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
        let result = MarkdownExport.blocks(from: model, baseFolder: folder)
        let bytes: Data
        switch String(cString: format) {
        case "docx":
            bytes = DocxWriter.write(result.blocks, bodySize: CGFloat(bodySize), letterSpacing: CGFloat(letterSpacing))
            skipped.pointee = Int32(result.imageLoadFailures)
        case "hwpx":
            // The hwpx writer leaves images out for now and counts them itself, as on macOS.
            let output = HwpxWriter.build(result.blocks, bodySize: CGFloat(bodySize), letterSpacing: CGFloat(letterSpacing))
            bytes = output.data
            skipped.pointee = Int32(output.imageSkipped)
        default:
            throw AIError(message: "unknown export format")
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(bytes.count, 1))
        bytes.copyBytes(to: buffer, count: bytes.count)
        data.pointee = buffer
        length.pointee = bytes.count
        return 0
    } catch let failure {
        error.pointee = duplicate(message(for: failure))
        return -1
    }
}

/// Default sizes until the Windows app has its own text settings.
@_cdecl("jena_default_body_size")
public func jena_default_body_size() -> Double {
    Double(MemoFontSize.body)
}
