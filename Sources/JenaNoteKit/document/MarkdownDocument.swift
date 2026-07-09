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

    // MARK: - External Change Reload

    /// 디스크의 파일이 외부에서 바뀌었고 미저장 편집이 없으면 조용히 다시 읽는다.
    /// FSEvents(.folderContentsDidChange) 경유로 호출되며, 수정 시각 비교로
    /// 중복 리로드를 막는다. 미저장 편집이 있으면 덮어쓰지 않고 건너뛴다.
    func reloadFromDiskIfClean() {
        guard let url = fileURL, !isDocumentEdited else { return }
        guard let diskDate = (try? FileManager.default
            .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return }
        if let known = fileModificationDate, diskDate <= known { return }
        guard let type = fileType else { return }
        do {
            try revert(toContentsOf: url, ofType: type)
            fileModificationDate = diskDate
        } catch {
            // 읽기 실패(잠금·부분 쓰기 등)는 다음 변경 이벤트에서 재시도된다.
        }
    }

    /// 되돌리기(수동 메뉴·자동 리로드 공통)가 content 를 교체한 뒤 뷰가 따라오도록 알린다.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        NotificationCenter.default.post(name: .documentDidReloadFromDisk, object: self)
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

extension Notification.Name {
    /// 문서가 디스크에서 다시 읽혔음(수동 되돌리기·외부 변경 자동 리로드).
    /// object 는 해당 MarkdownDocument.
    static let documentDidReloadFromDisk = Notification.Name("JNDocumentDidReloadFromDisk")
}
