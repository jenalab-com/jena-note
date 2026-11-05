import Foundation
import JenaNoteCore

// C ABI over JenaNoteCore for the Windows app. Strings are UTF-8. A returned pointer is owned
// by the caller and released with jena_free. Functions that can fail return it through
// `result` or `error` and return 0 on success.

func duplicate(_ text: String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(text.utf8CString)
    let copy = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    copy.initialize(from: bytes, count: bytes.count)
    return copy
}

@_cdecl("jena_free")
public func jena_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    pointer?.deallocate()
}

@_cdecl("jena_markdown_to_json")
public func jena_markdown_to_json(_ markdown: UnsafePointer<CChar>,
                                  _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                  _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        result.pointee = duplicate(try MarkdownJSON.encode(MarkdownParser.parse(String(cString: markdown))))
        return 0
    } catch let failure {
        error.pointee = duplicate(String(describing: failure))
        return -1
    }
}

@_cdecl("jena_json_to_markdown")
public func jena_json_to_markdown(_ json: UnsafePointer<CChar>,
                                  _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                  _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        result.pointee = duplicate(MarkdownWriter.write(try MarkdownJSON.decode(String(cString: json))))
        return 0
    } catch let failure {
        error.pointee = duplicate(String(describing: failure))
        return -1
    }
}

/// Text for a translation key in the current language. Unknown keys come back as the key.
@_cdecl("jena_tr")
public func jena_tr(_ key: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    duplicate(L10n.tr(String(cString: key)))
}
