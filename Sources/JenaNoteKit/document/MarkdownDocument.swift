import AppKit

@objc(MarkdownDocument)
class MarkdownDocument: NSDocument {

    /// 문서 내용의 단일 진실 공급원 (Single Source of Truth)
    var content: NSMutableAttributedString = NSMutableAttributedString()

    // MARK: - NSDocument Overrides

    override class var autosavesInPlace: Bool { return true }

    /// 저장 다이얼로그에 노출할 포맷 목록
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        return ["net.daringfireball.markdown", "public.plain-text"]
    }

    /// 포맷별 기본 확장자
    override func fileNameExtension(forType typeName: String,
                                    saveOperation: NSDocument.SaveOperationType) -> String? {
        return typeName == "public.plain-text" ? "txt" : "md"
    }

    override func makeWindowControllers() {
        let windowController = EditorWindowController()
        addWindowController(windowController)
    }

    /// 열기: 파일 데이터 → NSAttributedString
    override func read(from data: Data, ofType typeName: String) throws {
        let text = String(data: data, encoding: .utf8) ?? ""
        let parsed = isPlainText(typeName) ? MarkdownSerializer.parsePlainText(text)
                                           : MarkdownSerializer.parse(text)
        content = NSMutableAttributedString(attributedString: parsed)
    }

    /// 저장: NSAttributedString → 파일 데이터
    override func data(ofType typeName: String) throws -> Data {
        let text = isPlainText(typeName) ? content.string
                                        : MarkdownSerializer.serialize(content)
        guard let data = text.data(using: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "문서를 UTF-8로 인코딩할 수 없습니다."]
            )
        }
        return data
    }

    private func isPlainText(_ typeName: String) -> Bool {
        let ext = fileURL?.pathExtension.lowercased() ?? ""
        return ext == "txt" || typeName == "public.plain-text"
    }

    /// 편집기에서 내용이 변경될 때 호출 — 문서 dirty 상태 갱신
    func textDidChange(_ newContent: NSAttributedString) {
        content = NSMutableAttributedString(attributedString: newContent)
        updateChangeCount(.changeDone)
    }
}
