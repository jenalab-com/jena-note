import AppKit

/// 읽기 전용 "책 보기" 뷰. document.content(이미 파싱된 NSAttributedString)를
/// 받아 한글 35자 컬럼으로 조판한다. 원본은 절대 수정하지 않는다.
class ReaderViewController: NSViewController {

    // MARK: - State
    private var sourceContent: NSAttributedString
    private var scale: CGFloat = SettingsManager.shared.readingFontScale
    private var pageMode: SettingsManager.ReadingPageMode = SettingsManager.shared.readingPageMode

    // MARK: - Views
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var widthConstraint: NSLayoutConstraint!

    // MARK: - Init
    init(content: NSAttributedString) {
        self.sourceContent = content
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // MARK: - Layout
    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textContainer = NSTextContainer(containerSize: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 48)
        textView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = textView

        // 컬럼을 고정폭으로 두고 가로 가운데 정렬.
        // documentView 의 height 는 텍스트 내용이 결정하도록 top 만 고정하고
        // bottom 은 contentView 에 >= 로 묶어 세로 스크롤이 동작하게 한다.
        let column = columnWidthForCurrentSettings()
        let contentView = scrollView.contentView
        widthConstraint = textView.widthAnchor.constraint(equalToConstant: column)
        let bottomConstraint = textView.bottomAnchor.constraint(
            greaterThanOrEqualTo: contentView.bottomAnchor)
        bottomConstraint.priority = .defaultLow
        NSLayoutConstraint.activate([
            widthConstraint,
            textView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor),
            bottomConstraint
        ])

        view = scrollView
        renderContent()
    }

    // MARK: - Rendering
    private func columnWidthForCurrentSettings() -> CGFloat {
        let chars = SettingsManager.shared.readingLineLength
        // 한글 전각 글리프 advance 실측 (시스템 폰트 fallback 보정)
        let probeFont = NSFont(descriptor: MemoFont.body.fontDescriptor,
                               size: MemoFont.body.pointSize * scale) ?? MemoFont.body
        let advance = ("한" as NSString).size(withAttributes: [.font: probeFont]).width
        return ReaderMetrics.columnWidth(charCount: chars, glyphAdvance: advance)
    }

    private func renderContent() {
        guard let storage = textView.textStorage else { return }
        let display = ReaderMetrics.scaled(sourceContent, by: scale)
        storage.setAttributedString(display)
        widthConstraint.constant = columnWidthForCurrentSettings()
    }

    // MARK: - Public API
    func updateContent(_ content: NSAttributedString) {
        sourceContent = content
        renderContent()
    }

    func setFontScale(_ newScale: CGFloat) {
        scale = min(max(newScale, 0.8), 2.0)
        SettingsManager.shared.readingFontScale = scale
        renderContent()
    }

    func setPageMode(_ mode: SettingsManager.ReadingPageMode) {
        pageMode = mode
        SettingsManager.shared.readingPageMode = mode
        let paged = (mode == .paged)
        scrollView.hasVerticalScroller = !paged
        scrollView.verticalScrollElasticity = paged ? .none : .allowed
        currentPage = 0
        scrollToCurrentPage()
    }

    // MARK: - Paging State
    private var currentPage: Int = 0

    private var lineHeightEstimate: CGFloat {
        guard let lm = textView.layoutManager, textView.textStorage?.length ?? 0 > 0 else {
            let f = NSFont(descriptor: MemoFont.body.fontDescriptor,
                           size: MemoFont.body.pointSize * scale) ?? MemoFont.body
            return f.ascender - f.descender + f.leading + 2
        }
        return lm.defaultLineHeight(for: NSFont(descriptor: MemoFont.body.fontDescriptor,
                                                size: MemoFont.body.pointSize * scale) ?? MemoFont.body)
    }

    private var pageHeight: CGFloat {
        let visible = scrollView.contentView.bounds.height
        return ReaderMetrics.snappedPageHeight(viewHeight: visible, lineHeight: lineHeightEstimate)
    }

    private var totalContentHeight: CGFloat {
        (textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0)
            + textView.textContainerInset.height * 2
    }

    private var pageCount: Int {
        max(1, Int(ceil(totalContentHeight / max(pageHeight, 1))))
    }

    var pageInfo: (current: Int, total: Int) { (currentPage + 1, pageCount) }

    func goToNextPage() {
        guard currentPage < pageCount - 1 else { return }
        currentPage += 1
        scrollToCurrentPage()
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
        scrollToCurrentPage()
    }

    private func scrollToCurrentPage() {
        let y = CGFloat(currentPage) * pageHeight
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: .readerPageChanged, object: self)
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

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }
}

extension Notification.Name {
    static let readerPageChanged = Notification.Name("jn_readerPageChanged")
}
