import AppKit

/// 윈도우 하단 상태바 — 좌측에 작업 상태, 우측 끝에 문서 글자수를 표시하고,
/// 글자수 바로 왼쪽에 보기 컨트롤(스크롤·페이징, 보기 설정, 원문 보기)을 둔다.
///
/// 배치는 형제 프로젝트 jena-image 의 검증된 패턴을 따른다: 컨테이너 `NSView` 안에
/// split 뷰(위)와 이 상태바(아래 고정)를 형제로 두고, 컨테이너를 `window.contentViewController`
/// 로 삼는다. 타이틀바 액세서리가 아니라 콘텐츠 최하단에 붙으므로 실제 윈도우 하단에 표시된다.
final class StatusBarView: NSView {

    /// 12pt 보기 컨트롤이 들어가도록 22 → 32.
    static let barHeight: CGFloat = 32

    private let workLabel = NSTextField(labelWithString: "")
    private let charLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let controlStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 우측 글자수 라벨 텍스트 갱신.
    var charCountText: String { charLabel.stringValue }

    func setCharCountText(_ text: String) {
        charLabel.stringValue = text
    }

    /// 글자수 왼쪽에 나열할 컨트롤을 지정한다.
    func setControls(_ views: [NSView]) {
        controlStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(controlStack.addArrangedSubview)
    }

    func setWorkStatus(_ text: String) {
        workLabel.stringValue = text
        workLabel.toolTip = text
    }

    private func setupViews() {
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        charLabel.translatesAutoresizingMaskIntoConstraints = false
        charLabel.alignment = .right
        charLabel.font = .systemFont(ofSize: 11)
        charLabel.textColor = .secondaryLabelColor
        charLabel.lineBreakMode = .byTruncatingHead
        addSubview(charLabel)

        workLabel.translatesAutoresizingMaskIntoConstraints = false
        workLabel.font = .systemFont(ofSize: 11)
        workLabel.textColor = .secondaryLabelColor
        workLabel.lineBreakMode = .byTruncatingTail
        workLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(workLabel)

        controlStack.orientation = .horizontal
        controlStack.spacing = 6
        controlStack.alignment = .centerY
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlStack)
        NSLayoutConstraint.activate([
            workLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            workLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            workLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlStack.leadingAnchor, constant: -12),
            controlStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            controlStack.trailingAnchor.constraint(equalTo: charLabel.leadingAnchor, constant: -14),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            charLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            charLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }
}
