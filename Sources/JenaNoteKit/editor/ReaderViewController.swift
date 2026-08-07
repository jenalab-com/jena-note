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

/// 페이징 화면의 한 쪽(page)을 그리는 텍스트 뷰.
///
/// 읽기 전용이지만 **글자는 고를 수 있다** — 인용을 옮겨 적으려면 선택이 있어야 하니까.
/// 대신 선택을 켜는 순간 이 뷰가 first responder 를 가져가므로, 예전에 VC 가 받던
/// 페이지 넘김(←/→)과 "글자를 쳐서 편집으로 갈아타기"를 여기서 직접 위로 흘려보낸다.
final class PageTextView: NSTextView {
    /// ←/→ 를 눌렀다. `next == true` 면 다음 쪽.
    var onPageKey: ((Bool) -> Void)?
    /// 글자를 치려는 키가 왔다 — 편집 조판으로 갈아탈 신호 (ADR-0009).
    var onTextInput: ((NSEvent) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 124: onPageKey?(true);  return   // →
        case 123: onPageKey?(false); return   // ←
        default: break
        }
        if let handler = onTextInput, ReaderViewController.isTextInput(event) {
            handler(event)
            return
        }
        super.keyDown(with: event)
    }

    /// 드래그가 쪽 밖으로 나가도 배경 스크롤뷰를 끌어당기지 않게 한다 —
    /// 페이지는 고정 크기라 스크롤할 것이 없다.
    override func autoscroll(with event: NSEvent) -> Bool { false }
}

/// 페이징 조판 전용 읽기 오버레이. 원본 사본을 받아 한글 35자 컬럼으로 조판하며
/// 원본은 절대 수정하지 않는다.
///
/// ADR-0009 이후 스크롤 조판은 에디터가 직접 입는다(편집 가능). 이 클래스는 **페이징일
/// 때만** 우측 페인에 올라오는 읽기 전용 화면이고, 여기서 글자를 치면 `onEditRequested`
/// 로 알려 스크롤 조판으로 갈아타게 한다. 스크롤 경로는 모드 전환 과도기를 위해 남아 있다.
///
/// - 페이징: NSLayoutManager 에 페이지마다 NSTextContainer 를 두는 "진짜 페이지네이션".
///   컨테이너에 안 들어가는 줄은 통째로 다음 페이지로 흐르므로 줄이 잘리지 않는다.
///   창이 넓으면 좌·우 두 쪽을 나란히 펼친다.
class ReaderViewController: NSViewController, ReadingPositionProviding {

    /// 읽기 단(컬럼) 폭 프리셋. 조판 계산과 함께 ReaderMetrics 로 옮겼다
    /// (에디터도 같은 폭으로 조판해야 하므로). 기존 호출부를 위해 이름은 남긴다.
    typealias WidthMode = ReaderMetrics.WidthMode

    // MARK: - State
    private var sourceContent: NSAttributedString
    private var scale: CGFloat = SettingsManager.shared.readingFontScale
    private var pageMode: SettingsManager.ReadingPageMode = SettingsManager.shared.readingPageMode
    private var fontFamily: SettingsManager.ReadingFont = SettingsManager.shared.readingFont
    private var fontWeight: SettingsManager.ReadingWeight = SettingsManager.shared.readingWeight
    private var lineSpacing: CGFloat = SettingsManager.shared.readingLineSpacing
    private var widthMode: WidthMode = .book

    // MARK: - Scroll-mode views
    private var scrollView: NSScrollView!
    private var textView: NSTextView!

    // MARK: - Paged-mode views (멀티 컨테이너 페이지네이션)
    private var pagedHost: PagedHostView?
    /// 지금 화면에 얹힌 페이지 뷰들 — 낱쪽이면 1개, 펼침면이면 좌·우 2개.
    private var pageViews: [PageTextView] = []
    private var pagedStorage: NSTextStorage?
    private var pagedLM: NSLayoutManager?
    private var pageContainers: [NSTextContainer] = []
    private var pageCharRanges: [NSRange] = []
    private var currentPage = 0
    private weak var pageIndicator: NSTextField?
    /// 마지막으로 페이지를 나눈 컨테이너 크기(컬럼 폭 × 페이지 높이).
    /// 페이지 경계는 이 둘에만 의존하므로, 창 폭만 바뀐 리사이즈에서는 재분할하지 않는다.
    private var lastPageBoxSize: NSSize = .zero
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
        ReaderMetrics.columnWidth(mode: widthMode, scale: scale, family: fontFamily,
                                  charCount: SettingsManager.shared.readingLineLength)
    }

    private func styledContent() -> NSAttributedString {
        ReaderMetrics.styled(sourceContent, scale: scale,
                             font: fontFamily, lineHeightMultiple: lineSpacing,
                             weight: fontWeight,
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
            guard !pageContainers.isEmpty else { return }
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
        lastPageBoxSize = .zero     // 강제 rebuild
        rebuildPages()
        focusPage()
    }

    private func removePagedOverlay() {
        pagedHost?.removeFromSuperview()
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews = []
        pageContainers = []
        pagedLM = nil
        pagedStorage = nil
    }

    /// 페이지 컨테이너 한 장의 크기. 페이지 경계는 오직 이 크기에서 나온다
    /// (창 폭은 배치에만 쓰인다 — 그래서 가로 리사이즈는 재분할을 부르지 않는다).
    private func pageBoxSize() -> NSSize {
        guard let host = pagedHost else { return .zero }
        return NSSize(width: columnWidthForCurrentSettings(),
                      height: max(1, host.bounds.height - 2 * pageVMargin))
    }

    /// 페이지마다 NSTextContainer 를 추가해 전체 텍스트를 페이지로 나눈다.
    private func rebuildPages() {
        guard pagedHost != nil else { return }
        let size = pageBoxSize()

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
        lastPageBoxSize = size
        // 페이지 경계가 새로 잡혔으므로 페이지 번호가 아니라 앵커에서 다시 찾는다.
        // 폰트·행간·폭을 바꿔도 읽던 문장이 화면에 남는 이유다.
        currentPage = min(max(0, pageIndex(containing: anchorOffset)), max(0, containers.count - 1))
        needsAnchorApply = false
        showCurrentSpread()
    }

    /// 주어진 문자 오프셋이 속한 페이지 인덱스.
    private func pageIndex(containing offset: Int) -> Int {
        guard !pageCharRanges.isEmpty else { return 0 }
        for (i, r) in pageCharRanges.enumerated() where offset < NSMaxRange(r) { return i }
        return pageCharRanges.count - 1
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
        guard currentPage >= 0, currentPage < pageContainers.count else { return [] }
        guard isSpread, currentPage + 1 < pageContainers.count else { return [currentPage] }
        return [currentPage, currentPage + 1]
    }

    /// 현재 펼침면(또는 낱쪽)을 호스트 가운데에 배치한다.
    private func showCurrentSpread() {
        // 페이지 뷰를 갈아끼우면 그 뷰가 쥐고 있던 키보드 포커스가 사라진다. 리더가
        // 쥐고 있던 포커스면 새 뷰에 다시 넘겨주고, 사이드바처럼 밖에 있었으면 뺏지 않는다.
        let hadFocus = readerHasFocus()
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews = []
        guard let host = pagedHost, currentPage < pageContainers.count else { return }

        updateSpreadState()
        // 펼침면의 왼쪽은 항상 짝수 쪽 — 책처럼 짝을 고정해 넘길 때 짝이 밀리지 않는다.
        if isSpread { currentPage = ReaderMetrics.spreadStart(page: currentPage) }

        let indices = visiblePageIndices()
        guard !indices.isEmpty else { return }
        let box = pageBoxSize()
        let gutter = ReaderMetrics.spreadGutter
        let totalW = CGFloat(indices.count) * box.width + CGFloat(indices.count - 1) * gutter
        var x = max(0, (host.bounds.width - totalW) / 2)

        for index in indices {
            let tv = PageTextView(frame: NSRect(x: x, y: pageVMargin, width: box.width, height: box.height),
                                  textContainer: pageContainers[index])
            tv.isEditable = false
            tv.isSelectable = true        // 읽으면서 인용을 고를 수 있어야 한다
            tv.drawsBackground = false
            tv.onPageKey = { [weak self] next in
                if next { self?.goToNextPage() } else { self?.goToPreviousPage() }
            }
            tv.onTextInput = { [weak self] event in
                guard let self = self else { return }
                self.onEditRequested?(self.editingOffset(), event)
            }
            host.addSubview(tv, positioned: .below, relativeTo: pageIndicator)
            pageViews.append(tv)
            x += box.width + gutter
        }
        if hadFocus { focusPage() }

        captureAnchor()
        updatePageIndicator()
        NotificationCenter.default.post(name: .readerPageChanged, object: self)
    }

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
        (currentPage + 1, max(1, pageContainers.count))
    }

    /// 한 번에 넘길 쪽 수 — 펼침면이면 두 쪽씩.
    private var pageStep: Int { isSpread ? 2 : 1 }

    func goToNextPage() {
        guard currentPage + pageStep < pageContainers.count else { return }
        currentPage += pageStep
        showCurrentSpread()
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        currentPage = max(0, currentPage - pageStep)
        showCurrentSpread()
    }

    // MARK: - Page Indicator
    @objc private func updatePageIndicator() {
        guard pageMode == .paged else { pageIndicator?.isHidden = true; return }
        pageIndicator?.isHidden = false
        let total = max(1, pageContainers.count)
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
    }

    // MARK: - Keyboard Paging

    /// 페이징 화면에서 글자를 치려는 신호가 왔을 때 알린다. 페이징은 읽기 전용이므로
    /// 호출자가 스크롤 조판으로 갈아타 그 자리에서 이어 쓰게 한다 (ADR-0009).
    /// 방아쇠가 된 이벤트를 함께 넘겨 전환 후 첫 글자를 잃지 않게 한다.
    var onEditRequested: ((Int, NSEvent?) -> Void)?

    /// 편집으로 갈아탈 때 커서를 놓을 자리. 보고 있는 쪽 안에 캐럿(또는 선택 시작점)이
    /// 있으면 그 자리를 쓴다 — 글자를 골라둔 데서 이어 쓰게 된다. 아직 아무 데도 안
    /// 짚었다면 쪽 첫 글자로 물러난다(선택 기본값 0 이 문서 맨 앞으로 튀지 않도록).
    private func editingOffset() -> Int {
        let visible = visibleCharacterRange
        for tv in pageViews {
            let sel = tv.selectedRange()
            guard sel.location != NSNotFound else { continue }
            if NSLocationInRange(sel.location, visible) || sel.location == NSMaxRange(visible) {
                return sel.location
            }
        }
        return currentCharacterOffset
    }

    override func keyDown(with event: NSEvent) {
        guard pageMode == .paged else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 124: goToNextPage()      // →
        case 123: goToPreviousPage()  // ←
        default:
            if let handler = onEditRequested, ReaderViewController.isTextInput(event) {
                handler(editingOffset(), event)
                return
            }
            super.keyDown(with: event)
        }
    }

    /// 글자를 입력하려는 키인지 — 단축키(⌘·⌃)와 방향키·기능키는 제외한다.
    static func isTextInput(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return false }
        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first else {
            return false
        }
        // 방향키·F키 등은 유니코드 사용자 영역에 실려 온다.
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        // 탈출·삭제 같은 제어 문자는 입력으로 보지 않는다 (단, 줄바꿈·탭은 입력).
        if scalar.value == 0x1B || scalar.value == 0x7F { return false }
        return true
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
        // 페이지 경계는 컨테이너 크기(컬럼 폭 × 페이지 높이)에만 의존한다. 창 폭만 바뀐
        // 리사이즈는 배치·펼침면 판정만 다시 하면 되므로 재분할(비용 큼)을 건너뛴다.
        if pageBoxSize() != lastPageBoxSize {
            rebuildPages()
        } else if needsAnchorApply {
            applyAnchor()
        } else {
            showCurrentSpread()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
        // 이 오버레이는 페이징 조판 전용이다 — 스크롤 조판은 에디터가 직접 그린다 (ADR-0009).
        setPageMode(.paged)
    }
}

extension Notification.Name {
    static let readerPageChanged = Notification.Name("jn_readerPageChanged")
}
