import AppKit
import QuartzCore

extension EditorWindowController {
    /// 이 크기를 넘는 파일은 읽기 시작 전에 바로 띄운다. 읽는 동안 메인이 멈춰 타이머가 돌지 못한다.
    private static let largeFileBytes = 150_000
    /// 문서가 이미 메모리에 있어도 이 길이를 넘으면 화면에 그리는 데 시간이 걸린다.
    private static let largeDocumentLength = 50_000
    /// 작은 파일은 금방 열려 깜빡이기만 하므로, 클라우드 내려받기처럼 늦어질 때만 띄운다.
    private static let loadingDelay: TimeInterval = 0.15
    private static let fadeDuration: TimeInterval = 0.12

    func beginDocumentLoading(of url: URL) {
        documentLoadingDelay?.cancel()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size >= Self.largeFileBytes {
            showDocumentLoading()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.showDocumentLoading() }
        documentLoadingDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadingDelay, execute: work)
    }

    func showDocumentLoadingIfLarge(_ doc: MarkdownDocument) {
        if doc.content.length >= Self.largeDocumentLength { showDocumentLoading() }
    }

    /// 다음 화면 갱신까지 기다렸다 걷어야 그려진 본문이 바로 이어진다.
    func endDocumentLoading() {
        documentLoadingDelay?.cancel()
        documentLoadingDelay = nil
        guard let view = documentLoadingView else { return }
        documentLoadingView = nil
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeDuration
                view.animator().alphaValue = 0
            }, completionHandler: { view.removeFromSuperview() })
        }
    }

    private func showDocumentLoading() {
        guard documentLoadingView == nil, let window, let host = window.contentView,
              let pane = documentPaneView else { return }
        // 처음 여는 창은 아직 화면에 없다. 먼저 띄워야 그리는 동안 스켈레톤이 보인다.
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        window.layoutIfNeeded()
        var frame = host.convert(pane.bounds, from: pane)
        // 문서 영역이 상태바 밑까지 내려가도 글자 수와 구분선은 가리지 않는다.
        let bottom = min(frame.maxY, max(frame.minY, StatusBarView.barHeight))
        frame.size.height = frame.maxY - bottom
        frame.origin.y = bottom
        let view = DocumentLoadingView(frame: frame)
        view.autoresizingMask = [.width, .height]
        // 바꾸기 박스가 열려 있으면 그 아래, 없으면 맨 위에 놓는다.
        if let panel = readerToolbar?.replacePanel {
            host.addSubview(view, positioned: .below, relativeTo: panel)
        } else {
            host.addSubview(view)
        }
        documentLoadingView = view
        // 곧 메인이 그리기로 막힌다. 그 전에 화면으로 내보내야 애니메이션이 돈다.
        window.displayIfNeeded()
        CATransaction.flush()
    }
}
