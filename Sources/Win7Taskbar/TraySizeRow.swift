import AppKit

/// One row of the per-item size editor: a label, a "Standard" checkbox (use the general size /
/// default width), and a slider with a px read-out. Applies live via `onChange` (nil = Standard).
final class TraySizeRow: NSView {
    let id: String
    var onChange: ((String, CGFloat?) -> Void)?
    private let minV: CGFloat
    private let maxV: CGFloat
    private let autoBox = NSButton(checkboxWithTitle: "Standard", target: nil, action: nil)
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")

    init(id: String, label: String, min: CGFloat, max: CGFloat) {
        self.id = id; self.minV = min; self.maxV = max
        super.init(frame: .zero)

        let name = NSTextField(labelWithString: label)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 130).isActive = true

        autoBox.target = self
        autoBox.action = #selector(autoToggled)

        slider.minValue = Double(min)
        slider.maxValue = Double(max)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let stack = NSStackView(views: [name, autoBox, slider, valueLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `value` nil = Standard (checkbox on); `manualDefault` seeds the slider when Standard is off.
    func configure(value: CGFloat?, manualDefault: CGFloat) {
        if let value {
            autoBox.state = .off
            slider.isEnabled = true
            slider.doubleValue = Double(value)
            valueLabel.stringValue = "\(Int(value)) px"
        } else {
            autoBox.state = .on
            slider.isEnabled = false
            slider.doubleValue = Double(Swift.max(minV, Swift.min(maxV, manualDefault)))
            valueLabel.stringValue = "Standard"
        }
    }

    @objc private func autoToggled() {
        if autoBox.state == .on {
            slider.isEnabled = false
            valueLabel.stringValue = "Standard"
            onChange?(id, nil)
        } else {
            slider.isEnabled = true
            let v = CGFloat(slider.doubleValue.rounded())
            valueLabel.stringValue = "\(Int(v)) px"
            onChange?(id, v)
        }
    }

    @objc private func sliderChanged() {
        let v = slider.doubleValue.rounded()
        valueLabel.stringValue = "\(Int(v)) px"
        onChange?(id, CGFloat(v))
    }
}
