import AppKit

/// 숫자 하나를 보여주고 정한다 — 글자 크기(pt), 자간(%). 직접 입력하거나 1씩 움직인다.
final class NumberStepControl: NSStackView {
    var onChange: ((CGFloat) -> Void)?

    private(set) var value: CGFloat
    private let range: ClosedRange<CGFloat>
    private let granularity: CGFloat
    let field = NSTextField()
    /// 1 줄이기 / 1 늘리기 — 헤더 아이콘 버튼과 같은 결
    private(set) var decreaseButton: HeaderButton!
    private(set) var increaseButton: HeaderButton!

    /// `granularity` 는 입력값을 맞출 단위다. 1이면 정수만 받는다.
    init(value: CGFloat, range: ClosedRange<CGFloat>, unit: String, granularity: CGFloat = 0.1) {
        self.value = value
        self.range = range
        self.granularity = granularity
        super.init(frame: .zero)
        spacing = 2
        alignment = .centerY
        // 헤더 컨트롤과 같은 결 — 칸 테두리 없이 숫자·단위·작은 화살표만, 높이 28.
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: HeaderStyle.height).isActive = true

        field.alignment = .right
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.textColor = HeaderStyle.tint
        field.target = self
        field.action = #selector(fieldChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let small = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        decreaseButton = HeaderButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: nil)?
                                        .withSymbolConfiguration(small),
                                      label: "−1 \(unit)", target: self, action: #selector(decrease), size: 22)
        increaseButton = HeaderButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                                        .withSymbolConfiguration(small),
                                      label: "+1 \(unit)", target: self, action: #selector(increase), size: 22)

        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.font = .systemFont(ofSize: 12)
        unitLabel.textColor = .secondaryLabelColor
        addArrangedSubview(decreaseButton)
        addArrangedSubview(field)
        addArrangedSubview(unitLabel)
        addArrangedSubview(increaseButton)
        show()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    var isEnabled = true {
        didSet {
            field.isEnabled = isEnabled
            decreaseButton.isEnabled = isEnabled
            increaseButton.isEnabled = isEnabled
        }
    }

    /// 소수 값에서도 다음 정수로 맞춘다 — 16.5에서 올리면 17.5가 아니라 17이다.
    @objc func increase() { apply(floor(value) + 1) }
    @objc func decrease() { apply(ceil(value) - 1) }

    @objc private func fieldChanged() {
        let text = field.stringValue.replacingOccurrences(of: ",", with: ".")
        guard let typed = Double(text.trimmingCharacters(in: .whitespaces)) else { show(); return }
        apply(CGFloat(typed))
    }

    private func apply(_ newValue: CGFloat) {
        let snapped = (newValue / granularity).rounded() * granularity
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        let changed = clamped != value
        value = clamped
        show()
        if changed { onChange?(clamped) }
    }

    private func show() {
        field.stringValue = String(format: "%g", Double((value * 10).rounded() / 10))
        decreaseButton?.isEnabled = isEnabled && value > range.lowerBound
        increaseButton?.isEnabled = isEnabled && value < range.upperBound
    }
}
