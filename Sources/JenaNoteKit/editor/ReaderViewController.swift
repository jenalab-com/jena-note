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
    private var pageCharRanges: [NSRange] = []
    private var currentPage = 0
    private weak var pageIndicator: NSTextField?
    private var lastPagedSize: NSSize = .zero

    // MARK: - Reading position (ADR-0008)
    /// 읽던 자리의 문자 오프셋 — 표시 설정과 무관한 유일한 좌표.
    /// 페이지 번호·스크롤 y 는 이 값에서 파생되는 표시 결과일 뿐이다.
    private var anchorOffset = 0
    /// 복원이 아직 화면에 반영되지 않았음. 이 동안은 화면에서 위치를 되읽지 않는다.
    private var needsAnchorApply = false
    private var positionSaveTimer: Timer?

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
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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

        // 스크롤 모드에서 읽던 자리를 따라가기 위한 관측 (ADR-0008)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        renderContent()
    }

    @objc private func scrollViewDidScroll(_ note: Notification) {
        guard pageMode == .scroll else { return }
        captureAnchor()
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
        if pageMode == .paged {
            rebuildPages()          // 내부에서 앵커를 되적용한다
        } else {
            applyAnchor()           // 폰트·행간·폭이 바뀌어도 읽던 자리를 유지
        }
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

    // MARK: - Reading Position (ADR-0008)

    /// 지금 화면 맨 위(페이징이면 현재 페이지 첫 글자)의 문자 오프셋.
    /// 이어읽기 저장은 이 값만 쓴다.
    var currentCharacterOffset: Int { anchorOffset }

    /// 현재 조판 중인 원문. 앵커의 문맥 스니펫을 뜨거나 되찾는 기준 텍스트다.
    var contentString: String { sourceContent.string }

    /// 지금 화면에 보이는 문자 범위. "이 화면에 이미 책갈피가 있나"를 판정하는 데 쓴다.
    var visibleCharacterRange: NSRange {
        if pageMode == .paged {
            guard currentPage >= 0, currentPage < pageCharRanges.count else { return NSRange(location: 0, length: 0) }
            return pageCharRanges[currentPage]
        }
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              lm.numberOfGlyphs > 0 else { return NSRange(location: 0, length: 0) }
        var rect = scrollView.contentView.bounds
        rect.origin.y -= textView.textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        return lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// 읽던 자리가 바뀌었을 때 알린다(0.5초 코얼레싱). 저장 책임은 호출자에게 있다.
    /// 리더가 저장소를 직접 알지 않도록 콜백으로 뺐다.
    var onPositionChanged: ((Int) -> Void)?

    /// 대기 중인 위치 알림을 즉시 흘려보낸다(모드 종료·문서 전환 직전용).
    func flushPositionChange() {
        guard positionSaveTimer != nil else { return }
        positionSaveTimer?.invalidate()
        positionSaveTimer = nil
        onPositionChanged?(anchorOffset)
    }

    private func schedulePositionChange() {
        positionSaveTimer?.invalidate()
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.positionSaveTimer = nil
            self.onPositionChanged?(self.anchorOffset)
        }
    }

    /// 저장돼 있던 위치로 되돌린다. 레이아웃이 아직 안 잡혔으면 다음 layout 에서 적용된다.
    func restore(to offset: Int) {
        anchorOffset = max(0, offset)
        needsAnchorApply = true
        applyAnchor()
    }

    /// 화면에 보이는 위치를 읽어 앵커에 반영한다. 복원 대기 중이면 건너뛴다
    /// (아직 옛 위치를 보여주는 화면에서 되읽으면 복원값을 덮어쓰게 된다).
    private func captureAnchor() {
        guard !needsAnchorApply else { return }
        let newOffset = pageMode == .paged ? pagedOffset() : scrollOffset()
        guard newOffset != anchorOffset else { return }
        anchorOffset = newOffset
        schedulePositionChange()
    }

    /// 앵커가 가리키는 자리를 화면에 반영한다. 레이아웃 준비 전이면 표시만 남기고 물러난다.
    private func applyAnchor() {
        guard view.bounds.height > 0 else { return }
        if pageMode == .paged {
            guard !pageContainers.isEmpty else { return }
            currentPage = pageIndex(containing: anchorOffset)
            needsAnchorApply = false
            showCurrentPage()
        } else {
            scrollToOffset(anchorOffset)
            needsAnchorApply = false
        }
    }

    private func pagedOffset() -> Int {
        guard currentPage >= 0, currentPage < pageCharRanges.count else { return 0 }
        return pageCharRanges[currentPage].location
    }

    private func scrollOffset() -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              lm.numberOfGlyphs > 0 else { return 0 }
        // 뷰 좌표 → 텍스트 컨테이너 좌표 (상단 inset 48 만큼 어긋나 있다)
        let topY = scrollView.contentView.bounds.minY - textView.textContainerOrigin.y
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, topY)), in: tc)
        return lm.characterIndexForGlyph(at: glyph)
    }

    private func scrollToOffset(_ offset: Int) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let length = textView.textStorage?.length, length > 0 else { return }
        if offset <= 0 { textView.scroll(.zero); return }
        // 길이 0 범위는 빈 사각형을 주는 경우가 있어 한 글자를 잡아 재본다.
        let loc = min(offset, length - 1)
        lm.ensureLayout(for: tc)
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 1),
                                   actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        let y = rect.minY + textView.textContainerOrigin.y
        textView.scroll(NSPoint(x: 0, y: max(0, y)))
    }

    // MARK: - Public API
    /// 표시할 내용을 교체한다. 문서 전환이면 첫 페이지·맨 위로, 같은 문서의 리로드면
    /// `resetPage: false` 로 읽던 위치를 유지한다(페이지 수가 줄면 클램프).
    func updateContent(_ content: NSAttributedString, resetPage: Bool = true) {
        sourceContent = content
        if resetPage {
            currentPage = 0
            anchorOffset = 0        // 문서 전환 — 이전 문서의 위치를 물려주지 않는다
            needsAnchorApply = false
        }
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
        // 모드를 바꾸기 전에 현재 모드 기준으로 위치를 읽어둔다 — 스크롤↔페이징 왕복에도
        // 읽던 자리가 유지된다.
        captureAnchor()
        pageMode = mode
        SettingsManager.shared.readingPageMode = mode
        if mode == .paged {
            installPagedOverlay()
        } else {
            removePagedOverlay()
            applyAnchor()
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
        var charRanges: [NSRange] = []
        while true {
            let c = NSTextContainer(size: size)
            c.lineFragmentPadding = 0
            lm.addTextContainer(c)
            containers.append(c)
            lm.ensureLayout(for: c)
            let laid = lm.glyphRange(for: c)
            charRanges.append(lm.characterRange(forGlyphRange: laid, actualGlyphRange: nil))
            if NSMaxRange(laid) >= lm.numberOfGlyphs { break }
            if containers.count >= 9999 { break }   // 안전장치
        }

        pagedStorage = storage
        pagedLM = lm
        pageContainers = containers
        pageCharRanges = charRanges
        lastPagedSize = host.bounds.size
        // 페이지 경계가 새로 잡혔으므로 페이지 번호가 아니라 앵커에서 다시 찾는다.
        // 폰트·행간·폭을 바꿔도 읽던 문장이 화면에 남는 이유다.
        currentPage = min(max(0, pageIndex(containing: anchorOffset)), max(0, containers.count - 1))
        needsAnchorApply = false
        showCurrentPage()
    }

    /// 주어진 문자 오프셋이 속한 페이지 인덱스.
    private func pageIndex(containing offset: Int) -> Int {
        guard !pageCharRanges.isEmpty else { return 0 }
        for (i, r) in pageCharRanges.enumerated() where offset < NSMaxRange(r) { return i }
        return pageCharRanges.count - 1
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
        captureAnchor()
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

    deinit {
        NotificationCenter.default.removeObserver(self)
        positionSaveTimer?.invalidate()
    }

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
        guard pageMode == .paged, let host = pagedHost else {
            // 스크롤 모드: 레이아웃이 잡히길 기다리던 복원이 있으면 지금 적용한다.
            if needsAnchorApply { applyAnchor() }
            return
        }
        host.frame = scrollView.bounds
        // 크기가 바뀐 경우에만 페이지 재분할(비용 큼). 그 외엔 현재 페이지만 다시 배치.
        if host.bounds.size != lastPagedSize {
            rebuildPages()
        } else if needsAnchorApply {
            applyAnchor()
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
