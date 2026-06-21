import AppKit

/// 페이징 모드에서 자유 스크롤을 막고 스크롤 제스처를 페이지 넘김으로 변환하는 스크롤뷰.
final class PagingScrollView: NSScrollView {
    var isPaging = false
    /// true = 다음 페이지(아래로), false = 이전 페이지(위로)
    var onPage: ((Bool) -> Void)?
    private var armed = true

    override func scrollWheel(with event: NSEvent) {
        guard isPaging else { super.scrollWheel(with: event); return }
        // 관성(momentum) 구간은 무시 — 한 번의 제스처가 여러 페이지를 넘기지 않게.
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
class ReaderViewController: NSViewController {

    // MARK: - State
    private var sourceContent: NSAttributedString
    private var scale: CGFloat = SettingsManager.shared.readingFontScale
    private var pageMode: SettingsManager.ReadingPageMode = SettingsManager.shared.readingPageMode
    private var fontFamily: SettingsManager.ReadingFont = SettingsManager.shared.readingFont
    private var lineSpacing: CGFloat = SettingsManager.shared.readingLineSpacing

    // MARK: - Views
    private var scrollView: PagingScrollView!
    private var textView: NSTextView!
    private weak var pageIndicator: NSTextField?

    // MARK: - Init
    init(content: NSAttributedString) {
        self.sourceContent = content
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // MARK: - Layout
    override func loadView() {
        scrollView = PagingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.onPage = { [weak self] down in
            if down { self?.goToNextPage() } else { self?.goToPreviousPage() }
        }

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
        // 에디터와 동일한 정석: textView 가 documentView 로서 스크롤뷰 폭을 꽉 채우고
        // (autoresizingMask + widthTracksTextView), 세로로만 늘어나 정상 스크롤된다.
        // 컬럼 가운데 정렬은 좌우 textContainerInset 으로 표현(폭은 viewDidLayout 에서 갱신).
        textView.textContainerInset = NSSize(width: 0, height: 48)

        scrollView.documentView = textView

        // 하단 페이지 인디케이터 (페이징 모드에서만 표시)
        let indicator = NSTextField(labelWithString: "")
        indicator.alignment = .center
        indicator.textColor = .secondaryLabelColor
        indicator.font = NSFont.systemFont(ofSize: 11)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            indicator.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -8)
        ])
        self.pageIndicator = indicator
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatePageIndicator),
            name: .readerPageChanged, object: self)

        view = scrollView
        renderContent()
    }

    // MARK: - Rendering
    private func columnWidthForCurrentSettings() -> CGFloat {
        let chars = SettingsManager.shared.readingLineLength
        // 본문 글리프 advance 실측 (현재 폰트·배율 기준)
        let size = MemoFont.body.pointSize * scale
        let probeFont = ReaderMetrics.readerFont(family: fontFamily, size: size, traits: [])
        let advance = ("한" as NSString).size(withAttributes: [.font: probeFont]).width
        return ReaderMetrics.columnWidth(charCount: chars, glyphAdvance: advance)
    }

    private func renderContent() {
        guard let storage = textView.textStorage else { return }
        let display = ReaderMetrics.styled(sourceContent, scale: scale,
                                           font: fontFamily, lineHeightMultiple: lineSpacing)
        storage.setAttributedString(display)
        updateColumnInset()
        invalidatePaging()
        if pageMode == .paged { scrollToCurrentPage() }
    }

    /// 스크롤뷰 폭에 맞춰 좌우 inset 을 갱신해 컬럼을 가운데 둔다.
    private func updateColumnInset() {
        let avail = scrollView.contentView.bounds.width
        guard avail > 0 else { return }
        let column = columnWidthForCurrentSettings()
        let side = max(24, (avail - column) / 2)
        if abs(textView.textContainerInset.width - side) > 0.5 {
            textView.textContainerInset = NSSize(width: side, height: 48)
            invalidatePaging()
        }
    }

    // MARK: - Public API
    func updateContent(_ content: NSAttributedString) {
        sourceContent = content
        currentPage = 0
        renderContent()
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

    func setPageMode(_ mode: SettingsManager.ReadingPageMode) {
        pageMode = mode
        SettingsManager.shared.readingPageMode = mode
        let paged = (mode == .paged)
        scrollView.isPaging = paged
        scrollView.hasVerticalScroller = !paged
        scrollView.verticalScrollElasticity = paged ? .none : .allowed
        if paged {
            currentPage = 0
            invalidatePaging()
            scrollToCurrentPage()
        } else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updatePageIndicator()
    }

    // MARK: - Line-aligned Paging
    private var currentPage: Int = 0
    private var pageStartsCache: [CGFloat]?

    private func invalidatePaging() { pageStartsCache = nil }

    /// 각 페이지의 시작 y(documentView 좌표). 페이지 경계를 실제 줄 경계에 맞춰
    /// 줄이 잘리지 않게 한다. 페이지 하단에 걸치는 줄은 통째로 다음 페이지로 넘긴다.
    private var pageStarts: [CGFloat] {
        if let cached = pageStartsCache { return cached }
        let starts = computePageStarts()
        pageStartsCache = starts
        return starts
    }

    private func computePageStarts() -> [CGFloat] {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return [0] }
        lm.ensureLayout(for: tc)
        let inset = textView.textContainerInset.height
        let visible = max(1, scrollView.contentView.bounds.height)
        let totalHeight = lm.usedRect(for: tc).height
        if totalHeight <= visible { return [0] }

        var starts: [CGFloat] = [0]        // documentView 좌표 (inset 포함)
        var pageTop: CGFloat = 0           // container 좌표 (inset 제외)

        // 안전장치: 최악의 경우라도 줄 수 이상 반복하지 않게 상한을 둔다.
        let maxPages = Int(ceil(totalHeight / max(1, lm.defaultLineHeight(for: MemoFont.body)))) + 2
        var guardCount = 0

        while pageTop + visible < totalHeight && guardCount < maxPages {
            guardCount += 1
            let probeY = min(pageTop + visible, totalHeight - 1)
            let glyphIdx = lm.glyphIndex(for: NSPoint(x: 2, y: probeY), in: tc)
            var lineRange = NSRange()
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &lineRange)
            var nextTop = lineRect.minY
            // 페이지 하단 줄이 페이지 top 과 같으면(한 줄이 visible 보다 큰 극단) 강제 전진.
            if nextTop <= pageTop + 1 {
                nextTop = pageTop + visible
            }
            starts.append(nextTop + inset)
            pageTop = nextTop
        }
        return starts
    }

    var pageInfo: (current: Int, total: Int) { (currentPage + 1, pageStarts.count) }

    func goToNextPage() {
        guard currentPage < pageStarts.count - 1 else { return }
        currentPage += 1
        scrollToCurrentPage()
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
        scrollToCurrentPage()
    }

    private func scrollToCurrentPage() {
        let starts = pageStarts
        guard !starts.isEmpty else { return }
        currentPage = min(max(0, currentPage), starts.count - 1)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: starts[currentPage]))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: .readerPageChanged, object: self)
        updatePageIndicator()
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
        // 폭/높이가 바뀌면 컬럼 inset·페이지 분할을 다시 계산한다.
        updateColumnInset()
        invalidatePaging()
        guard pageMode == .paged else { return }
        scrollToCurrentPage()  // currentPage clamp 은 scrollToCurrentPage 내부에서 처리
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
        // 영속화된 page mode 를 레이아웃 완료(non-zero bounds) 후 한 번 적용.
        setPageMode(SettingsManager.shared.readingPageMode)
    }
}

extension Notification.Name {
    static let readerPageChanged = Notification.Name("jn_readerPageChanged")
}
