import AppKit

/// 윈도우 하단 상태바 — 우측 끝에 문서 글자수를 실시간 표시한다.
/// 좌측은 비워둔다(향후 저장 상태·커서 위치 자리).
///
/// 배치는 형제 프로젝트 jena-image 의 검증된 패턴을 따른다: 컨테이너 `NSView` 안에
/// split 뷰(위)와 이 상태바(아래 고정)를 형제로 두고, 컨테이너를 `window.contentViewController`
/// 로 삼는다. 타이틀바 액세서리가 아니라 콘텐츠 최하단에 붙으므로 실제 윈도우 하단에 표시된다.
final class StatusBarView: NSView {

    static let barHeight: CGFloat = 22

    private let charLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 우측 글자수 라벨 텍스트 갱신.
    func setCharCountText(_ text: String) {
        charLabel.stringValue = text
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

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            charLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            charLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            charLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        ])
    }
}
