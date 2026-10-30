import AppKit

/// 페이징 모드 호스트 — 멀티 컨테이너 페이지뷰를 담는 불투명 오버레이.
/// flipped 로 페이지를 상단 기준 배치하고, 스크롤 제스처를 페이지 넘김으로 변환한다.
final class PagedHostView: NSView {
    override var isFlipped: Bool { true }
    var onPage: ((Bool) -> Void)?
    private var armed = true

    override func draw(_ dirtyRect: NSRect) {
        PaperBackground.currentColor.setFill()
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

/// 본문 방향키는 NSTextView의 커서 이동에 맡기고 Page Up/Down만 페이지를 넘긴다.
final class PageTextView: NSTextView {
    var onPageKey: ((Bool) -> Void)?
    var onInputFinished: (() -> Void)?
    var onFind: (() -> Void)?

    override func performTextFinderAction(_ sender: Any?) { onFind?() }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.keyCode == 121 || event.keyCode == 116 {
            onPageKey?(event.keyCode == 121)
            return
        }
        super.keyDown(with: event)
        onInputFinished?()
    }

    override func unmarkText() {
        super.unmarkText()
        onInputFinished?()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        onInputFinished?()
    }

    override func autoscroll(with event: NSEvent) -> Bool { false }
}

/// 편집 가능한 페이징 조판. 원본 서식과 표시 서식을 분리하고 변경 범위만 문서에 전달한다.
/// 조판은 현재 펼침면을 먼저 계산하며 뒤쪽 페이지는 이벤트 사이에 나눠 계산한다.
class ReaderViewController: NSViewController, NSTextStorageDelegate, NSTextViewDelegate, ReadingPositionProviding {

    typealias WidthMode = ReaderMetrics.WidthMode

    // MARK: - State
    private var sourceContent: NSMutableAttributedString
    private var scale: CGFloat = SettingsManager.shared.readingFontScale
    private var pageMode: SettingsManager.ReadingPageMode = SettingsManager.shared.readingPageMode
    private var fontFamily: SettingsManager.ReadingFont = SettingsManager.shared.readingFont
    private var fontWeight: SettingsManager.ReadingWeight = SettingsManager.shared.readingWeight
    private var lineSpacing: CGFloat = SettingsManager.shared.readingLineSpacing
    private var widthMode: WidthMode = .book
    /// 페이지 좌·우 여백(pt). 치수자가 바꾸며 설정에 저장된다. 페이지 박스는 그대로 두고
    /// 그 안의 글 영역만 줄인다(워드와 같은 뜻).
    private var marginLeft: CGFloat = SettingsManager.shared.readingPageMarginLeft
    private var marginRight: CGFloat = SettingsManager.shared.readingPageMarginRight

    // MARK: - Scroll-mode views
    private var scrollView: NSScrollView!
    private var textView: NSTextView!

    // MARK: - Paged-mode views (멀티 컨테이너 페이지네이션)
    private var pagedHost: PagedHostView?
    /// 지금 화면에 얹힌 페이지 뷰들 — 낱쪽이면 1개, 펼침면이면 좌·우 2개.
    private var pageViews: [PageTextView] = []
    /// 페이지마다 하나씩 얹는 치수자 — 낱쪽이면 1개, 펼침면이면 2개.
    private var rulerViews: [PageRulerView] = []
    private var paginator: IncrementalPaginator?
    private var pagedStorage: NSTextStorage? { paginator?.storage }
    private var pageContainers: [NSTextContainer] { paginator?.containers ?? [] }
    private var pageCharRanges: [NSRange] { paginator?.ranges ?? [] }
    private var paginationWork: DispatchWorkItem?
    private var editRefreshWork: DispatchWorkItem?
    private var isApplyingContent = false
    private var isRefreshing = false
    private var hasPendingEdit = false
    private var deferredRender = false
    /// 문서 소유 Undo에 전달할 원본 서식의 변경 범위.
    var onContentEdit: ((NSRange, NSAttributedString) -> Void)?
    var documentUndoManager: (() -> UndoManager?)?
    private(set) var isPaginationComplete = false
    var paginationCalculationCount: Int { paginator?.computedPageCount ?? 0 }
    weak var formattingTarget: EditorViewController?
    private var lastSelection: NSRange?
    var selectedTextRange: NSRange? {
        if let active = activePageTextView { return active.selectedRange() }
        if let selection = lastSelection, rangeIsVisible(selection) { return selection }
        return NSRange(location: visibleCharacterRange.location, length: 0)
    }

    func selectTextRange(_ range: NSRange) {
        guard NSMaxRange(range) <= sourceContent.length else { return }
        paginator?.ensureCharacter(range.location)
        currentPage = pageIndex(containing: range.location)
        showCurrentSpread()
        lastSelection = range
        selectInVisiblePage(range)
    }

    func setTypingAttributes(_ attributes: [NSAttributedString.Key: Any]) {
        activePageTextView?.typingAttributes = attributes
    }

    var visiblePageTextViews: [PageTextView] { pageViews }
    var visiblePageRulers: [PageRulerView] { rulerViews }

    private var currentPage = 0
    private weak var pageIndicator: NSTextField?
    /// 마지막으로 페이지를 나눈 컨테이너 크기(글 영역 폭 × 페이지 높이).
    /// 페이지 경계는 이 둘에만 의존하므로, 창 폭만 바뀐 리사이즈에서는 재분할하지 않는다.
    private var lastTextBoxSize: NSSize = .zero
    /// 지금 좌·우 두 페이지를 나란히 보여주는 중인지. 창 폭에서 파생될 뿐 저장하지 않는다.
    private var isSpread = false

    // MARK: - Reading position (ADR-0008)
    /// 읽던 자리의 문자 오프셋 — 표시 설정과 무관한 유일한 좌표.
    /// 페이지 번호·스크롤 y 는 이 값에서 파생되는 표시 결과일 뿐이다.
    private var anchorOffset = 0
    /// 복원이 아직 화면에 반영되지 않았음. 이 동안은 화면에서 위치를 되읽지 않는다.
    private var needsAnchorApply = false
    private var positionSaveTimer: Timer?

    private let pageVMargin: CGFloat = 40
    /// 치수자의 세로 자리 — 페이지 위 여백(pageVMargin) 안에 든다.
    private let rulerTop: CGFloat = 12

    // MARK: - Init
    init(content: NSAttributedString) {
        self.sourceContent = NSMutableAttributedString(attributedString: content)
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
        NotificationCenter.default.addObserver(self, selector: #selector(paperSizeChanged), name: DocumentPaperSize.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyPaperBackground), name: PaperBackground.changed, object: nil)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = PaperBackground.currentColor

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
    @objc private func applyPaperBackground() {
        scrollView.backgroundColor = PaperBackground.currentColor
        func redraw(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(redraw) }
        redraw(view)
    }

    @objc private func paperSizeChanged() {
        widthMode = .book
        if let host = pagedHost { layoutPaperHost(host) }
        renderContent()
    }

    private func layoutPaperHost(_ host: NSView) {
        defer {
            pageIndicator?.frame = NSRect(x: 0, y: host.bounds.height - 26, width: host.bounds.width, height: 18)
        }
        host.frame = scrollView.bounds
        guard widthMode == .book, let paper = DocumentPaperSize.selected.points else {
            host.bounds = NSRect(origin: .zero, size: host.frame.size)
            return
        }
        let scale = min(1, host.frame.width / (paper.width + 48), host.frame.height / (paper.height + 2 * pageVMargin))
        guard scale > 0 else { return }
        host.bounds = NSRect(origin: .zero, size: NSSize(width: host.frame.width / scale, height: host.frame.height / scale))
    }

    private func columnWidthForCurrentSettings() -> CGFloat {
        if widthMode == .book, let paper = DocumentPaperSize.selected.points { return paper.width }
        return ReaderMetrics.columnWidth(mode: widthMode, scale: scale, family: fontFamily,
                                  charCount: SettingsManager.shared.readingLineLength,
                                  pageWidthOverride: SettingsManager.shared.readingPageWidth)
    }

    /// 지금 페이지 폭에 맞게 잘라낸 좌·우 여백.
    private func pageMargins() -> (left: CGFloat, right: CGFloat) {
        ReaderMetrics.clampedMargins(left: marginLeft, right: marginRight,
                                     pageWidth: columnWidthForCurrentSettings())
    }

    /// 페이지 폭에서 여백을 뺀 글 영역 폭.
    private func textWidthForCurrentSettings() -> CGFloat {
        ReaderMetrics.textWidth(pageWidth: columnWidthForCurrentSettings(),
                                left: marginLeft, right: marginRight)
    }

    private func styledContent() -> NSAttributedString {
        ReaderMetrics.styled(sourceContent, scale: scale,
                             font: fontFamily, lineHeightMultiple: lineSpacing,
                             weight: fontWeight,
                             maxImageWidth: textWidthForCurrentSettings())
    }

    private func renderContent() {
        if pageViews.contains(where: { $0.hasMarkedText() }) {
            deferredRender = true
            return
        }
        deferredRender = false
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
        let column = textWidthForCurrentSettings()
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
    /// 펼침면이면 좌·우 두 페이지의 합집합이다 — 오른쪽 면의 책갈피를 놓치면 ⌘D 가
    /// 같은 화면에 책갈피를 하나 더 찍는다.
    var visibleCharacterRange: NSRange {
        if pageMode == .paged {
            let indices = visiblePageIndices().filter { $0 < pageCharRanges.count }
            guard let first = indices.first, let last = indices.last else {
                return NSRange(location: 0, length: 0)
            }
            let start = pageCharRanges[first].location
            let end = NSMaxRange(pageCharRanges[last])
            return NSRange(location: start, length: max(0, end - start))
        }
        return ScrollReadingPosition.visibleRange(textView: textView, scrollView: scrollView)
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
            paginator?.ensureCharacter(anchorOffset)
            guard !pageCharRanges.isEmpty else { return }
            currentPage = pageIndex(containing: anchorOffset)
            needsAnchorApply = false
            showCurrentSpread()
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
        ScrollReadingPosition.offset(textView: textView, scrollView: scrollView)
    }

    private func scrollToOffset(_ offset: Int) {
        ScrollReadingPosition.scroll(textView: textView, to: offset)
    }

    // MARK: - Public API
    /// 표시할 내용을 교체한다. 문서 전환이면 첫 페이지·맨 위로, 같은 문서의 리로드면
    /// `resetPage: false` 로 읽던 위치를 유지한다(페이지 수가 줄면 클램프).
    func updateContent(_ content: NSAttributedString, resetPage: Bool = true) {
        finishComposition()
        cancelPaginationWork()
        hasPendingEdit = false
        sourceContent = NSMutableAttributedString(attributedString: content)
        if resetPage {
            lastSelection = nil
            currentPage = 0
            anchorOffset = 0        // 문서 전환 — 이전 문서의 위치를 물려주지 않는다
            needsAnchorApply = false
        }
        renderContent()
        if resetPage {
            textView.scroll(.zero)
            // 문서 전환 시 사이드바로 옮겨간 포커스를 리더로 되돌린다.
            // 안 그러면 페이징 모드에서 키보드 ←/→ 가 리더로 오지 않아 먹지 않는다.
            if pageMode == .paged { focusPage() }
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

    func setWeight(_ weight: SettingsManager.ReadingWeight) {
        fontWeight = weight
        SettingsManager.shared.readingWeight = weight
        renderContent()
    }

    func setLineSpacing(_ value: CGFloat) {
        lineSpacing = min(max(value, 1.0), 2.5)
        SettingsManager.shared.readingLineSpacing = lineSpacing
        renderContent()
    }

    var currentLineSpacing: CGFloat { lineSpacing }
    var currentFont: SettingsManager.ReadingFont { fontFamily }
    var currentWeight: SettingsManager.ReadingWeight { fontWeight }

    /// 읽기 단 폭 프리셋 토글. 저장하지 않으며 현재 모드(스크롤/페이징) 양쪽에 반영된다.
    func setWidthMode(_ mode: WidthMode) {
        widthMode = mode
        if let host = pagedHost { layoutPaperHost(host) }
        renderContent()
    }
    var currentWidthMode: WidthMode { widthMode }

    /// 치수자로 정한 페이지 좌·우 여백을 적용하고 저장한다. 글 영역 폭이 바뀌므로
    /// 재조판한다(폭 프리셋 전환과 같은 경로).
    func setPageMargins(left: CGFloat, right: CGFloat) {
        setPageLayout(pageWidth: columnWidthForCurrentSettings(), left: left, right: right)
    }

    /// 치수자가 정한 페이지 폭과 여백을 함께 적용한다. 폭은 "책" 모드에서만 저장된다 —
    /// 모바일은 고정 프리셋이라 치수자가 넓히지 못한다.
    func setPageLayout(pageWidth: CGFloat, left: CGFloat, right: CGFloat) {
        let s = SettingsManager.shared
        var widthChanged = false
        if widthMode == .book, DocumentPaperSize.selected == .automatic, abs(pageWidth - columnWidthForCurrentSettings()) > 0.5 {
            s.readingPageWidth = pageWidth
            widthChanged = true
        }
        let m = ReaderMetrics.clampedMargins(left: left, right: right,
                                             pageWidth: columnWidthForCurrentSettings())
        guard widthChanged || m.left != marginLeft || m.right != marginRight else { return }
        marginLeft = m.left
        marginRight = m.right
        s.readingPageMarginLeft = m.left
        s.readingPageMarginRight = m.right
        renderContent()
    }

    /// 치수자 더블클릭 — 넓힌 폭과 여백을 기본(글자수 폭·여백 0)으로 되돌린다.
    func resetPageLayout() {
        if DocumentPaperSize.selected == .automatic { SettingsManager.shared.readingPageWidth = 0 }
        marginLeft = 0
        marginRight = 0
        SettingsManager.shared.readingPageMarginLeft = 0
        SettingsManager.shared.readingPageMarginRight = 0
        renderContent()
    }
    var currentPageMargins: (left: CGFloat, right: CGFloat) { pageMargins() }
    var currentPageWidth: CGFloat { columnWidthForCurrentSettings() }

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
            indicator.translatesAutoresizingMaskIntoConstraints = true
            host.addSubview(indicator)
            self.pageIndicator = indicator
            self.pagedHost = host
        }
        layoutPaperHost(host)
        scrollView.addSubview(host)
        lastTextBoxSize = .zero     // 강제 rebuild
        rebuildPages()
        focusPage()
    }

    private func removePagedOverlay() {
        tearDownPageViews()     // 텍스트 시스템을 놓기 전에 페이지뷰부터 떼어낸다
        pagedHost?.removeFromSuperview()
        cancelPaginationWork()
        pagedStorage?.delegate = nil
        paginator = nil
    }

    /// 페이지 뷰를 버리는 화면 경로가 공통으로 쓰는 문
    /// (`showCurrentSpread`·`rebuildPages`·`removePagedOverlay`).
    ///
    /// 포커스를 **뷰가 살아 있는 지금** 회수한 뒤 떼어낸다 — resign 이 해제 뒤로 미뤄지면
    /// 죽은 뷰를 메시징하게 된다 (2026-08-10 크래시).
    private func tearDownPageViews() {
        guard !pageViews.isEmpty else { return }
        if readerHasFocus() { view.window?.makeFirstResponder(self) }
        discardPageViews()
    }

    /// 페이지뷰를 화면에서 걷어내고 **텍스트 시스템에서 떼어낸다.**
    ///
    /// NSLayoutManager 는 자기 텍스트뷰를 비소유(`assign`) 포인터로 기억한다
    /// (`textViewForBeginningOfSelection` 등 — AppKit 헤더에 그렇게 선언돼 있다).
    /// 그래서 페이지뷰를 그냥 버리면, 해제된 뒤에도 레이아웃 매니저 안에 죽은 포인터가
    /// 남는다. 다음에 포커스가 옮겨가는 순간(= 아무 데나 클릭) 살아 있는 페이지뷰의
    /// `-[NSTextView updateRuler]` 가 그 죽은 포인터에 `enclosingScrollView` 를 보내며
    /// 앱이 통째로 죽는다(2026-08-08 크래시).
    ///
    /// 컨테이너의 `textView` 를 비우면 AppKit 이 레이아웃 매니저의 캐시까지 같이 정리한다.
    /// 컨테이너가 살아 있는 동안 불러야 하므로, 조판을 새로 짜기 **전에** 부른다.
    /// 포커스는 건드리지 않으므로 `deinit` 에서도 안전하다.
    private func discardPageViews() {
        for tv in pageViews {
            tv.removeFromSuperview()
            tv.textContainer?.textView = nil
        }
        pageViews = []
    }

    /// 페이지 한 장의 크기(치수자가 보여주는 폭 × 페이지 높이). 배치의 기준이다.
    private func pageBoxSize() -> NSSize {
        guard let host = pagedHost else { return .zero }
        return NSSize(width: columnWidthForCurrentSettings(),
                      height: widthMode == .book ? (DocumentPaperSize.selected.points?.height ?? max(1, host.bounds.height - 2 * pageVMargin)) : max(1, host.bounds.height - 2 * pageVMargin))
    }

    /// 페이지 컨테이너 한 장의 크기 = 페이지에서 좌·우 여백을 뺀 글 영역.
    /// 페이지 경계는 오직 이 크기에서 나온다 (창 폭은 배치에만 쓰인다 — 그래서 가로
    /// 리사이즈는 재분할을 부르지 않는다).
    private func textBoxSize() -> NSSize {
        guard pagedHost != nil else { return .zero }
        return NSSize(width: textWidthForCurrentSettings(), height: pageBoxSize().height)
    }

    /// 표시 설정이 바뀔 때만 조판 네트워크를 교체한다. 타이핑은 기존 네트워크를 쓴다.
    private func rebuildPages() {
        guard let host = pagedHost, host.bounds.height > 2 * pageVMargin,
              host.bounds.width > 0 else { return }
        if pageViews.contains(where: { $0.hasMarkedText() }) {
            deferredRender = true
            return
        }
        cancelPaginationWork()
        let hadFocus = readerHasFocus()
        let selection = activePageTextView?.selectedRange()
        tearDownPageViews()
        pagedStorage?.delegate = nil
        let storage = NSTextStorage(attributedString: styledContent())
        paginator = IncrementalPaginator(storage: storage, pageSize: textBoxSize())
        let targetOffset = hadFocus ? (selection?.location ?? anchorOffset) : anchorOffset
        paginator?.ensureCharacter(targetOffset)
        currentPage = pageIndex(containing: targetOffset)
        updateSpreadState()
        ensureVisiblePages()
        storage.delegate = self
        lastTextBoxSize = textBoxSize()
        needsAnchorApply = false
        showCurrentSpread(restoringFocus: hadFocus)
        if let selection = selection, NSMaxRange(selection) <= storage.length, hadFocus {
            selectInVisiblePage(selection)
        }
        schedulePagination()
    }

    private func pageIndex(containing offset: Int) -> Int {
        paginator?.pageIndex(containing: offset) ?? 0
    }

    private func ensureVisiblePages() {
        paginator?.ensurePage(currentPage + (isSpread ? 1 : 0))
        currentPage = min(currentPage, max(0, pageCharRanges.count - 1))
        isPaginationComplete = paginator?.isComplete ?? true
    }

    private func cancelPaginationWork() {
        paginationWork?.cancel()
        paginationWork = nil
        editRefreshWork?.cancel()
        editRefreshWork = nil
    }

    private func schedulePagination(after delay: TimeInterval = 0.03) {
        paginationWork?.cancel()
        guard let paginator = paginator, !paginator.isComplete, !paginator.isBlocked else {
            isPaginationComplete = paginator?.isComplete ?? true
            updatePageIndicator()
            return
        }
        isPaginationComplete = false
        let work = DispatchWorkItem { [weak self, weak paginator] in
            guard let self = self, let paginator = paginator, self.paginator === paginator else { return }
            if self.pageViews.contains(where: { $0.hasMarkedText() }) {
                self.schedulePagination(after: 0.1)
                return
            }
            paginator.advance(maxPages: 2)
            self.isPaginationComplete = paginator.isComplete
            self.updatePageIndicator()
            // 새 다음 페이지가 계산됐을 때 필요한 표시 뷰만 추가한다.
            self.showCurrentSpread()
            self.schedulePagination()
        }
        paginationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 지금 창 폭에서 펼침면이 가능한지 다시 판정한다. 창 폭에서 파생될 뿐이라
    /// 저장하지 않으며, 배치 직전에 매번 되묻는다.
    private func updateSpreadState() {
        guard let host = pagedHost else { isSpread = false; return }
        isSpread = ReaderMetrics.fitsSpread(hostWidth: host.bounds.width,
                                            columnWidth: columnWidthForCurrentSettings(),
                                            currentlySpread: isSpread)
    }

    /// 지금 화면에 얹을 페이지 인덱스 — 낱쪽이면 1개, 펼침면이면 좌·우 2개.
    /// 마지막이 홀수 장이면 오른쪽 면은 비운다.
    private func visiblePageIndices() -> [Int] {
        guard currentPage >= 0, currentPage < pageCharRanges.count else { return [] }
        guard isSpread, currentPage + 1 < pageCharRanges.count else { return [currentPage] }
        return [currentPage, currentPage + 1]
    }

    /// 현재 펼침면(또는 낱쪽)을 호스트 가운데에 배치한다.
    ///
    /// `restoringFocus` 는 "리더가 포커스를 쥐고 있었는가" — 호출자가 이미 페이지뷰를
    /// 떼어낸 뒤라면(rebuildPages) 여기서는 되읽을 수 없으므로 넘겨받는다.
    private func showCurrentSpread(restoringFocus: Bool? = nil) {
        guard !isRefreshing, let host = pagedHost else { return }
        // 입력기가 사용하는 뷰를 교체하면 조합 중인 글자가 유실된다.
        guard !pageViews.contains(where: { $0.hasMarkedText() }) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let hadFocus = restoringFocus ?? readerHasFocus()
        let oldSelection = activePageTextView?.selectedRange()
        updateSpreadState()
        if isSpread { currentPage = ReaderMetrics.spreadStart(page: currentPage) }
        ensureVisiblePages()
        let indices = visiblePageIndices()
        guard !indices.isEmpty else { return }
        let desired = indices.map { pageContainers[$0] }
        let removed = pageViews.filter { tv in !desired.contains { $0 === tv.textContainer } }
        if removed.contains(where: { $0 === view.window?.firstResponder }) {
            view.window?.makeFirstResponder(self)
        }
        for tv in removed {
            tv.delegate = nil
            tv.removeFromSuperview()
            tv.textContainer?.textView = nil
        }
        let retained = pageViews.filter { tv in desired.contains { $0 === tv.textContainer } }
        let box = pageBoxSize()
        let textBox = textBoxSize()
        let margins = pageMargins()
        let totalW = CGFloat(indices.count) * box.width + CGFloat(indices.count - 1) * ReaderMetrics.spreadGutter
        var x = max(0, (host.bounds.width - totalW) / 2)
        var pageXs: [CGFloat] = []
        pageViews = indices.map { index in
            let container = pageContainers[index]
            let tv = retained.first { $0.textContainer === container }
                ?? makePageTextView(container: container)
            // 페이지는 x 에서 시작하고, 글은 왼쪽 여백만큼 들어간 자리에서 시작한다.
            tv.frame = NSRect(x: x + margins.left, y: pageVMargin,
                              width: textBox.width, height: textBox.height)
            if tv.superview == nil { host.addSubview(tv, positioned: .below, relativeTo: pageIndicator) }
            pageXs.append(x)
            x += box.width + ReaderMetrics.spreadGutter
            return tv
        }
        layoutRulers(pageXs: pageXs, pageWidth: box.width, margins: margins, in: host)
        if hadFocus, !pageViews.contains(where: { $0 === view.window?.firstResponder }) {
            if let selection = oldSelection, rangeIsVisible(selection) {
                selectInVisiblePage(selection)
            } else {
                focusPage()
                pageViews.first?.setSelectedRange(NSRange(location: pagedOffset(), length: 0))
            }
        }
        captureAnchor()
        updatePageIndicator()
        NotificationCenter.default.post(name: .readerPageChanged, object: self)
    }

    /// 페이지 수만큼 치수자를 맞춰 두고 각 페이지 위에 얹는다. 치수자끼리는 같은 여백을
    /// 보여주며, 한쪽을 끌면 나머지도 따라 움직인다(펼침면은 한 장의 책이다).
    private func layoutRulers(pageXs: [CGFloat], pageWidth: CGFloat,
                              margins: (left: CGFloat, right: CGFloat), in host: NSView) {
        while rulerViews.count > pageXs.count {
            rulerViews.removeLast().removeFromSuperview()
        }
        while rulerViews.count < pageXs.count {
            let ruler = PageRulerView(frame: .zero)
            ruler.onMarginsChanging = { [weak self, weak ruler] l, r in
                self?.rulerViews.filter { $0 !== ruler }.forEach { $0.setMargins(left: l, right: r) }
            }
            ruler.onCommitted = { [weak self] w, l, r in
                self?.setPageLayout(pageWidth: w, left: l, right: r)
            }
            ruler.onReset = { [weak self] in self?.resetPageLayout() }
            host.addSubview(ruler, positioned: .below, relativeTo: pageIndicator)
            rulerViews.append(ruler)
        }
        let maxWidth = ReaderMetrics.maxPageWidth(hostWidth: host.bounds.width, spread: pageXs.count == 2)
        for (ruler, px) in zip(rulerViews, pageXs) {
            ruler.frame = NSRect(x: px, y: rulerTop, width: pageWidth, height: PageRulerView.height)
            ruler.usesPaperOrigin = widthMode == .book && DocumentPaperSize.selected != .automatic
            ruler.canGrowPage = widthMode == .book && DocumentPaperSize.selected == .automatic
            ruler.maxPageWidth = maxWidth
            ruler.setMargins(left: margins.left, right: margins.right)
        }
    }

    private func makePageTextView(container: NSTextContainer) -> PageTextView {
        let tv = PageTextView(frame: NSRect(origin: .zero, size: textBoxSize()), textContainer: container)
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = true
        // Undo actions target the document, never a transient page NSTextView.
        tv.allowsUndo = false
        tv.drawsBackground = false
        tv.usesRuler = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.delegate = self
        tv.onPageKey = { [weak self] next in
            if next { self?.goToNextPage() } else { self?.goToPreviousPage() }
        }
        tv.onFind = { [weak self] in self?.formattingTarget?.showFindBar(nil) }
        tv.onInputFinished = { [weak self] in self?.scheduleEditRefresh() }
        syncTypingAttributes(tv)
        return tv
    }

    private var activePageTextView: PageTextView? {
        guard let focused = view.window?.firstResponder as? PageTextView,
              pageViews.contains(where: { $0 === focused }) else { return nil }
        return focused
    }

    private func rangeIsVisible(_ range: NSRange) -> Bool {
        let visible = visibleCharacterRange
        return range.location >= visible.location && range.location <= NSMaxRange(visible)
    }

    private func selectInVisiblePage(_ range: NSRange) {
        let index = pageIndex(containing: range.location)
        guard index < pageContainers.count else { return }
        let target = pageViews.first { $0.textContainer === pageContainers[index] } ?? pageViews.first
        target?.setSelectedRange(range)
        if let target = target { view.window?.makeFirstResponder(target) }
    }

    private func syncTypingAttributes(_ tv: NSTextView) {
        var attrs: [NSAttributedString.Key: Any]
        if let storage = pagedStorage, storage.length > 0 {
            let selection = tv.selectedRange()
            let position = selection.length > 0 ? selection.location : selection.location - 1
            let offset = min(max(0, position), storage.length - 1)
            attrs = storage.attributes(at: offset, effectiveRange: nil)
        } else {
            let base = NSAttributedString(string: " ", attributes: [
                .font: MemoFont.body, .foregroundColor: NSColor.labelColor,
                .mdBlockType: "body", .paragraphStyle: FormatCommands.bodyParagraphStyle()
            ])
            attrs = ReaderMetrics.styled(base, scale: scale, font: fontFamily,
                                        lineHeightMultiple: lineSpacing, weight: fontWeight)
                .attributes(at: 0, effectiveRange: nil)
        }
        // Keep original paragraph attributes: new text inherits its actual paragraph's style.
        tv.typingAttributes = attrs
    }

    // MARK: - Incremental editing

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard !isApplyingContent, textStorage === pagedStorage,
              editedRange.location != NSNotFound else { return }
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        guard oldRange.length >= 0, NSMaxRange(oldRange) <= sourceContent.length,
              NSMaxRange(editedRange) <= textStorage.length else { return }
        let replacement = ReaderMetrics.unstyled(textStorage.attributedSubstring(from: editedRange))
        let changed = !sourceContent.attributedSubstring(from: oldRange).isEqual(to: replacement)
        guard changed || editedMask.contains(.editedCharacters) else { return }
        sourceContent.replaceCharacters(in: oldRange, with: replacement)
        anchorOffset = ReadingAnchor.offsetAfterEdit(anchorOffset, range: oldRange,
                                                     replacementLength: replacement.length)
        paginator?.invalidate(editedRange: editedRange)
        hasPendingEdit = true
        isPaginationComplete = false
        paginationWork?.cancel()
        if changed { onContentEdit?(oldRange, replacement) }
        // Layout is forbidden during NSTextStorage's editing transaction.
        scheduleEditRefresh()
    }

    func textDidChange(_ notification: Notification) {
        scheduleEditRefresh()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isRefreshing, let tv = notification.object as? PageTextView else { return }
        lastSelection = tv.selectedRange()
        if !tv.hasMarkedText() { syncTypingAttributes(tv) }
        formattingTarget?.updateToolbarState()
        scheduleEditRefresh()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { documentUndoManager?() }

    func finishComposition() {
        isApplyingContent = true
        for tv in pageViews where tv.hasMarkedText() {
            tv.unmarkText()
            tv.inputContext?.discardMarkedText()
        }
        isApplyingContent = false
    }

    @objc func undo() {
        finishComposition()
        documentUndoManager?()?.undo()
    }

    @objc func redo() {
        finishComposition()
        documentUndoManager?()?.redo()
    }

    /// Undo/Redo from the document uses the same persistent TextKit network.
    func applyDocumentEdit(in range: NSRange, replacement: NSAttributedString) {
        guard NSMaxRange(range) <= sourceContent.length, let storage = pagedStorage else { return }
        finishComposition()
        sourceContent.replaceCharacters(in: range, with: replacement)
        let styled = ReaderMetrics.styled(replacement, scale: scale, font: fontFamily,
                                         lineHeightMultiple: lineSpacing, weight: fontWeight,
                                         maxImageWidth: textWidthForCurrentSettings())
        isApplyingContent = true
        storage.replaceCharacters(in: range, with: styled)
        isApplyingContent = false
        paginator?.invalidate(editedRange: NSRange(location: range.location, length: replacement.length))
        anchorOffset = min(range.location, sourceContent.length)
        hasPendingEdit = true
        paginator?.ensureCharacter(range.location + replacement.length)
        currentPage = pageIndex(containing: range.location + replacement.length)
        showCurrentSpread()
        selectInVisiblePage(NSRange(location: range.location + replacement.length, length: 0))
        scheduleEditRefresh()
    }

    private func scheduleEditRefresh() {
        guard !isRefreshing, pageMode == .paged else { return }
        editRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshAfterEditing() }
        editRefreshWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func refreshAfterEditing() {
        guard let paginator = paginator else { return }
        if pageViews.contains(where: { $0.hasMarkedText() }) {
            updatePageIndicator()
            return
        }
        if deferredRender { renderContent(); return }
        let selection = activePageTextView?.selectedRange()
        if let selection = selection {
            paginator.ensureCharacter(selection.location)
            currentPage = paginator.pageIndex(containing: selection.location)
        }
        ensureVisiblePages()
        showCurrentSpread()
        if let selection = selection {
            let index = pageIndex(containing: selection.location)
            if index < pageContainers.count, activePageTextView?.textContainer !== pageContainers[index] {
                selectInVisiblePage(selection)
            }
        }
        if hasPendingEdit {
            hasPendingEdit = false
            schedulePositionChange()
            schedulePagination(after: 0.25)
        }
    }

    @objc func toggleBold(_ sender: Any?) { formattingTarget?.toggleBold(sender) }
    @objc func toggleItalic(_ sender: Any?) { formattingTarget?.toggleItalic(sender) }
    @objc func toggleInlineCode(_ sender: Any?) { formattingTarget?.toggleInlineCode(sender) }
    @objc func setHeading1(_ sender: Any?) { formattingTarget?.setHeading1(sender) }
    @objc func setHeading2(_ sender: Any?) { formattingTarget?.setHeading2(sender) }
    @objc func setHeading3(_ sender: Any?) { formattingTarget?.setHeading3(sender) }
    @objc func setBodyText(_ sender: Any?) { formattingTarget?.setBodyText(sender) }
    @objc func toggleUnorderedList(_ sender: Any?) { formattingTarget?.toggleUnorderedList(sender) }
    @objc func toggleOrderedList(_ sender: Any?) { formattingTarget?.toggleOrderedList(sender) }
    @objc func toggleBlockquote(_ sender: Any?) { formattingTarget?.toggleBlockquote(sender) }
    @objc func insertLink(_ sender: Any?) { formattingTarget?.insertLink(sender) }
    @objc func insertImage(_ sender: Any?) { formattingTarget?.insertImage(sender) }
    @objc func insertHorizontalRule(_ sender: Any?) { formattingTarget?.insertHorizontalRule(sender) }
    @objc func showColorPanel(_ sender: Any?) { formattingTarget?.showColorPanel(sender) }
    @objc func showFindBar(_ sender: Any?) { formattingTarget?.showFindBar(sender) }

    // MARK: - Focus

    /// 지금 키보드 포커스가 리더 안(페이지 뷰 또는 VC 자신)에 있는지.
    private func readerHasFocus() -> Bool {
        guard let responder = view.window?.firstResponder else { return false }
        if responder === self { return true }
        guard let focused = responder as? NSView else { return false }
        return pageViews.contains { focused === $0 || focused.isDescendant(of: $0) }
    }

    /// 키보드 포커스를 첫 페이지 뷰에 준다 — 페이지 뷰가 선택과 키(←/→)를 함께 받는다.
    /// 아직 페이지가 없으면 VC 가 대신 받는다(안전망).
    private func focusPage() {
        view.window?.makeFirstResponder(pageViews.first ?? self)
    }

    var pageInfo: (current: Int, total: Int) {
        (currentPage + 1, max(1, pageCharRanges.count))
    }

    /// 한 번에 넘길 쪽 수 — 펼침면이면 두 쪽씩.
    private var pageStep: Int { isSpread ? 2 : 1 }

    func goToNextPage() {
        guard !pageViews.contains(where: { $0.hasMarkedText() }) else { return }
        paginator?.ensurePage(currentPage + pageStep)
        guard currentPage + pageStep < pageCharRanges.count else { return }
        currentPage += pageStep
        showCurrentSpread()
    }

    func goToPreviousPage() {
        guard currentPage > 0, !pageViews.contains(where: { $0.hasMarkedText() }) else { return }
        currentPage = max(0, currentPage - pageStep)
        showCurrentSpread()
    }

    // MARK: - Page Indicator
    @objc private func updatePageIndicator() {
        guard pageMode == .paged else { pageIndicator?.isHidden = true; return }
        pageIndicator?.isHidden = false
        let blocked = paginator?.isBlocked == true
        let total = blocked ? "!" : (isPaginationComplete ? String(max(1, pageCharRanges.count)) : "…")
        pageIndicator?.toolTip = blocked ? L10n.tr("reader.layoutUnavailable")
            : (isPaginationComplete ? nil : L10n.tr("reader.paginating"))
        let indices = visiblePageIndices()
        if indices.count == 2 {
            pageIndicator?.stringValue = "‹ \(indices[0] + 1)–\(indices[1] + 1) / \(total) ›"
        } else {
            pageIndicator?.stringValue = "‹ \(currentPage + 1) / \(total) ›"
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        positionSaveTimer?.invalidate()
        cancelPaginationWork()
        pagedStorage?.delegate = nil
        // 리더가 통째로 사라질 때도 텍스트 시스템과의 연결은 손으로 끊어 준다 —
        // 페이지뷰가 오토릴리스 풀에 잠깐 더 살아남아도 죽은 컨테이너를 짚지 않도록.
        discardPageViews()
    }

    // MARK: - Keyboard Paging

    override func keyDown(with event: NSEvent) {
        guard pageMode == .paged else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 121: goToNextPage()
        case 116: goToPreviousPage()
        default:
            focusPage()
            pageViews.first?.keyDown(with: event)
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
        layoutPaperHost(host)
        // 페이지 경계는 컨테이너 크기(컬럼 폭 × 페이지 높이)에만 의존한다. 창 폭만 바뀐
        // 리사이즈는 배치·펼침면 판정만 다시 하면 되므로 재분할(비용 큼)을 건너뛴다.
        if textBoxSize() != lastTextBoxSize {
            rebuildPages()
        } else if needsAnchorApply {
            applyAnchor()
        } else {
            showCurrentSpread()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard paginator == nil else { return }
        view.window?.makeFirstResponder(self)
        // 이 오버레이는 페이징 조판 전용이다 — 스크롤 조판은 에디터가 직접 그린다 (ADR-0009).
        setPageMode(.paged)
    }
}

extension Notification.Name {
    static let readerPageChanged = Notification.Name("jn_readerPageChanged")
}
