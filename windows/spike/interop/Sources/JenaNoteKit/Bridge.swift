import Foundation

// C ABI boundary for the spike: UTF-8 strings and JSON in, callback or owned buffer out.
// Every buffer returned to the caller is released with jena_free.

private func duplicate(_ text: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(text.utf8CString)
    let copy = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    copy.initialize(from: bytes, count: bytes.count)
    return copy
}

@_cdecl("jena_free")
public func jena_free(_ pointer: UnsafeMutableRawPointer?) {
    pointer?.deallocate()
}

/// Round-trips a string through Swift so the harness can check UTF-8 and call overhead.
@_cdecl("jena_echo")
public func jena_echo(_ text: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    duplicate(String(cString: text))
}

// MARK: - HWPX export

private struct InlineDTO: Decodable {
    var text: String
    var bold: Bool?
    var italic: Bool?
    var code: Bool?
    var color: String?
    var link: String?

    var model: Inline {
        Inline(text: text, bold: bold ?? false, italic: italic ?? false,
               code: code ?? false, color: color, link: link)
    }
}

private struct BlockDTO: Decodable {
    var type: String
    var level: Int?
    var ordered: Bool?
    var index: Int?
    var inlines: [InlineDTO]?
    var text: String?

    func model() throws -> Block {
        let content = (inlines ?? []).map(\.model)
        switch type {
        case "heading": return .heading(level: level ?? 1, inlines: content)
        case "paragraph": return .paragraph(content)
        case "listItem": return .listItem(ordered: ordered ?? false, index: index ?? 1, inlines: content)
        case "blockquote": return .blockquote(content)
        case "codeBlock": return .codeBlock(text ?? "")
        case "horizontalRule": return .horizontalRule
        default: throw AIError(message: "unknown block type: \(type)")
        }
    }
}

/// Returns 0 and an owned buffer on success, -1 and an owned error string on failure.
@_cdecl("jena_hwpx_from_json")
public func jena_hwpx_from_json(_ json: UnsafePointer<CChar>,
                                _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                                _ outLength: UnsafeMutablePointer<Int>,
                                _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        let source = Data(String(cString: json).utf8)
        let blocks = try JSONDecoder().decode([BlockDTO].self, from: source).map { try $0.model() }
        let data = HwpxWriter.write(blocks)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: buffer, count: data.count)
        outData.pointee = buffer
        outLength.pointee = data.count
        return 0
    } catch {
        outError.pointee = duplicate(String(describing: error))
        return -1
    }
}

// MARK: - Proofreading

public typealias JenaResultCallback = @convention(c) (
    _ result: UnsafePointer<CChar>?, _ error: UnsafePointer<CChar>?, _ context: UInt
) -> Void

private var proofreadingEngine: KiwiProofreadingEngine?

/// Model directory is a UTF-8 path. Call once before jena_proofread.
@_cdecl("jena_proofread_configure")
public func jena_proofread_configure(_ modelDirectory: UnsafePointer<CChar>) {
    let url = URL(fileURLWithPath: String(cString: modelDirectory), isDirectory: true)
    proofreadingEngine = KiwiProofreadingEngine(modelURL: { url })
}

/// Completes on a background thread. The strings are valid only during the callback.
@_cdecl("jena_proofread")
public func jena_proofread(_ text: UnsafePointer<CChar>, _ callback: JenaResultCallback, _ context: UInt) {
    let source = String(cString: text)
    let engine = proofreadingEngine
    Task.detached {
        do {
            guard let engine else { throw AIError(message: "engine not configured") }
            let corrected = try await engine.check(source)
            corrected.withCString { callback($0, nil, context) }
        } catch {
            String(describing: error).withCString { callback(nil, $0, context) }
        }
    }
}
