import AppKit

/// The round Windows-7 "Start" orb. Drawn vectorially (glossy sphere + 4-colour flag) so the
/// three states — idle, hover (pulsing Aero glow) and pressed (depressed + bright) — animate
/// smoothly. If `orb.png` is bundled in Resources it is used as the sphere instead.
final class StartOrbButton: NSControl {
    var onRightClick: (() -> Void)?

    private var hovering = false
    private var pressed = false

    // Animated state, eased each tick toward its target.
    private var glow: CGFloat = 0          // 0…1 hover glow
    private var press: CGFloat = 0          // 0…1 pressed depth
    private var phase: CGFloat = 0          // free-running phase for the pulse
    private var anim: Timer?

    private let orbImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "orb", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Interaction

    override func mouseEntered(with event: NSEvent) { hovering = true; startAnim() }
    override func mouseExited(with event: NSEvent) { hovering = false; startAnim() }

    override func mouseDown(with event: NSEvent) {
        pressed = true; startAnim()
        if let action = action { NSApp.sendAction(action, to: target, from: self) }
    }
    override func mouseUp(with event: NSEvent) { pressed = false; startAnim() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    // MARK: - Animation loop

    private func startAnim() {
        guard anim == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        anim = t
    }

    private func tick() {
        let glowTarget: CGFloat = (hovering || pressed) ? 1 : 0
        glow += (glowTarget - glow) * 0.12
        let pressTarget: CGFloat = pressed ? 1 : 0
        press += (pressTarget - press) * 0.16
        if hovering { phase += 0.08 }

        needsDisplay = true

        // Stop the timer once everything has settled (and we're not pulsing).
        if !hovering && !pressed && glow < 0.01 && press < 0.01 {
            glow = 0; press = 0
            anim?.invalidate(); anim = nil
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The orb art sits inside transparent padding, so we crop to the content and let it
        // fill the bar height (overflowing slightly into the clipped glow margin).
        let base = orbImage != nil ? bounds.height * 1.18 : min(bounds.width - 4, bounds.height - 2)
        let d = base * (1 - 0.05 * press)                 // depress slightly when pressed
        let rect = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)

        if let img = orbImage {
            drawImageOrb(img, in: rect)
        } else {
            drawGlow(around: rect)
            drawVectorOrb(in: rect)
        }
    }

    /// orb.png is one image stacked vertically in three states:
    /// top = normal, middle = hover, bottom = pressed. We crossfade between them.
    private func drawImageOrb(_ img: NSImage, in rect: NSRect) {
        // Three layers stacked normal → hover → pressed; each cross-fades over the one below,
        // so the orb glides smoothly through the states in both directions.
        drawThird(img, 0, in: rect, alpha: 1)                  // normal (base)
        if glow > 0.001 { drawThird(img, 1, in: rect, alpha: glow) }    // hover fades in over normal
        if press > 0.001 { drawThird(img, 2, in: rect, alpha: press) }  // pressed fades in over hover
    }

    private func drawThird(_ img: NSImage, _ index: Int, in rect: NSRect, alpha: CGFloat) {
        let thirdH = img.size.height / 3
        // Crop away most of the transparent padding (measured ~20px in a 106px tile; keep a few
        // pixels for the hover glow). Image origin is bottom-left, so index 0 (top) is highest.
        let inset = img.size.width * (14.0 / 106.0)
        let y0 = thirdH * CGFloat(2 - index)
        let src = NSRect(x: inset, y: y0 + inset,
                         width: img.size.width - 2 * inset, height: thirdH - 2 * inset)
        img.draw(in: rect, from: src, operation: .sourceOver, fraction: max(0, min(1, alpha)))
    }

    private func drawGlow(around rect: NSRect) {
        guard glow > 0.01 else { return }
        let pulse = 1 + 0.12 * sin(phase) * glow
        let spread = (6 + 10 * glow) * pulse
        let glowRect = rect.insetBy(dx: -spread, dy: -spread)
        let path = NSBezierPath(ovalIn: glowRect)
        NSGraphicsContext.current?.saveGraphicsState()
        let cyan = NSColor(calibratedRed: 0.55, green: 0.90, blue: 1.0, alpha: 0.55 * glow)
        cyan.setFill()
        path.fill()
        // Soft shadow used as a bloom.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 0.5, green: 0.88, blue: 1.0, alpha: 0.8 * glow)
        shadow.shadowBlurRadius = 14 * glow
        shadow.set()
        NSColor(calibratedWhite: 1, alpha: 0.0).setFill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawVectorOrb(in rect: NSRect) {
        let path = NSBezierPath(ovalIn: rect)

        // Outer dark rim for depth.
        NSColor(calibratedWhite: 0.05, alpha: 0.55).setStroke()
        path.lineWidth = 2
        path.stroke()

        // Blue glass sphere.
        let topB = pressed ? Theme.orbBottom : NSColor(calibratedRed: 0.52, green: 0.80, blue: 1.0, alpha: 1)
        let midB = NSColor(calibratedRed: 0.13, green: 0.48, blue: 0.85, alpha: 1)
        let botB = pressed ? NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.95, alpha: 1) : Theme.orbBottom
        let sphere = NSGradient(colors: [topB, midB, botB], atLocations: [0, 0.5, 1], colorSpace: .sRGB)
        sphere?.draw(in: path, angle: -90)

        // The four-pane waving flag.
        drawFlag(in: rect)

        // Glossy top highlight.
        let glossRect = NSRect(x: rect.minX + d(rect) * 0.12, y: rect.midY + d(rect) * 0.04,
                               width: d(rect) * 0.76, height: d(rect) * 0.42)
        let gloss = NSBezierPath(ovalIn: glossRect)
        let g = NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.55 + 0.30 * glow),
                                    NSColor(calibratedWhite: 1, alpha: 0.0)])
        g?.draw(in: gloss, angle: -90)

        // Bright inner ring.
        NSColor(calibratedWhite: 1, alpha: 0.5 + 0.4 * glow).setStroke()
        let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
        inner.lineWidth = 1
        inner.stroke()
    }

    private func d(_ r: NSRect) -> CGFloat { r.width }

    /// Four coloured panes (red/green/blue/yellow) arranged as the Windows flag, slightly tilted.
    private func drawFlag(in rect: NSRect) {
        let cx = rect.midX, cy = rect.midY
        let s = rect.width * 0.17       // pane size
        let gap = s * 0.20
        let tilt: CGFloat = 6 * (.pi / 180)

        let colors = [
            NSColor(calibratedRed: 0.96, green: 0.30, blue: 0.20, alpha: 1),   // red  (top-left)
            NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.18, alpha: 1),   // green(top-right)
            NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.95, alpha: 1),   // blue (bottom-left)
            NSColor(calibratedRed: 0.99, green: 0.80, blue: 0.10, alpha: 1),   // yellow(bottom-right)
        ]
        let offsets = [(-1.0, 1.0), (1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)]

        let ctx = NSGraphicsContext.current
        ctx?.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: cx, yBy: cy)
        transform.rotate(byRadians: tilt)
        transform.translateX(by: -cx, yBy: -cy)
        transform.concat()

        for (i, off) in offsets.enumerated() {
            let ox = cx + CGFloat(off.0) * (s / 2 + gap / 2)
            let oy = cy + CGFloat(off.1) * (s / 2 + gap / 2)
            let pane = NSRect(x: ox - s / 2, y: oy - s / 2, width: s, height: s)
            let p = NSBezierPath(roundedRect: pane, xRadius: s * 0.12, yRadius: s * 0.12)
            // Pane gradient for a glassy look.
            let c = colors[i]
            let grad = NSGradient(colors: [c.blended(withFraction: 0.35, of: .white) ?? c, c])
            grad?.draw(in: p, angle: -90)
            NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
            p.lineWidth = 1
            p.stroke()
        }
        ctx?.restoreGraphicsState()
    }
}
