import AppKit

extension EditorWindowController {
    /// 지금 보이는 화면을 찾기 대상으로 맞춘다.
    func documentFindContextChanged() {
        if isShowingSource, let source = sourcePreview {
            documentFinder.retarget(TextViewFindTarget(textView: source.textView))
        } else if let reader = readerVC {
            documentFinder.retarget(reader)
        } else {
            documentFinder.retarget(TextViewFindTarget(textView: editorVC.textView))
        }
    }

    @objc func focusDocumentFind(_ sender: Any?) {
        readerToolbar?.focusFindField()
    }

    /// ⌥⌘F — 헤더 검색창 아래에 바꾸기 입력창을 연다.
    @objc func showDocumentReplace(_ sender: Any?) {
        readerToolbar?.showReplacePanel()
    }

    @objc func findNextInDocument(_ sender: Any?) {
        moveDocumentFind(forward: true)
    }

    @objc func findPreviousInDocument(_ sender: Any?) {
        moveDocumentFind(forward: false)
    }

    private func moveDocumentFind(forward: Bool) {
        if documentFinder.query.isEmpty { focusDocumentFind(nil) } else { documentFinder.move(forward: forward) }
    }

    /// Esc — 검색을 끝내고 현재 일치를 선택한 채 본문으로 돌아간다.
    func cancelDocumentFind() {
        readerToolbar?.resetFindField()
        documentFinder.finish()
        let page = readerVC?.visiblePageTextViews.first as NSTextView?
        window?.makeFirstResponder(isShowingSource ? sourcePreview?.textView : page ?? editorVC.textView)
    }
}
