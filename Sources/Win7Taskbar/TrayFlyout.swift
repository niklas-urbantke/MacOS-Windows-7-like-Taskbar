import AppKit

// Shared pieces of the Windows 7 tray flyouts (AeroThemePlasma's system-tray popup): the Seven-Black
// "solid" dialog frame with Aero glass behind its 8 px edge, the #f1f5fb footer strip with its link,
// and the Win7 controls (Kvantum Windows7Aero buttons/checkbox, line edits). Assets: ThemeResources/wf-*.

enum TF {
    static func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255,
                blue: CGFloat(h & 0xff) / 255, alpha: a)
    }
    static func font(_ k: CGFloat, bold: Bool = false) -> NSFont { Menu7Font.font(size: 12 * k, bold: bold) }

    /// Single line of text, vertically centred in `rect`.
    static func text(_ s: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left,
                     underline: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = ceil(str.size().height)
        str.draw(with: NSRect(x: rect.minX, y: (rect.midY - h / 2).rounded(), width: rect.width, height: h),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    static func width(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Signal icon like plasma-nm: quality 0 → 0, < 20 → 20, < 40 → 40, < 60 → 60, < 80 → 80, else 100,
    /// "-locked" for secured networks; `big` = the 32 px variant of the connected row.
    static func barsIcon(rssi: Int, secure: Bool, big: Bool) -> NSImage? {
        let q = rssi == 0 ? 100 : max(0, min(100, 2 * (rssi + 100)))
        let lvl = q <= 0 ? 0 : q < 20 ? 20 : q < 40 ? 40 : q < 60 ? 60 : q < 80 ? 80 : 100
        return Menu7Assets.image("wf-bars-\(lvl)\(secure ? "-locked" : "")\(big ? "-big" : "")")
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Controls

/// Windows 7 push button (Kvantum Windows7Aero "btn": normal / hover / pressed).
final class TFButton: M7HoverView {
    var title: String { didSet { needsDisplay = true } }
    var k: CGFloat = 1
    var onClick: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }

    init(_ title: String) { self.title = title; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    /// At least 75 px wide like Windows buttons, text plus 10 px each side.
    var preferredWidth: CGFloat { max((75 * k).rounded(), TF.width(title, TF.font(k)) + (20 * k).rounded()) }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let state = pressed ? "pressed" : (hovering ? "focused" : "normal")
        Menu7Assets.draw(Menu7Assets.frame("wf-btn-\(state)", 3, 3, 3, 3), in: bounds)
        TF.text(title, in: bounds, font: TF.font(k), color: .black, alignment: .center)
    }
}

/// Flat tool button with an icon (frame only on hover/press), e.g. refresh.
final class TFToolButton: M7HoverView {
    let icon: String
    var k: CGFloat = 1
    var onClick: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }

    init(icon: String) { self.icon = icon; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        if pressed || hovering {
            Menu7Assets.draw(Menu7Assets.frame(pressed ? "wf-btn-pressed" : "wf-btn-focused", 3, 3, 3, 3), in: bounds)
        }
        let s = (16 * k).rounded()
        Menu7Assets.draw(Menu7Assets.image(icon), in: NSRect(x: ((bounds.width - s) / 2).rounded(),
                                                             y: ((bounds.height - s) / 2).rounded(), width: s, height: s))
    }
}

/// QtQuick checkbox under Kvantum Windows7Aero: 13 px box, the Wi-Fi icon, then the label.
final class TFCheckbox: M7HoverView {
    let title: String
    var k: CGFloat = 1
    var checked = false { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    var onToggle: ((Bool) -> Void)?

    init(_ title: String) { self.title = title; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat { (13 * k).rounded() + (4 * k).rounded() * 2 + (16 * k).rounded() + TF.width(title, TF.font(k)) + 2 }

    override func mouseUp(with event: NSEvent) {
        guard enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        checked.toggle()
        onToggle?(checked)
    }
    override func draw(_ dirtyRect: NSRect) {
        let box = (13 * k).rounded(), gap = (4 * k).rounded(), icon = (16 * k).rounded()
        let state = !enabled ? "disabled" : (hovering ? "focused" : "normal")
        let name = checked ? "wf-checkbox-checked-\(state)" : "wf-checkbox-\(state)"
        Menu7Assets.draw(Menu7Assets.image(name), in: NSRect(x: 0, y: ((bounds.height - box) / 2).rounded(), width: box, height: box))
        let ix = box + gap
        Menu7Assets.draw(Menu7Assets.image(checked ? "wf-wifi-on" : "wf-wifi-off"),
                         in: NSRect(x: ix, y: ((bounds.height - icon) / 2).rounded(), width: icon, height: icon))
        let tx = ix + icon + gap
        TF.text(title, in: NSRect(x: tx, y: 0, width: bounds.width - tx, height: bounds.height),
                font: TF.font(k), color: enabled ? .black : .disabledControlTextColor)
    }
}

/// Text link in the footer (#0066cc, underlined on hover, pointing-hand cursor).
final class TFLink: M7HoverView {
    let title: String
    var k: CGFloat = 1
    var onClick: (() -> Void)?
    init(_ title: String) { self.title = title; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        TF.text(title, in: bounds, font: TF.font(k), color: TF.hex(0x0066cc), alignment: .center, underline: hovering)
    }
}

/// Text field with the original line-edit frame (search: plasmoid lineedit.svg, password: widgets/lineedit.svg).
final class TFFieldBox: M7FlippedView {
    let frameName: String
    let inset: CGFloat
    init(frameName: String, inset: CGFloat) { self.frameName = frameName; self.inset = inset; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        Menu7Assets.draw(Menu7Assets.frame(frameName, inset, inset, inset, inset), in: bounds)
    }
}

// MARK: - Chrome (glass frame + footer strip)

final class TFChrome: M7FlippedView {
    var k: CGFloat = 1
    func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }
    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        guard b.width > 40, b.height > 40 else { return }
        Menu7Assets.draw(Menu7Assets.frame("wf-dialog", 8, 8, 8, 8), in: b)
        // Footer strip: 42 px, #f1f5fb with a 4 px #ccd9ea → #f1f5fb gradient on top.
        let strip = NSRect(x: 8, y: b.height - 8 - r(42), width: b.width - 16, height: r(42))
        TF.hex(0xf1f5fb).setFill()
        strip.fill()
        NSGradient(starting: TF.hex(0xccd9ea), ending: TF.hex(0xf1f5fb))?
            .draw(in: NSRect(x: strip.minX, y: strip.minY, width: strip.width, height: r(4)), angle: 90)
    }
}

/// Pin toggle at the bottom right (tray svgs/button.svgz toolbutton-hover / -pressed, 10 px "pin"):
/// a pinned flyout stays open when it loses focus.
final class TFPin: M7HoverView {
    var k: CGFloat = 1
    var pinned = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { pinned.toggle() }
    }
    override func draw(_ dirtyRect: NSRect) {
        if pressed || pinned {
            Menu7Assets.draw(Menu7Assets.frame("wf-toolbutton-pressed", 2, 2, 2, 2), in: bounds)
        } else if hovering {
            Menu7Assets.draw(Menu7Assets.frame("wf-toolbutton-hover", 2, 2, 2, 2), in: bounds)
        }
        let s = (10 * k).rounded()
        Menu7Assets.draw(Menu7Assets.image("wf-pin"), in: NSRect(x: ((bounds.width - s) / 2).rounded(),
                                                                y: ((bounds.height - s) / 2).rounded(), width: s, height: s))
    }
}

// MARK: - Host window

/// Window of a tray flyout: frame + glass + footer link; the owner adds its content to `root`
/// inside `appletRect`. Sizes are the main item in reference px (scaled by `k`), the frame adds its
/// native 8 px on each side. Opens centred above the tray icon, closes when it loses focus.
final class TrayFlyoutHost: NSObject {
    let window: KeyableWindow
    let root = M7FlippedView()
    private let glass = AeroBackdropView()
    private let chrome = TFChrome()
    let footer: TFLink
    let pin = TFPin()
    /// Distance of the pin from the main item's right/bottom edge (tray: 6, clock: 8).
    var pinMargin: CGFloat = 6
    private(set) var k: CGFloat = 1
    var onEscape: (() -> Void)?
    var onHide: (() -> Void)?
    func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    init(footer title: String) {
        footer = TFLink(title)
        window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 288, height: 320),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false   // the macOS shadow adds a dark 1 px outline
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.onCancel = { [weak self] in
            if let e = self?.onEscape { e() } else { self?.hide() }
        }
        window.contentView = root
        glass.roundBottom = true
        root.addSubview(glass)
        root.addSubview(chrome)
        root.addSubview(footer)
        root.addSubview(pin)
        NotificationCenter.default.addObserver(self, selector: #selector(resigned),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    var isVisible: Bool { window.isVisible }
    var W: CGFloat { root.bounds.width }
    var H: CGFloat { root.bounds.height }

    /// Applet area: the main item inset by 8 (top, sides) and by the footer (42 + 4) at the bottom.
    var appletRect: NSRect {
        NSRect(x: 8 + r(8), y: 8 + r(8), width: W - 16 - 2 * r(8), height: H - 16 - r(8) - r(46))
    }
    /// Top of the footer strip (content may scroll down to here).
    var footerTop: CGFloat { H - 8 - r(42) }

    /// Sets the main item size (reference px) and lays out frame, glass and footer.
    func setMainSize(width: CGFloat, height: CGFloat) {
        k = max(1, Theme.barHeight / 40)
        let w = r(width) + 16, h = r(height) + 16
        root.frame = NSRect(x: 0, y: 0, width: w, height: h)
        glass.frame = root.bounds
        glass.topRadius = 6
        chrome.k = k
        chrome.frame = root.bounds
        chrome.needsDisplay = true
        footer.k = k
        footer.frame = NSRect(x: 8, y: h - 8 - r(40), width: w - 16, height: r(40) - r(4))
        pin.k = k
        pin.frame = NSRect(x: w - 8 - r(pinMargin) - r(17), y: h - 8 - r(pinMargin) - r(16), width: r(17), height: r(16))
    }

    /// Centred on the tray icon, 10 px above it, kept 10 px inside the screen.
    func show(anchor: NSRect, on screen: NSScreen) {
        reposition(anchor: anchor, on: screen)
        shownAt = Date()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// When the app is activated for the flyout, the window can lose key status once right away;
    /// that must not close it.
    private var shownAt = Date.distantPast

    /// Applies a new size/position without activating (e.g. after the content changed while open).
    func reposition(anchor: NSRect, on screen: NSScreen) {
        let vf = screen.frame
        var x = (anchor.midX - W / 2).rounded()
        x = max(vf.minX + r(10), min(x, vf.maxX - r(10) - W))
        window.setFrame(NSRect(x: x, y: anchor.maxY + r(10), width: W, height: H), display: true)
        glass.configure(sigma: AeroGlass.blurSigma * k, spec: AeroColor.current, fallbackAlpha: 1)
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        onHide?()
    }

    @objc private func resigned() {
        guard !pin.pinned else { return }
        if Date().timeIntervalSince(shownAt) < 0.6 {
            DispatchQueue.main.async { [weak self] in self?.window.makeKeyAndOrderFront(nil) }
            return
        }
        hide()
    }
}
