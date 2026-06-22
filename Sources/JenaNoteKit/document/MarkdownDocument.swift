import AppKit

@objc(MarkdownDocument)
class MarkdownDocument: NSDocument {

    /// 문서 내용의 단일 진실 공급원 (Single Source of Truth)
    var content: NSMutableAttributedString = NSMutableAttributedString()

    /// 이미지 상대경로(`attachments/...`)를 해석할 기준 폴더 — 노트 파일이 있는 디렉토리.
    /// 미저장 새 문서는 nil.
    var attachmentBaseURL: URL? { fileURL?.deletingLastPathComponent() }

    enum ImageImportError: Error {
        /// 저장되지 않은 문서라 첨부를 둘 폴더가 없음
        case noDestination
    }

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
                                           : MarkdownSerializer.parse(text, baseURL: fileURL?.deletingLastPathComponent())
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

    // MARK: - Image Attachment

    /// 이미지를 노트 옆 `attachments/` 폴더로 복사하고, 노트 기준 상대경로를 반환한다.
    /// (예: `"attachments/photo.png"`) 파일명이 충돌하면 `-1`, `-2` 식으로 회피한다.
    /// - Throws: 저장되지 않은 문서(`fileURL == nil`)면 `ImageImportError.noDestination`.
    func importImage(from sourceURL: URL) throws -> String {
        guard let baseDir = attachmentBaseURL else { throw ImageImportError.noDestination }
        let attachmentsDir = baseDir.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        let destURL = uniqueDestination(for: sourceURL, in: attachmentsDir)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return "attachments/\(destURL.lastPathComponent)"
    }

    /// 대상 폴더에서 충돌하지 않는 파일 URL을 만든다.
    private func uniqueDestination(for source: URL, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(source.lastPathComponent)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var n = 1
        repeat {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            candidate = dir.appendingPathComponent(name)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
