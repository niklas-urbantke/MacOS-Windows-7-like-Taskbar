import AppKit

// 1:1 rebuild of AeroThemePlasma's volume flyout ("Sound Mixer", plasma/plasmoids/io.gitgud.wackyideas.volume:
// main.qml, ListItemBase.qml, VolumeSlider.qml, svgs/control.svg) in the tray popup frame. Content 149 × 289
// (68 wide without an input device); per column (34 px cell, output at x 17, input at x 98, separator #d6e1dd at
// x 74): 32 px device icon (switches the device when there are several), vertical slider — 6 px groove
// (widgets/slider.svg) at y 67…181, #cfcfcf ticks with the control.svg "bgthing" wedge, 18 × 10 "scursor"
// handle with a hard 1 px shadow, value tooltip while dragging — and the mute button (widgets/button.svg
// toolbutton frames, control.svg "mute" / "unmute"). Footer "Mixer" (macOS has no per-app mixer → Sound settings).

private final class VFPanel: M7FlippedView {
    struct Column { let kind: AudioOutput.Kind; let cell: CGFloat }
    var k: CGFloat = 1
    var columns: [Column] = []
    var separatorX: CGFloat?
    var onDeviceMenu: ((AudioOutput.Kind, NSPoint) -> Void)?

    private enum Part: Equatable { case icon(Int), slider(Int), mute(Int) }
    private var hover: Part?
    private var pressed: Part?
    private var dragging: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    // Geometry in content px (scaled).
    private let grooveTop: CGFloat = 67, grooveH: CGFloat = 115, handleH: CGFloat = 10
    private func iconRect(_ c: Column) -> NSRect { NSRect(x: r(c.cell + 1), y: r(17), width: r(32), height: r(32)) }
    private func iconHit(_ c: Column) -> NSRect { iconRect(c).insetBy(dx: -r(4), dy: -r(4)) }
    private func grooveRect(_ c: Column) -> NSRect { NSRect(x: r(c.cell + 11), y: r(grooveTop), width: r(6), height: r(grooveH)) }
    private func sliderHit(_ c: Column) -> NSRect { NSRect(x: r(c.cell + 2), y: r(grooveTop - 4), width: r(30), height: r(grooveH + 8)) }
    private func muteRect(_ c: Column) -> NSRect { NSRect(x: r(c.cell + 1), y: r(202), width: r(32), height: r(30)) }
    private func handleRect(_ c: Column, _ v: CGFloat) -> NSRect {
        NSRect(x: r(c.cell + 9), y: r(grooveTop) + ((1 - v) * (r(grooveH) - r(handleH))).rounded(), width: r(18), height: r(handleH))
    }

    private func value(_ i: Int) -> CGFloat? { AudioOutput.volume(columns[i].kind).map { CGFloat($0) } }
    private func muted(_ i: Int) -> Bool { AudioOutput.muted(columns[i].kind) }
    private func deviceCount(_ i: Int) -> Int { AudioOutput.devices(columns[i].kind).count }

    private func part(at p: NSPoint) -> Part? {
        for (i, c) in columns.enumerated() {
            if iconHit(c).contains(p), deviceCount(i) > 1 { return .icon(i) }
            if sliderHit(c).contains(p) { return .slider(i) }
            if muteRect(c).contains(p) { return .mute(i) }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let p = part(at: convert(event.locationInWindow, from: nil))
        if p != hover { hover = p; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    private func setValue(from p: NSPoint, column i: Int) {
        let g = grooveRect(columns[i])
        let travel = g.height - r(handleH)
        let v = 1 - (p.y - g.minY - r(handleH) / 2) / max(1, travel)
        let step = (max(0, min(1, v)) * 100).rounded() / 100      // 1 % steps
        AudioOutput.setVolume(Float(step), columns[i].kind)
        if muted(i) { AudioOutput.setMuted(false, columns[i].kind) }   // dragging unmutes, like the original
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressed = part(at: p)
        if case .slider(let i)? = pressed, value(i) != nil {
            dragging = i
            setValue(from: p, column: i)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let i = dragging else { return }
        setValue(from: convert(event.locationInWindow, from: nil), column: i)
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { pressed = nil; dragging = nil; needsDisplay = true }
        guard let was = pressed, part(at: p) == was else { return }
        switch was {
        case .mute(let i): AudioOutput.setMuted(!muted(i), columns[i].kind)
        case .icon(let i):
            let rect = iconHit(columns[i])
            onDeviceMenu?(columns[i].kind, NSPoint(x: rect.minX, y: rect.maxY))
        case .slider: break
        }
    }
    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = columns.indices.first(where: { NSRect(x: r(columns[$0].cell), y: 0, width: r(34), height: bounds.height).contains(p) }),
              let v = value(i), event.scrollingDeltaY != 0 else { return }
        let dir: CGFloat = event.scrollingDeltaY > 0 ? 1 : -1
        let inverted: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        AudioOutput.setVolume(Float(max(0, min(1, v + 0.05 * dir * inverted))), columns[i].kind)   // ±5 % per step
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let sx = separatorX {
            TF.hex(0xd6e1dd).setFill()
            NSRect(x: r(sx), y: r(16), width: 1, height: r(215)).fill()
        }
        for (i, c) in columns.enumerated() {
            // Device icon (+ tool-button frame on hover / press when it opens the device menu).
            if hover == .icon(i) || pressed == .icon(i) {
                Menu7Assets.draw(Menu7Assets.frame(pressed == .icon(i) ? "wf-tbtn-pressed" : "wf-tbtn-hover", 3, 3, 3, 3), in: iconHit(c))
            }
            var ir = iconRect(c)
            if pressed == .icon(i) { ir.origin.x += 1 }
            Menu7Assets.draw(Menu7Assets.image(c.kind == .output ? "wf-vol-speakers" : "wf-vol-mic"), in: ir)

            // Slider (half transparent while muted or without volume control).
            let v = value(i)
            let alpha: CGFloat = (muted(i) || v == nil) ? 0.5 : 1
            let g = grooveRect(c)
            Menu7Assets.draw(Menu7Assets.frame("wf-vol-groove", 1, 1, 1, 1), in: g, alpha: alpha)
            let tx = g.maxX, tw = r(13)
            TF.hex(0xcfcfcf, alpha).setFill()
            for y in [g.minY, (g.minY + r(56)), g.maxY - 1] { NSRect(x: tx, y: y, width: tw, height: 1).fill() }
            // "bgthing": full width at the top, narrowing towards the bottom (#d6dfe4 at 91 %).
            let wedge = NSBezierPath()
            wedge.move(to: NSPoint(x: tx, y: g.minY))
            wedge.line(to: NSPoint(x: tx + r(10), y: g.minY))
            wedge.line(to: NSPoint(x: tx + r(2), y: g.maxY))
            wedge.line(to: NSPoint(x: tx, y: g.maxY))
            wedge.close()
            TF.hex(0xd6dfe4, 0.914 * alpha).setFill()
            wedge.fill()

            let hv = v ?? 0
            let hr = handleRect(c, hv)
            let state = dragging == i || pressed == .slider(i) ? "pressed" : hover == .slider(i) ? "focused" : "normal"
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowOffset = NSSize(width: 1, height: -1)
            sh.shadowBlurRadius = 0
            sh.shadowColor = NSColor(white: 0, alpha: 0x30 / 255.0)
            sh.set()
            Menu7Assets.draw(Menu7Assets.image("wf-vol-scursor-\(state)"), in: hr, alpha: alpha)
            NSGraphicsContext.restoreGraphicsState()

            // Value tooltip left of the handle while dragging (no "%").
            if dragging == i {
                let text = "\(Int((hv * 100).rounded()))"
                let font = Menu7Font.font(size: 12 * k)
                let tw = max(r(21), TF.width(text, font) + r(8))
                let tip = NSRect(x: hr.minX - tw - r(2), y: hr.minY - r(5), width: tw, height: r(20))
                let path = NSBezierPath(roundedRect: tip.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                NSGradient(starting: TF.hex(0xfefefe), ending: TF.hex(0xe4e5f0))?.draw(in: path, angle: -90)
                TF.hex(0x767676).setStroke()
                path.stroke()
                TF.text(text, in: tip, font: font, color: .black, alignment: .center)
            }

            // Mute button.
            let mr = muteRect(c)
            if pressed == .mute(i) {
                Menu7Assets.draw(Menu7Assets.frame("wf-tbtn-pressed", 3, 3, 3, 3), in: mr)
            } else if hover == .mute(i) {
                Menu7Assets.draw(Menu7Assets.frame("wf-tbtn-hover", 3, 3, 3, 3), in: mr)
            }
            let isMuted = muted(i)
            let iw = r(isMuted ? 14 : 17), ih = r(16)
            var mi = NSRect(x: (mr.midX - iw / 2).rounded(), y: (mr.midY - ih / 2).rounded(), width: iw, height: ih)
            if pressed == .mute(i) { mi.origin.x += 1 }
            Menu7Assets.draw(Menu7Assets.image(isMuted ? "wf-vol-unmute" : "wf-vol-mute"), in: mi)
        }
    }
}

final class VolumeFlyoutController: NSObject {
    private let host = TrayFlyoutHost(footer: "Mixer")
    private let panel = VFPanel()
    private var timer: Timer?
    var onStateChange: (() -> Void)?

    var isVisible: Bool { host.isVisible }

    override init() {
        super.init()
        host.root.addSubview(panel)
        host.footer.onClick = { [weak self] in
            TF.openSettings("com.apple.Sound-Settings.extension")
            self?.host.hide()
        }
        host.onHide = { [weak self] in self?.timer?.invalidate(); self?.timer = nil }
        panel.onDeviceMenu = { [weak self] kind, point in self?.deviceMenu(kind, at: point) }
    }

    func toggle(anchor: NSRect, on screen: NSScreen) {
        if host.isVisible { host.hide() } else { show(anchor: anchor, on: screen) }
    }

    func show(anchor: NSRect, on screen: NSScreen) {
        let hasInput = AudioOutput.defaultDevice(.input) != nil
        let width: CGFloat = hasInput ? 149 : 68
        host.pinMargin = width <= 68 ? 2 : 6
        host.setMainSize(width: width, height: 289)
        panel.k = host.k
        panel.columns = hasInput ? [.init(kind: .output, cell: 17), .init(kind: .input, cell: 98)] : [.init(kind: .output, cell: 17)]
        panel.separatorX = hasInput ? 74 : nil
        panel.frame = NSRect(x: 8, y: 8, width: host.W - 16, height: host.footerTop - 8)
        panel.needsDisplay = true
        host.show(anchor: anchor, on: screen)
        // Follow changes made elsewhere (keyboard, Control Center).
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.panel.needsDisplay = true
            self?.onStateChange?()
        }
    }

    /// Device list of the icon (checked = default), like the original's QMenu.
    private func deviceMenu(_ kind: AudioOutput.Kind, at point: NSPoint) {
        let menu = NSMenu()
        let current = AudioOutput.defaultDeviceID(kind)
        for d in AudioOutput.devices(kind) {
            let item = NSMenuItem(title: d.name + "      ", action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.state = d.id == current ? .on : .off
            item.representedObject = (d, kind)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: panel)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let (d, kind) = sender.representedObject as? (AudioOutput.Device, AudioOutput.Kind) else { return }
        AudioOutput.setDefault(d, kind)
        panel.needsDisplay = true
        onStateChange?()
    }
}
