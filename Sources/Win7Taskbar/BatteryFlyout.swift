import AppKit

// 1:1 rebuild of AeroThemePlasma's battery flyout (plasma/plasmoids/io.gitgud.wackyideas.battery: PopupDialog.qml,
// BatteryItem.qml, FlyoutBatteryIcon.qml, PowerProfileItem.qml, InhibitionItem.qml) in the tray popup frame:
// - 240 wide (window 256), height = content + 72 (22 px white gap above the 42 px footer)
// - battery block (10 px padding): 32 px flyout-battery-NNN icon (+ charging / caution / critical overlay),
//   status text 12 px black, wrapped at 168 px, line pitch 16
// - 1 px #dde0e2 separator
// - "Energiesparplan auswählen:" (black 75 %) + Kvantum radios (13 px, 6 px gap, 16 px pitch). macOS has only the
//   Stromsparmodus, so the plans are shown, not switched (a click opens the Battery settings)
// - "Ruhezustand und Bildschirmsperre manuell verhindern" (Kvantum checkbox) = a power assertion
// - footer "Weitere Energieoptionen" → Battery settings

private func bfFont(_ k: CGFloat) -> NSFont { Menu7Font.font(size: 12 * k) }

private func bfHeight(_ s: String, _ k: CGFloat, width: CGFloat) -> CGFloat {
    let style = NSMutableParagraphStyle(); style.minimumLineHeight = (16 * k).rounded(); style.maximumLineHeight = (16 * k).rounded()
    return ceil(NSAttributedString(string: s, attributes: [.font: bfFont(k), .paragraphStyle: style])
        .boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height)
}

private func bfDraw(_ s: String, _ k: CGFloat, _ color: NSColor, in r: NSRect) {
    let style = NSMutableParagraphStyle(); style.minimumLineHeight = (16 * k).rounded(); style.maximumLineHeight = (16 * k).rounded()
    NSAttributedString(string: s, attributes: [.font: bfFont(k), .foregroundColor: color, .paragraphStyle: style])
        .draw(with: r, options: [.usesLineFragmentOrigin])
}

/// Kvantum radio button / checkbox with its label ("-focused" = hover, like Kvantum).
private final class BFToggle: M7HoverView {
    let title: String
    let radio: Bool
    var k: CGFloat = 1
    var checked = false { didSet { needsDisplay = true } }
    var wrapWidth: CGFloat = 0
    var onClick: (() -> Void)?
    init(_ title: String, radio: Bool) { self.title = title; self.radio = radio; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    private func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }
    var preferredHeight: CGFloat { max(r(16), bfHeight(title, k, width: wrapWidth - r(19))) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let s = r(13)
        let base = radio ? "wf-radio" : "wf-checkbox"
        let name = "\(base)\(checked ? "-checked" : "")-\(hovering ? "focused" : "normal")"
        // Centred on a single line, top-aligned to the first line when the label wraps.
        let y = preferredHeight > r(16) ? r(2) : ((bounds.height - s) / 2).rounded()
        Menu7Assets.draw(Menu7Assets.image(name), in: NSRect(x: 0, y: y, width: s, height: s))
        bfDraw(title, k, .black, in: NSRect(x: r(19), y: 0, width: bounds.width - r(19), height: bounds.height))
    }
}

private final class BFBattery: M7FlippedView {
    var k: CGFloat = 1
    var info: BatteryStatus.Info?
    private func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    /// Status text like Windows 7 / BatteryItem.qml.
    var text: String {
        guard let i = info else { return "Nicht vorhanden" }
        if i.charged { return "Vollständig aufgeladen (\(i.percent) %)" }
        if i.onAC { return "\(i.percent) % verfügbar (angeschlossen, \(i.charging ? "wird aufgeladen" : "wird nicht aufgeladen"))" }
        if let m = i.minutesLeft {
            let h = m / 60, mm = m % 60
            let dur = h > 0 ? "\(h) Std. \(mm) Min." : "\(mm) Min."
            return "\(dur) (\(i.percent) %) verbleibend"
        }
        return "\(i.percent) % verbleibend"
    }
    var preferredHeight: CGFloat { r(10) + max(r(32), bfHeight(text, k, width: r(168))) + r(10) }

    override func draw(_ dirtyRect: NSRect) {
        let s = r(32)
        let icon = NSRect(x: r(10), y: r(10), width: s, height: s)
        if let i = info {
            let p = i.percent
            let lvl = p >= 95 ? 100 : p >= 85 ? 90 : p >= 75 ? 80 : p >= 65 ? 70 : p >= 55 ? 60 : p >= 45 ? 50
                : p >= 35 ? 40 : p >= 25 ? 30 : p >= 15 ? 20 : p > 5 ? 10 : 0
            Menu7Assets.draw(Menu7Assets.image(String(format: "wf-fbat-%03d", lvl)), in: icon)
            let overlay = i.onAC ? "charging" : p <= 5 ? "critical" : p < 15 ? "caution" : nil
            if let o = overlay { Menu7Assets.draw(Menu7Assets.image("wf-fbat-\(o)"), in: icon) }
        } else {
            Menu7Assets.draw(Menu7Assets.image("wf-fbat-missing"), in: icon)
        }
        bfDraw(text, k, .black, in: NSRect(x: r(10) + s + r(4), y: r(10), width: r(168), height: bounds.height - r(10)))
    }
}

private final class BFSeparator: M7FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        TF.hex(0xdde0e2).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

private final class BFLabel: M7FlippedView {
    var k: CGFloat = 1
    var text = ""
    override func draw(_ dirtyRect: NSRect) { bfDraw(text, k, NSColor.black.withAlphaComponent(0.75), in: bounds) }
}

// MARK: - Controller

final class BatteryFlyoutController: NSObject {
    private let host = TrayFlyoutHost(footer: "Weitere Energieoptionen")
    private let battery = BFBattery()
    private let separator = BFSeparator()
    private let planLabel = BFLabel()
    private let plans = [BFToggle("Energiesparmodus", radio: true), BFToggle("Ausbalanciert", radio: true),
                         BFToggle("Höchstleistung", radio: true)]
    private let inhibit = BFToggle("Ruhezustand und Bildschirmsperre manuell verhindern", radio: false)
    private var timer: Timer?
    private var anchor = NSRect.zero
    private weak var screen: NSScreen?

    var isVisible: Bool { host.isVisible }
    var onStateChange: (() -> Void)?

    override init() {
        super.init()
        host.footer.onClick = { [weak self] in
            TF.openSettings("com.apple.Battery-Settings.extension")
            self?.host.hide()
        }
        host.onHide = { [weak self] in self?.timer?.invalidate(); self?.timer = nil }
        for p in plans { p.onClick = { [weak self] in TF.openSettings("com.apple.Battery-Settings.extension"); self?.host.hide() } }
        inhibit.onClick = { [weak self] in
            BatteryStatus.setPreventSleep(!BatteryStatus.preventingSleep)
            self?.refresh()
            self?.onStateChange?()
        }
        for v in [battery, separator, planLabel, inhibit] as [NSView] { host.root.addSubview(v) }
        plans.forEach { host.root.addSubview($0) }
    }

    func toggle(anchor: NSRect, on screen: NSScreen) {
        if host.isVisible { host.hide() } else { show(anchor: anchor, on: screen) }
    }

    func show(anchor: NSRect, on screen: NSScreen) {
        self.anchor = anchor; self.screen = screen
        refresh()
        host.show(anchor: anchor, on: screen)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let k = max(1, Theme.barHeight / 40)
        func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }
        battery.k = k
        battery.info = BatteryStatus.current()
        planLabel.k = k
        planLabel.text = "Energiesparplan auswählen:"
        let low = BatteryStatus.lowPowerMode
        for (i, p) in plans.enumerated() { p.k = k; p.checked = low ? i == 0 : i == 1 }
        inhibit.k = k
        inhibit.checked = BatteryStatus.preventingSleep

        // Content box: x 8…232 of the 240 wide main item, from y 8 (plus the frame's 8 px).
        let x0 = 8 + r(8), cw = r(224)
        var y = 8 + r(8)
        let bh = battery.preferredHeight
        battery.frame = NSRect(x: x0, y: y, width: cw, height: bh); y += bh
        separator.frame = NSRect(x: x0, y: y, width: cw, height: 1); y += 1
        // Power plans: 10 px padding, label, radios 20 px below its top (5 px indent), 4 px bottom padding.
        planLabel.frame = NSRect(x: x0 + r(10), y: y + r(10), width: cw - r(20), height: r(16))
        var ry = y + r(10) + r(20)
        for p in plans {
            p.wrapWidth = cw - r(25)
            p.frame = NSRect(x: x0 + r(15), y: ry, width: cw - r(25), height: r(16))
            ry += r(16)
        }
        y = ry + r(4)
        // Inhibition checkbox: 10 px padding (1 px indent), wraps at 184 px, 4 px bottom padding.
        inhibit.wrapWidth = r(204) - r(1)
        let ih = inhibit.preferredHeight
        inhibit.frame = NSRect(x: x0 + r(10) + r(1), y: y + r(10), width: r(204) - r(1), height: ih)
        y += r(10) + ih + r(4)
        [battery, planLabel, inhibit].forEach { $0.needsDisplay = true }

        let contentH = (y - 8) / k
        host.setMainSize(width: 240, height: contentH + 22 + 42)
        if host.isVisible, let s = screen { host.reposition(anchor: anchor, on: s) }
    }
}
