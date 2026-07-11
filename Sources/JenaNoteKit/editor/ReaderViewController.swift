import AppKit

/// 페이징 모드 호스트 — 멀티 컨테이너 페이지뷰를 담는 불투명 오버레이.
/// flipped 로 페이지를 상단 기준 배치하고, 스크롤 제스처를 페이지 넘김으로 변환한다.
final class PagedHostView: NSView {
    override var isFlipped: Bool { true }
    var onPage: ((Bool) -> Void)?
    private var armed = true

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase != [] { return }
        let dy = event.scrollingDeltaY
        if event.phase == [] && event.momentumPhase == [] {
            // 마우스 휠(비연속): 매 노치마다 한 페이지.
            if abs(dy) > 0.5 { onPage?(dy < 0) }
            return
        }
        // 트랙패드(연속 제스처): 제스처당 한 번만.
        if event.phase == .began { armed = true }
        guard armed, abs(dy) > 2 else { return }
        armed = false
        onPage?(dy < 0)
    }
}

/// 읽기 전용 "책 보기" 뷰. document.content(이미 파싱된 NSAttributedString)를
/// 받아 한글 35자 컬럼으로 조판한다. 원본은 절대 수정하지 않는다.
///
/// - 스크롤 모드: 단일 NSScrollView + NSTextView 로 세로 스크롤(에디터 정석).
/// - 페이징 모드: NSLayoutManager 에 페이지마다 NSTextContainer 를 두는 "진짜 페이지네이션".
///   컨테이너에 안 들어가는 줄은 통째로 다음 페이지로 흐르므로 줄이 잘리지 않는다.
class ReaderViewController: NSViewController {

    /// 읽기 단(컬럼) 폭 프리셋. 저장하지 않으며 매 진입 시 .book 으로 시작한다.
    enum WidthMode {
        case book      // 글자수(readingLineLength) 기반 — 기존 폭
        case mobile    // 모바일 화면 폭(고정 px)
    }

    // MARK: - State
    private var sourceContent: NSAttributedString
    private var scale: CGFloat = SettingsManager.shared.readingFontScale
    private var pageMode: SettingsManager.ReadingPageMode = SettingsManager.shared.readingPageMode
    private var fontFamily: SettingsManager.ReadingFont = SettingsManager.shared.readingFont
    private var lineSpacing: CGFloat = SettingsManager.shared.readingLineSpacing
    private var widthMode: WidthMode = .book

    // MARK: - Scroll-mode views
    private var scrollView: NSScrollView!
    private var textView: NSTextView!

    // MARK: - Paged-mode views (멀티 컨테이너 페이지네이션)
    private var pagedHost: PagedHostView?
    private var pageView: NSTextView?
    private var pagedStorage: NSTextStorage?
    private var pagedLM: NSLayoutManager?
    private var pageContainers: [NSTextContainer] = []
    private var currentPage = 0
    private weak var pageIndicator: NSTextField?
    private var lastPagedSize: NSSize = .zero

    private let pageVMargin: CGFloat = 40

    // MARK: - Init
    init(content: NSAttributedString) {
        self.sourceContent = content
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // MARK: - Layout (scroll mode)
    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textContainer = NSTextContainer(containerSize: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: scrollView.bounds, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 48)

        scrollView.documentView = textView
        view = scrollView
        renderContent()
    }

    // MARK: - Rendering
    private func columnWidthForCurrentSettings() -> CGFloat {
        switch widthMode {
        case .mobile:
            return ReaderMetrics.mobileColumnWidth
        case .book:
            let chars = SettingsManager.shared.readingLineLength
            let size = MemoFont.body.pointSize * scale
            let probeFont = ReaderMetrics.readerFont(family: fontFamily, size: size, traits: [])
            let advance = ("한" as NSString).size(withAttributes: [.font: probeFont]).width
            return ReaderMetrics.columnWidth(charCount: chars, glyphAdvance: advance)
        }
    }

    private func styledContent() -> NSAttributedString {
        ReaderMetrics.styled(sourceContent, scale: scale,
                             font: fontFamily, lineHeightMultiple: lineSpacing,
                             maxImageWidth: columnWidthForCurrentSettings())
    }

    private func renderContent() {
        if let storage = textView.textStorage {
            storage.setAttributedString(styledContent())
        }
        updateColumnInset()
        if pageMode == .paged { rebuildPages() }
    }

    /// 스크롤뷰 폭에 맞춰 좌우 inset 을 갱신해 컬럼을 가운데 둔다(스크롤 모드).
    private func updateColumnInset() {
        let avail = scrollView.contentView.bounds.width
        guard avail > 0 else { return }
        let column = columnWidthForCurrentSettings()
        let side = max(24, (avail - column) / 2)
        if abs(textView.textContainerInset.width - side) > 0.5 {
            textView.textContainerInset = NSSize(width: side, height: 48)
        }
    }

    // MARK: - Public API
    /// 표시할 내용을 교체한다. 문서 전환이면 첫 페이지·맨 위로, 같은 문서의 리로드면
    /// `resetPage: false` 로 읽던 위치를 유지한다(페이지 수가 줄면 클램프).
    func updateContent(_ content: NSAttributedString, resetPage: Bool = true) {
        sourceContent = content
        if resetPage { currentPage = 0 }
        renderContent()
        if resetPage {
            textView.scroll(.zero)
            // 문서 전환 시 사이드바로 옮겨간 포커스를 리더로 되돌린다.
            // 안 그러면 페이징 모드에서 키보드 ←/→ 가 리더로 오지 않아 먹지 않는다.
            if pageMode == .paged { view.window?.makeFirstResponder(self) }
        }
    }

    func setFontScale(_ newScale: CGFloat) {
        scale = min(max(newScale, 0.8), 2.0)
        SettingsManager.shared.readingFontScale = scale
        renderContent()
    }

    func setFont(_ family: SettingsManager.ReadingFont) {
        fontFamily = family
        SettingsManager.shared.readingFont = family
        renderContent()
    }

    func setLineSpacing(_ value: CGFloat) {
        lineSpacing = min(max(value, 1.0), 2.5)
        SettingsManager.shared.readingLineSpacing = lineSpacing
        renderContent()
    }

    var currentLineSpacing: CGFloat { lineSpacing }
    var currentFont: SettingsManager.ReadingFont { fontFamily }

    /// 읽기 단 폭 프리셋 토글. 저장하지 않으며 현재 모드(스크롤/페이징) 양쪽에 반영된다.
    func setWidthMode(_ mode: WidthMode) {
        widthMode = mode
        renderContent()
    }
    var currentWidthMode: WidthMode { widthMode }

    func setPageMode(_ mode: SettingsManager.ReadingPageMode) {
        pageMode = mode
        SettingsManager.shared.readingPageMode = mode
        if mode == .paged {
            installPagedOverlay()
        } else {
            removePagedOverlay()
        }
        updatePageIndicator()
    }

    // MARK: - Paged Overlay
    private func installPagedOverlay() {
        let host: PagedHostView
        if let existing = pagedHost {
            host = existing
        } else {
            host = PagedHostView()
            host.autoresizingMask = [.width, .height]
            host.onPage = { [weak self] down in
                if down { self?.goToNextPage() } else { self?.goToPreviousPage() }
            }
            // 페이지 인디케이터
            let indicator = NSTextField(labelWithString: "")
            indicator.alignment = .center
            indicator.textColor = .secondaryLabelColor
            indicator.font = NSFont.systemFont(ofSize: 11)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                indicator.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10)
            ])
            self.pageIndicator = indicator
            self.pagedHost = host
        }
        host.frame = scrollView.bounds
        scrollView.addSubview(host)
        lastPagedSize = .zero       // 강제 rebuild
        rebuildPages()
        view.window?.makeFirstResponder(self)
    }

    private func removePagedOverlay() {
        pagedHost?.removeFromSuperview()
        pageView?.removeFromSuperview()
        pageView = nil
        pageContainers = []
        pagedLM = nil
        pagedStorage = nil
    }

    /// 페이지마다 NSTextContainer 를 추가해 전체 텍스트를 페이지로 나눈다.
    private func rebuildPages() {
        guard let host = pagedHost else { return }
        let pageH = max(1, host.bounds.height - 2 * pageVMargin)
        let pageW = columnWidthForCurrentSettings()
        let size = NSSize(width: pageW, height: pageH)

        let storage = NSTextStorage(attributedString: styledContent())
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)

        var containers: [NSTextContainer] = []
        while true {
            let c = NSTextContainer(size: size)
            c.lineFragmentPadding = 0
            lm.addTextContainer(c)
            containers.append(c)
            lm.ensureLayout(for: c)
            let laid = lm.glyphRange(for: c)
            if NSMaxRange(laid) >= lm.numberOfGlyphs { break }
            if containers.count >= 9999 { break }   // 안전장치
        }

        pagedStorage = storage
        pagedLM = lm
        pageContainers = containers
        lastPagedSize = host.bounds.size
        currentPage = min(max(0, currentPage), containers.count - 1)
        showCurrentPage()
    }

    private func showCurrentPage() {
        pageView?.removeFromSuperview()
        guard let host = pagedHost, currentPage < pageContainers.count else { return }
        let pageH = max(1, host.bounds.height - 2 * pageVMargin)
        let pageW = columnWidthForCurrentSettings()
        let x = max(0, (host.bounds.width - pageW) / 2)
        let tv = NSTextView(frame: NSRect(x: x, y: pageVMargin, width: pageW, height: pageH),
                            textContainer: pageContainers[currentPage])
        tv.isEditable = false
        tv.isSelectable = false       // 키(←/→)가 VC 로 가도록 선택 비활성
        tv.drawsBackground = false
        host.addSubview(tv, positioned: .below, relativeTo: pageIndicator)
        pageView = tv
        updatePageIndicator()
        NotificationCenter.default.post(name: .readerPageChanged, object: self)
    }

    var pageInfo: (current: Int, total: Int) {
        (currentPage + 1, max(1, pageContainers.count))
    }

    func goToNextPage() {
        guard currentPage < pageContainers.count - 1 else { return }
        currentPage += 1
        showCurrentPage()
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
        showCurrentPage()
    }

    // MARK: - Page Indicator
    @objc private func updatePageIndicator() {
        guard pageMode == .paged else { pageIndicator?.isHidden = true; return }
        let info = pageInfo
        pageIndicator?.isHidden = false
        pageIndicator?.stringValue = "‹ \(info.current) / \(info.total) ›"
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Keyboard Paging
    override func keyDown(with event: NSEvent) {
        guard pageMode == .paged else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 124: goToNextPage()      // →
        case 123: goToPreviousPage()  // ←
        default: super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateColumnInset()
        guard pageMode == .paged, let host = pagedHost else { return }
        host.frame = scrollView.bounds
        // 크기가 바뀐 경우에만 페이지 재분할(비용 큼). 그 외엔 현재 페이지만 다시 배치.
        if host.bounds.size != lastPagedSize {
            rebuildPages()
        } else {
            showCurrentPage()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
        setPageMode(SettingsManager.shared.readingPageMode)
    }
}

extension Notification.Name {
    static let readerPageChanged = Notification.Name("jn_readerPageChanged")
}
