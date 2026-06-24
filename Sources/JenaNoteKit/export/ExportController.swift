import AppKit

// MARK: - ExportController
//
// File > 내보내기 메뉴의 타깃. 현재 문서를 docx/hwpx로 내보낸다.
// 내보내기는 NSDocument 저장 흐름 **바깥**의 독립 동작이다 — 원본 md 문서의
// dirty 상태·`fileURL`을 건드리지 않는다(Save As 아님).

final class ExportController: NSObject, NSMenuItemValidation {

    static let shared = ExportController()

    enum Format {
        case docx
        case hwpx

        var ext: String { self == .docx ? "docx" : "hwpx" }
    }

    // MARK: - 메뉴 액션

    @objc func exportDocx(_ sender: Any?) { export(.docx) }
    @objc func exportHwpx(_ sender: Any?) { export(.hwpx) }

    /// 현재 문서가 있을 때만 메뉴 활성화.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return currentDocument != nil
    }

    private var currentDocument: MarkdownDocument? {
        NSDocumentController.shared.currentDocument as? MarkdownDocument
    }

    // MARK: - 내보내기 흐름

    private func export(_ format: Format) {
        guard let doc = currentDocument else { NSSound.beep(); return }

        // IR 변환은 패널을 띄우기 전에(취소해도 가벼움). 이미지 로드 실패 수를 함께 얻는다.
        let model = DocumentModelBuilder.build(doc.content, baseURL: doc.attachmentBaseURL)
        let baseName = doc.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName).\(format.ext)"
        panel.allowedFileTypes = [format.ext]   // 확장자 고정
        panel.canCreateDirectories = true

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeFile(format: format, blocks: model.blocks,
                            imageFailures: model.imageLoadFailures, to: url)
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    private func writeFile(format: Format, blocks: [Block], imageFailures: Int, to url: URL) {
        let data: Data
        var skipped = imageFailures
        switch format {
        case .docx:
            data = DocxWriter.write(blocks)
        case .hwpx:
            // hwpx는 1차에서 이미지를 생략한다 — 생략 수를 경고에 반영.
            let out = HwpxWriter.build(blocks)
            data = out.data
            skipped = out.imageSkipped
        }

        do {
            try data.write(to: url)
            if skipped > 0 { warnImagesSkipped(skipped) }
        } catch {
            showWriteError()
        }
    }

    // MARK: - 알림

    private func warnImagesSkipped(_ count: Int) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("export.warn.title")
        alert.informativeText = String(format: L10n.tr("export.warn.imageSkipped"), count)
        alert.runModal()
    }

    private func showWriteError() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.tr("export.error.title")
        alert.informativeText = L10n.tr("export.error.message")
        alert.runModal()
    }
}
