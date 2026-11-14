import AppKit
import ImageIO

/// 이미지 트리용 NSOutlineView (우측 사이드바로 옮길 예정 — 지금은 쓰는 곳이 없다) — 이미지 행 위에 마우스를 올리면
/// 최대 100px 미리보기를 NSPopover로 띄운다. (우측 문서 화면은 건드리지 않는다)
final class ImagePreviewOutlineView: SidebarOutlineView {

    private let popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .applicationDefined   // hover 전용 — 우리가 직접 닫는다
        p.animates = false
        return p
    }()
    private var hoveredRow = -1
    private var previewCache: [String: NSImage] = [:]

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let r = row(at: point)
        guard r >= 0, let node = item(atRow: r) as? SidebarNode, !node.isDirectory else {
            hidePreview(); return
        }
        if r == hoveredRow && popover.isShown { return }
        showPreview(for: node, row: r)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hidePreview()
    }

    // MARK: - Preview

    private func previewImage(for url: URL) -> NSImage? {
        if let cached = previewCache[url.path] { return cached }
        guard let img = Self.downsampledImage(at: url, maxPixel: 100) else { return nil }
        previewCache[url.path] = img
        return img
    }

    private func showPreview(for node: SidebarNode, row: Int) {
        guard let image = previewImage(for: node.url) else { hidePreview(); return }
        hoveredRow = row

        let size = image.size
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = image

        let vc = NSViewController()
        vc.view = imageView

        popover.contentViewController = vc
        popover.contentSize = size

        popover.show(relativeTo: rect(ofRow: row), of: self, preferredEdge: .maxX)
    }

    private func hidePreview() {
        hoveredRow = -1
        if popover.isShown { popover.performClose(nil) }
    }

    /// ImageIO로 최대 변 maxPixel 이하 썸네일을 만든다 (메모리 절약).
    static func downsampledImage(at url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
