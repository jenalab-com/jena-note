import AppKit

/// 숫자 하나를 보여주고 정한다 — 글자 크기(pt), 자간(%). 직접 입력하거나 1씩 움직인다.
final class NumberStepControl: NSStackView {
    var onChange: ((CGFloat) -> Void)?

    private(set) var value: CGFloat
    private let range: ClosedRange<CGFloat>
    private let granularity: CGFloat
    private let field = NSTextField()
    private let stepper = NSStepper()

    /// `granularity` 는 입력값을 맞출 단위다. 1이면 정수만 받는다.
    init(value: CGFloat, range: ClosedRange<CGFloat>, unit: String, granularity: CGFloat = 0.1) {
        self.value = value
        self.range = range
        self.granularity = granularity
        super.init(frame: .zero)
        spacing = 4

        field.alignment = .right
        field.target = self
        field.action = #selector(fieldChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true

        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        addArrangedSubview(field)
        addArrangedSubview(NSTextField(labelWithString: unit))
        addArrangedSubview(stepper)
        show()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    var isEnabled = true {
        didSet {
            field.isEnabled = isEnabled
            stepper.isEnabled = isEnabled
        }
    }

    /// 소수 값에서도 다음 정수로 맞춘다 — 16.5에서 올리면 17.5가 아니라 17이다.
    @objc private func stepperChanged() {
        let up = CGFloat(stepper.doubleValue) > value
        apply(up ? floor(value) + 1 : ceil(value) - 1)
    }

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
        stepper.doubleValue = Double(value)
    }
}
