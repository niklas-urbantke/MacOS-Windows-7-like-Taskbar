import AppKit

/// Flyouts über der Taskleiste. `anchor` ist das auslösende Element in Bildschirmkoordinaten.
/// Jedes show* toggelt: ist dasselbe Flyout schon offen, schließt es. Immer nur eins gleichzeitig.
/// Kalender und Medien gibt es in allen Profilen, das Aussehen folgt `FlyoutLook` (Win11 oder Aero).
enum Win11Flyouts {
    fileprivate enum Kind { case calendar, media }

    private static var panel: Win11FlyoutPanel?
    private static var kind: Kind?
    private static var anchor: NSRect = .zero
    private static var monitors: [Any] = []

    static func showCalendar(anchor: NSRect, screen: NSScreen) {
        // Win11: fest am rechten Bildschirmrand. Aero: rechtsbündig über der Uhr (wie Windows 7).
        let placement: Win11FlyoutPanel.Placement = FlyoutLook.isAero ? .rightAligned(anchor.maxX) : .right
        toggle(.calendar, anchor: anchor, screen: screen, placement: placement) { Win11CalendarFlyout(frame: .zero) }
    }
    static func showMedia(anchor: NSRect, screen: NSScreen) {
        toggle(.media, anchor: anchor, screen: screen, placement: .centered(anchor.midX)) {
            Win11MediaFlyout(frame: .zero)
        }
    }
    static func closeAll() { close(animated: true) }
    static var isShown: Bool { panel != nil }

    // MARK: - Internals

    private static func toggle(_ k: Kind, anchor a: NSRect, screen: NSScreen,
                               placement: Win11FlyoutPanel.Placement,
                               make: () -> Win11FlyoutContent) {
        if kind == k, panel != nil { close(animated: true); return }
        close(animated: false)
        let p = Win11FlyoutPanel(content: make())
        panel = p
        kind = k
        anchor = a
        p.present(on: screen, placement: placement)
        installMonitors()
    }

    private static func close(animated: Bool) {
        removeMonitors()
        guard let p = panel else { return }
        panel = nil
        kind = nil
        p.dismiss(animated: animated)
    }

    /// Clicks outside close the flyout: global monitor for other apps, local one for our own
    /// windows. A click on the anchor itself is left to the element's toggle (otherwise it would
    /// close here and reopen right away). Esc closes as well.
    private static func installMonitors() {
        removeMonitors()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { _ in close(animated: true) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { e in
            guard let p = panel else { return e }
            if e.window === p { return e }
            let pt = e.window.map { $0.convertPoint(toScreen: e.locationInWindow) } ?? NSEvent.mouseLocation
            if e.type == .leftMouseDown && anchor.contains(pt) { return e }
            close(animated: true)
            return e
        }) {
            monitors.append(l)
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in
            if e.keyCode == 53 { close(animated: true) }
        }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            if e.keyCode == 53, panel != nil { close(animated: true); return nil }
            return e
        }) {
            monitors.append(l)
        }
    }

    private static func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }
}

// MARK: - Panel

/// Base class for flyout content. Flipped (top-down layout, the panel grows upwards).
class Win11FlyoutContent: NSView {
    var preferredSize: NSSize { NSSize(width: 360, height: 200) }
    /// Set by the panel; call when `preferredSize` changed.
    var onSizeChange: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }
    func layoutContent() {}
    func willShow() {}
    func didHide() {}
}

/// Randloses, nicht aktivierendes Panel mit der Fläche des Profils (Blur + Acryl-Tönung bzw.
/// Aero-Glas, Rand, Schatten).
final class Win11FlyoutPanel: NSPanel {
    /// `right`: am rechten Bildschirmrand. `centered`: mittig über x. `rightAligned`: rechte Kante bei x.
    enum Placement { case right, centered(CGFloat), rightAligned(CGFloat) }

    let content: Win11FlyoutContent
    private let blur = NSVisualEffectView()
    private let background = Win11FlyoutSurface()
    private let stroke = Win11FlyoutStroke()
    private var placement: Placement = .right
    private var screenFrame: NSRect = .zero
    /// Look chosen when the panel was created (the profile does not change while it is open).
    private let aero = FlyoutLook.isAero

    private var gap: CGFloat { aero ? 8 : 12 }
    private static let slide: CGFloat = 12

    init(content: Win11FlyoutContent) {
        self.content = content
        let size = content.preferredSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isFloatingPanel = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        appearance = Theme.nsAppearance

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        for v in [blur, background, content, stroke] as [NSView] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        FlyoutLook.configureBlur(blur)
        contentView = root
        content.onSizeChange = { [weak self] in self?.relayout() }
    }

    // Never steal focus from the frontmost app (Esc is caught by the key monitors).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func targetFrame(for size: NSSize) -> NSRect {
        let sf = screenFrame
        let y = sf.minY + Theme.barHeight + gap
        var x: CGFloat
        switch placement {
        case .right:
            x = sf.maxX - gap - size.width
        case .centered(let mid):
            x = min(max(mid - size.width / 2, sf.minX + gap), sf.maxX - gap - size.width)
        case .rightAligned(let edge):
            x = min(max(edge - size.width, sf.minX + gap), sf.maxX - gap - size.width)
        }
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    func present(on screen: NSScreen, placement: Placement) {
        self.placement = placement
        screenFrame = screen.frame
        // willShow first: it may load content that changes the preferred size.
        content.willShow()
        let target = targetFrame(for: content.preferredSize)
        alphaValue = 0
        if reduceMotion || aero {
            // Aero flyouts only fade in (Vista / Windows 7 do not slide).
            setFrame(target, display: true)
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = aero && !reduceMotion ? 0.15 : 0.12
                self.animator().alphaValue = 1
            }, completionHandler: { self.invalidateShadow() })
        } else {
            // Slide up a little and fade in, like the Win11 flyouts.
            setFrame(target.offsetBy(dx: 0, dy: -Self.slide), display: true)
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
                self.animator().setFrame(target, display: true)
                self.animator().alphaValue = 1
            }, completionHandler: { self.invalidateShadow() })
        }
    }

    func dismiss(animated: Bool) {
        content.didHide()
        guard animated else { orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            self.animator().alphaValue = 0
        }, completionHandler: { self.orderOut(nil) })
    }

    /// Content changed its preferred size: keep the bottom edge, grow/shrink upwards.
    private func relayout() {
        let target = targetFrame(for: content.preferredSize)
        guard target != frame else { return }
        if reduceMotion || !isVisible {
            setFrame(target, display: true)
            invalidateShadow()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(target, display: true)
            }, completionHandler: { self.invalidateShadow() })
        }
    }

    /// Stretchable rounded mask for the behind-window blur (also used by the window preview).
    static func roundedMask(radius r: CGFloat) -> NSImage {
        let side = 2 * r + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

/// Fläche des Flyouts (Acryl-Tönung bzw. Aero-Glas, Farbe zur Zeichenzeit). Auch für die Fenstervorschau.
final class Win11FlyoutSurface: NSView {
    override func draw(_ dirtyRect: NSRect) { FlyoutLook.drawSurface(in: bounds) }
}

/// Rand über dem Inhalt; lässt Klicks durch. Auch für die Fenstervorschau.
final class Win11FlyoutStroke: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { FlyoutLook.drawStroke(in: bounds) }
}

// MARK: - Look: Win11 or Aero

/// Aussehen der Flyouts und der Fenstervorschau passend zum Stil-Profil: Win11 (flach, Acryl) oder
/// Aero (Glas mit Verlauf, heller Innenkante und Rand, für Vista und Windows 7). Alles wird zur
/// Zeichenzeit gelesen, denn Farbmodus und Profil können sich jederzeit ändern. Im Win11-Profil
/// liefert jede Funktion genau das bisherige Win11-Aussehen.
enum FlyoutLook {
    static var isAero: Bool { !Theme.isWin11 }
    private static var isWin7: Bool { Theme.taskbarStyle == .win7 }
    private static var dark: Bool { Theme.isDark }

    static var panelRadius: CGFloat { isAero ? 6 : Theme.Win11.panelRadius }
    /// Radius of the hover field of small controls.
    static var controlRadius: CGFloat { isAero ? 3 : 4 }

    static var textPrimary: NSColor { isAero ? Theme.Aero.text : Theme.Win11.textPrimary }
    static var textSecondary: NSColor { isAero ? Theme.Aero.secondaryText : Theme.Win11.textSecondary }
    static var textDisabled: NSColor { isAero ? Theme.Aero.disabledText : Theme.Win11.textDisabled }
    static var accent: NSColor { isAero ? Theme.Aero.accent : Theme.Win11.accent }
    /// Subtle tile behind placeholders (minimised window, missing cover).
    static var tileFill: NSColor { isAero ? Theme.Aero.pressed : Theme.Win11.controlFill }
    static var tileStroke: NSColor {
        isAero ? (dark ? NSColor(calibratedWhite: 1, alpha: 0.14) : NSColor(calibratedWhite: 0, alpha: 0.12))
               : Theme.Win11.controlStroke
    }

    /// Frost layer behind the panel. Aero: the classic frost (strength like the start menu).
    static func configureBlur(_ v: NSVisualEffectView) {
        if isAero {
            v.material = .underWindowBackground
            v.blendingMode = .behindWindow
            v.state = .active
            v.appearance = Theme.nsAppearance
            v.alphaValue = Theme.menuBlur
            v.isHidden = false
        } else {
            Theme.Win11.configureBlur(v, for: .flyout)   // hides itself when Acryl is off
        }
        v.maskImage = Win11FlyoutPanel.roundedMask(radius: panelRadius)
    }

    /// Vertical gradient `colors[0]` (top) → last (bottom) in `path`, in flipped and unflipped views.
    static func verticalGradient(_ colors: [NSColor], in path: NSBezierPath) {
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        NSGradient(colors: colors)?.draw(in: path, angle: flipped ? 90 : -90)
    }

    private static func stroke(_ rect: NSRect, radius r: CGFloat, _ color: NSColor) {
        color.setStroke()
        let p = NSBezierPath(roundedRect: rect, xRadius: max(0, r), yRadius: max(0, r))
        p.lineWidth = 1
        p.stroke()
    }

    /// Panel fill. Aero: glass gradient, Windows 7 with the original Aero streaks, Vista with a
    /// gloss over the upper half.
    static func drawSurface(in b: NSRect) {
        let r = panelRadius
        guard isAero else {
            Win11TrayDraw.fill(b, radius: r, Theme.Win11.surface(.flyout))
            return
        }
        let A = Theme.Aero.self
        let path = NSBezierPath(roundedRect: b, xRadius: r, yRadius: r)
        verticalGradient([A.panelTop, A.panelBottom], in: path)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        if isWin7, let streaks = ThemeAssets.image("AeroPeek"), streaks.size.width > 0, streaks.size.height > 0 {
            // Aspect fill, anchored at the top left like the real glass.
            let s = streaks.size
            let k = max(b.width / s.width, b.height / s.height)
            let w = s.width * k, h = s.height * k
            let y = flipped ? b.minY : b.maxY - h
            NSGraphicsContext.current?.imageInterpolation = .high
            streaks.draw(in: NSRect(x: b.minX, y: y, width: w, height: h), from: .zero,
                         operation: .sourceOver, fraction: dark ? 1 : 0.8, respectFlipped: true, hints: nil)
        } else {
            let gh = (b.height * 0.45).rounded()
            let gloss = NSRect(x: b.minX, y: flipped ? b.minY : b.maxY - gh, width: b.width, height: gh)
            verticalGradient([NSColor(calibratedWhite: 1, alpha: dark ? 0.14 : 0.45),
                              NSColor(calibratedWhite: 1, alpha: dark ? 0.02 : 0.05)],
                             in: NSBezierPath(rect: gloss))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Panel border. Aero: outer edge plus the bright inner highlight line.
    static func drawStroke(in b: NSRect) {
        let r = panelRadius
        guard isAero else {
            stroke(b.insetBy(dx: 0.5, dy: 0.5), radius: r - 0.5, Theme.Win11.panelStroke)
            return
        }
        stroke(b.insetBy(dx: 0.5, dy: 0.5), radius: r - 0.5, Theme.Aero.stroke)
        stroke(b.insetBy(dx: 1.5, dy: 1.5), radius: r - 1.5, Theme.Aero.innerHighlight)
    }

    /// Hover / pressed field of a control or card. Win11: flat fill. Aero: glass (light gradient,
    /// fine edge, inner highlight).
    static func drawHover(_ rect: NSRect, radius: CGFloat? = nil, pressed: Bool = false) {
        let r = radius ?? controlRadius
        guard isAero else {
            Win11TrayDraw.fill(rect, radius: r, pressed ? Theme.Win11.pressedFill : Theme.Win11.hoverFill)
            return
        }
        let A = Theme.Aero.self
        let outer = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: outer, xRadius: max(0, r - 0.5), yRadius: max(0, r - 0.5))
        if pressed {
            verticalGradient([A.pressed.withAlphaComponent(A.pressed.alphaComponent * 1.6), A.pressed], in: path)
        } else {
            let h = A.hover
            verticalGradient([h, h.withAlphaComponent(h.alphaComponent * 0.35)], in: path)
        }
        stroke(outer, radius: r - 0.5, A.stroke)
        if !pressed, rect.width > 4, rect.height > 4 {
            stroke(rect.insetBy(dx: 1.5, dy: 1.5), radius: r - 1.5, A.innerHighlight.withAlphaComponent(
                A.innerHighlight.alphaComponent * (dark ? 1 : 0.8)))
        }
    }

    /// Hover field of the close button (×): red. Aero: red glass like the Windows 7 caption button.
    static func drawCloseHover(_ rect: NSRect, radius: CGFloat) {
        guard isAero else { Win11TrayDraw.fill(rect, radius: radius, NSColor.systemRed); return }
        let outer = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: outer, xRadius: radius - 0.5, yRadius: radius - 0.5)
        verticalGradient([NSColor(calibratedRed: 0.93, green: 0.52, blue: 0.46, alpha: 1),
                          NSColor(calibratedRed: 0.80, green: 0.20, blue: 0.14, alpha: 1),
                          NSColor(calibratedRed: 0.70, green: 0.10, blue: 0.06, alpha: 1)], in: path)
        stroke(outer, radius: radius - 0.5, NSColor(calibratedRed: 0.35, green: 0.04, blue: 0.02, alpha: 0.85))
        stroke(rect.insetBy(dx: 1.5, dy: 1.5), radius: radius - 1.5, NSColor(calibratedWhite: 1, alpha: 0.40))
    }

    /// Cover placeholder (`music.note` on a subtle tile).
    static func drawCoverPlaceholder(in rect: NSRect, radius: CGFloat, glyphSize: CGFloat) {
        guard isAero else {
            Win11TrayDraw.drawCoverPlaceholder(in: rect, radius: radius, glyphSize: glyphSize)
            return
        }
        Win11TrayDraw.fill(rect, radius: radius, tileFill)
        stroke(rect.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5, tileStroke)
        if let note = Win11TrayDraw.symbol(["music.note"], pointSize: glyphSize, color: textSecondary) {
            Win11TrayDraw.draw(note, centeredIn: rect)
        }
    }

    /// Thin dark frame around a cover or thumbnail (Aero only; Win11 draws them borderless).
    static func drawImageFrame(_ rect: NSRect, radius: CGFloat) {
        guard isAero else { return }
        stroke(rect.insetBy(dx: -0.5, dy: -0.5), radius: radius + 0.5,
               NSColor(calibratedWhite: 0, alpha: dark ? 0.45 : 0.25))
    }

    /// Text / glyphs on an accent fill.
    static var onAccent: NSColor { isAero ? .white : Theme.Win11.onAccent }

    /// Accent field (today in the calendar, primary buttons). Win11: flat, a bit lighter on hover
    /// and press. Aero: glossy accent glass with dark edge and bright inner line.
    static func drawAccentFill(_ rect: NSRect, radius r: CGFloat, hovered: Bool = false, pressed: Bool = false) {
        guard isAero else {
            var fill = Theme.Win11.accent
            if pressed { fill = fill.withAlphaComponent(0.8) } else if hovered { fill = fill.withAlphaComponent(0.9) }
            Win11TrayDraw.fill(rect, radius: r, fill)
            return
        }
        var a = Theme.Aero.accent
        if pressed { a = a.blended(withFraction: 0.18, of: .black) ?? a }
        else if hovered { a = a.blended(withFraction: 0.15, of: .white) ?? a }
        let outer = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: outer, xRadius: max(0, r - 0.5), yRadius: max(0, r - 0.5))
        verticalGradient([a.blended(withFraction: pressed ? 0.2 : 0.45, of: .white) ?? a, a,
                          a.blended(withFraction: 0.2, of: .black) ?? a], in: path)
        stroke(outer, radius: r - 0.5, (a.blended(withFraction: 0.55, of: .black) ?? a).withAlphaComponent(0.85))
        if !pressed, rect.width > 4, rect.height > 4 {
            stroke(rect.insetBy(dx: 1.5, dy: 1.5), radius: r - 1.5, NSColor(calibratedWhite: 1, alpha: 0.35))
        }
    }

    /// Horizontal separator in a flipped view. Win11: 1 px hairline. Aero: etched (dark over light).
    static func drawSeparator(x: CGFloat, y: CGFloat, width: CGFloat) {
        guard isAero else {
            Theme.Win11.hairline.setFill()
            NSRect(x: x, y: y, width: width, height: 1).fill()
            return
        }
        NSColor(calibratedWhite: 0, alpha: dark ? 0.35 : 0.14).setFill()
        NSRect(x: x, y: y, width: width, height: 1).fill()
        NSColor(calibratedWhite: 1, alpha: dark ? 0.10 : 0.60).setFill()
        NSRect(x: x, y: y + 1, width: width, height: 1).fill()
    }
}

// MARK: - Shared controls

/// Text row button with optional icon and hover field (Win11 flat or Aero glass).
final class Win11FlyoutRowButton: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 13)
    var color: () -> NSColor = { FlyoutLook.textPrimary }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var iconSize: CGFloat = 16
    var centered = false
    var padding: CGFloat = 8
    var onClick: (() -> Void)?
    private var hovering = false
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let fire = pressed && inside
        pressed = false
        hovering = inside
        needsDisplay = true
        if fire { onClick?() }
    }

    private var titleString: NSAttributedString {
        Win11TrayDraw.text(title, font: font, color: color())
    }
    private var iconBlock: CGFloat { icon != nil ? iconSize + 6 : 0 }
    /// Width that fits icon + title.
    var fittingWidth: CGFloat { 2 * padding + iconBlock + ceil(titleString.size().width) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering { FlyoutLook.drawHover(bounds, pressed: pressed) }
        let s = titleString
        let tw = min(ceil(s.size().width), bounds.width - 2 * padding - iconBlock)
        var x = centered ? ((bounds.width - iconBlock - tw) / 2).rounded() : padding
        if let icon {
            icon.draw(in: NSRect(x: x, y: ((bounds.height - iconSize) / 2).rounded(), width: iconSize, height: iconSize),
                      from: .zero, operation: .sourceOver, fraction: pressed ? 0.7 : 1, respectFlipped: true, hints: nil)
            x += iconBlock
        }
        let th = ceil(s.size().height)
        s.draw(in: NSRect(x: x, y: ((bounds.height - th) / 2).rounded(), width: max(0, tw), height: th))
    }
}

/// Regler: Spur, gefüllter Anteil in Akzentfarbe, runder Daumen. Win11 flach mit Akzentpunkt,
/// Aero als Glasspur mit gläsernem Knopf. Klicken springt, Ziehen folgt der Maus.
final class Win11Slider: NSView {
    /// 0…1
    var value: Double = 0 { didSet { needsDisplay = true } }
    /// Called while clicking / dragging.
    var onChange: ((Double) -> Void)?
    /// Called on mouse up.
    var onCommit: ((Double) -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }
    private(set) var isDragging = false
    private var hovering = false

    private let thumbDiameter: CGFloat = 20
    private let trackHeight: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    private var trackRect: NSRect {
        let r = thumbDiameter / 2
        return NSRect(x: r, y: ((bounds.height - trackHeight) / 2).rounded(),
                      width: max(0, bounds.width - 2 * r), height: trackHeight)
    }

    private func setValue(from event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = trackRect
        guard t.width > 0 else { return }
        value = Double(max(0, min(1, (p.x - t.minX) / t.width)))
        onChange?(value)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        setValue(from: event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        setValue(from: event)
    }
    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        hovering = bounds.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
        onCommit?(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        if FlyoutLook.isAero { drawAero(); return }
        let W = Theme.Win11.self
        let t = trackRect
        let r = trackHeight / 2
        Win11TrayDraw.fill(t, radius: r, W.controlFill)
        W.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: t.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        border.lineWidth = 1
        border.stroke()

        let v = CGFloat(max(0, min(1, value)))
        let cx = t.minX + t.width * v
        let accent = isEnabled ? W.accent : W.textDisabled
        if cx > t.minX {
            Win11TrayDraw.fill(NSRect(x: t.minX, y: t.minY, width: cx - t.minX, height: t.height), radius: r, accent)
        }

        // Thumb: outer disc with a thin border, inner accent dot (grows on hover, shrinks on press).
        let d = thumbDiameter
        let outer = NSRect(x: (cx - d / 2).rounded(), y: ((bounds.height - d) / 2).rounded(), width: d, height: d)
        (Theme.win11Dark ? NSColor(calibratedWhite: 0.27, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(ovalIn: outer).fill()
        W.controlStroke.setStroke()
        let ring = NSBezierPath(ovalIn: outer.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        let inner: CGFloat = isDragging ? 8 : (hovering && isEnabled ? 14 : 12)
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: outer.midX - inner / 2, y: outer.midY - inner / 2,
                                    width: inner, height: inner)).fill()
    }

    /// Aero: recessed glass track (`track`), glossy accent fill, glass knob that picks up the accent on hover.
    private func drawAero() {
        let A = Theme.Aero.self
        let dark = Theme.isDark
        let h: CGFloat = 5
        let full = trackRect
        let t = NSRect(x: full.minX, y: ((bounds.height - h) / 2).rounded(), width: full.width, height: h)
        let r = h / 2
        let track = NSBezierPath(roundedRect: t, xRadius: r, yRadius: r)
        FlyoutLook.verticalGradient([A.track.withAlphaComponent(A.track.alphaComponent * 1.4), A.track], in: track)
        NSColor(calibratedWhite: 0, alpha: dark ? 0.35 : 0.20).setStroke()
        let border = NSBezierPath(roundedRect: t.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        border.lineWidth = 1
        border.stroke()

        let v = CGFloat(max(0, min(1, value)))
        let cx = t.minX + t.width * v
        let accent = isEnabled ? A.accent : A.disabledText
        if cx > t.minX + 1 {
            let fill = NSBezierPath(roundedRect: NSRect(x: t.minX, y: t.minY, width: cx - t.minX, height: t.height),
                                    xRadius: r, yRadius: r)
            FlyoutLook.verticalGradient([accent.blended(withFraction: 0.45, of: .white) ?? accent, accent,
                                         accent.blended(withFraction: 0.2, of: .black) ?? accent], in: fill)
        }

        // Glass knob: light gradient, dark edge, bright upper reflection; tinted with the accent on hover.
        let d: CGFloat = isDragging ? 13 : 14
        let knob = NSRect(x: (cx - d / 2).rounded(), y: ((bounds.height - d) / 2).rounded(), width: d, height: d)
        let path = NSBezierPath(ovalIn: knob)
        var top = NSColor(calibratedWhite: 1, alpha: 1)
        var bottom = NSColor(calibratedWhite: dark ? 0.72 : 0.80, alpha: 1)
        if isEnabled && (hovering || isDragging) {
            top = top.blended(withFraction: 0.25, of: A.accent) ?? top
            bottom = bottom.blended(withFraction: 0.45, of: A.accent) ?? bottom
        }
        if !isEnabled { top = top.withAlphaComponent(0.6); bottom = bottom.withAlphaComponent(0.6) }
        FlyoutLook.verticalGradient([top, bottom], in: path)
        let flipped = isFlipped
        let shine = NSRect(x: knob.minX + 3, y: flipped ? knob.minY + 1.5 : knob.midY - 0.5,
                           width: knob.width - 6, height: knob.height / 2 - 1)
        NSColor(calibratedWhite: 1, alpha: 0.55).setFill()
        NSBezierPath(ovalIn: shine).fill()
        NSColor(calibratedWhite: 0, alpha: dark ? 0.60 : 0.45).setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }
}

// MARK: - Calendar

/// Kalender-Flyout: Kopfzeile mit Datum, Monatsnavigation, Monatsraster (6 Wochen) und, mit
/// „Termine anzeigen“, darunter die Termine des ausgewählten Tages (EventKit, `CalendarEvents`).
/// Aussehen nach `FlyoutLook`: Win11 flach mit runden Tagen, Aero mit Glasfeldern.
final class Win11CalendarFlyout: Win11FlyoutContent {
    override var preferredSize: NSSize {
        NSSize(width: Self.width, height: gridTop + gridHeight + eventsHeight + 12)
    }

    /// Ausgewählter Tag (Start des Tages); die Terminliste zeigt diesen Tag.
    var selectedDate: Date {
        didSet { grid.selectedDate = selectedDate; reloadAgenda() }
    }
    /// Terminliste unter dem Raster (Höhe 0, solange „Termine anzeigen“ aus ist).
    private let agenda = Win11CalendarAgenda()
    /// Separator + agenda (0 without events).
    private var eventsHeight: CGFloat { agenda.preferredHeight > 0 ? agendaGap + agenda.preferredHeight : 0 }
    private let agendaGap: CGFloat = 8

    private static let width: CGFloat = 360
    private let cal: Calendar
    private var month: Date { didSet { grid.month = month; reloadDots(); needsDisplay = true } }

    private let header = Win11FlyoutRowButton(frame: .zero)
    private let upButton = Win11GlyphButton(symbol: "chevron.up")
    private let downButton = Win11GlyphButton(symbol: "chevron.down")
    private let grid: Win11CalendarGrid
    private var observer: Any?

    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "EEEE, d. MMMM"; return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "LLLL yyyy"; return f
    }()

    // Vertical layout (flipped).
    private let pad: CGFloat = 12
    private let headerTop: CGFloat = 10
    private let headerHeight: CGFloat = 40
    private var hairlineY: CGFloat { headerTop + headerHeight + 8 }
    private var monthRowTop: CGFloat { hairlineY + 9 }
    private let monthRowHeight: CGFloat = 36
    private var weekdayTop: CGFloat { monthRowTop + monthRowHeight + 4 }
    private let weekdayHeight: CGFloat = 32
    private var gridTop: CGFloat { weekdayTop + weekdayHeight }
    private let rowHeight: CGFloat = 40
    private var gridHeight: CGFloat { rowHeight * 6 }
    private var colWidth: CGFloat { (Self.width - 2 * pad) / 7 }
    private var agendaSeparatorY: CGFloat { gridTop + gridHeight + agendaGap - 2 }

    private var scrollAccumulator: CGFloat = 0

    override init(frame frameRect: NSRect) {
        var c = Calendar.current
        c.locale = Locale.current
        let today = c.startOfDay(for: Date())
        cal = c
        selectedDate = today
        month = c.date(from: c.dateComponents([.year, .month], from: today)) ?? today
        grid = Win11CalendarGrid(calendar: c)
        super.init(frame: frameRect)

        header.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        header.onClick = { [weak self] in self?.goToToday() }
        header.toolTip = "Zum heutigen Tag"
        upButton.onClick = { [weak self] in self?.step(-1) }
        downButton.onClick = { [weak self] in self?.step(1) }
        for b in [upButton, downButton] { b.pointSize = 12; b.weight = .medium; b.cornerRadius = FlyoutLook.controlRadius }
        upButton.toolTip = "Vorheriger Monat"
        downButton.toolTip = "Nächster Monat"
        grid.month = month
        grid.selectedDate = selectedDate
        grid.onSelect = { [weak self] day in self?.select(day) }
        agenda.onOpen = { event in
            CalendarEvents.shared.open(event)
            Win11Flyouts.closeAll()
        }
        agenda.onStateChange = { [weak self] in self?.reloadEvents() }
        for v in [header, upButton, downButton, grid, agenda] as [NSView] { addSubview(v) }
        updateHeader()
        reloadEvents()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func willShow() {
        goToToday()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: CalendarEvents.changedNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reloadEvents()
            }
        }
    }

    override func didHide() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    override func layoutContent() {
        let w = bounds.width
        header.frame = NSRect(x: pad, y: headerTop, width: w - 2 * pad, height: headerHeight)
        let bs: CGFloat = 32
        let by = monthRowTop + (monthRowHeight - bs) / 2
        downButton.frame = NSRect(x: w - pad - bs, y: by, width: bs, height: bs)
        upButton.frame = NSRect(x: downButton.frame.minX - 4 - bs, y: by, width: bs, height: bs)
        grid.frame = NSRect(x: pad, y: gridTop, width: w - 2 * pad, height: gridHeight)
        agenda.frame = NSRect(x: pad, y: gridTop + gridHeight + agendaGap, width: w - 2 * pad,
                              height: agenda.preferredHeight)
    }

    private func updateHeader() {
        header.title = Self.headerFormatter.string(from: Date())
        grid.today = cal.startOfDay(for: Date())
    }

    private func goToToday() {
        updateHeader()
        let today = cal.startOfDay(for: Date())
        selectedDate = today
        month = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
    }

    private func step(_ delta: Int) {
        if let m = cal.date(byAdding: .month, value: delta, to: month) { month = m }
    }

    private func select(_ day: Date) {
        selectedDate = day
        // A day of the neighbouring month switches to that month (like Win11).
        if !cal.isDate(day, equalTo: month, toGranularity: .month),
           let m = cal.date(from: cal.dateComponents([.year, .month], from: day)) {
            month = m
        }
    }

    // MARK: Events

    /// Dots and list (after a change of settings, access or calendar data).
    private func reloadEvents() {
        reloadDots()
        reloadAgenda()
    }

    /// Calendar colours per day for the 42 visible days (this month plus the neighbouring ones).
    private func reloadDots() {
        let ev = CalendarEvents.shared
        guard CalendarEvents.enabled, ev.isAuthorized else {
            grid.showsDots = false
            grid.dots = [:]
            return
        }
        var dots: [Date: [NSColor]] = [:]
        for delta in -1...1 {
            guard let m = cal.date(byAdding: .month, value: delta, to: month),
                  let first = cal.date(from: cal.dateComponents([.year, .month], from: m)) else { continue }
            for (day, colors) in ev.daysWithEvents(inMonthOf: first) {
                if let d = cal.date(byAdding: .day, value: day - 1, to: first) { dots[d] = colors }
            }
        }
        grid.showsDots = true
        grid.dots = dots
    }

    private func reloadAgenda() {
        let old = eventsHeight
        agenda.show(day: selectedDate, calendar: cal, width: Self.width - 2 * pad)
        layoutContent()
        needsDisplay = true
        if eventsHeight != old { onSizeChange?() }
    }

    // Scrolling over the flyout pages through the months.
    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            if event.phase == .began { scrollAccumulator = 0 }
            scrollAccumulator += dy
            if abs(scrollAccumulator) >= 40 {
                step(scrollAccumulator > 0 ? -1 : 1)
                scrollAccumulator = 0
            }
        } else if dy != 0 {
            step(dy > 0 ? -1 : 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let L = FlyoutLook.self

        // Hairline under the header, and above the agenda.
        L.drawSeparator(x: 0, y: hairlineY, width: bounds.width)
        if eventsHeight > 0 { L.drawSeparator(x: 0, y: agendaSeparatorY, width: bounds.width) }

        // Month title.
        let title = Win11TrayDraw.text(Self.monthFormatter.string(from: month),
                                       font: NSFont.systemFont(ofSize: 14, weight: .semibold), color: L.textPrimary)
        let th = ceil(title.size().height)
        title.draw(in: NSRect(x: pad + 8, y: monthRowTop + ((monthRowHeight - th) / 2).rounded(),
                              width: upButton.frame.minX - pad - 16, height: th))

        // Weekday symbols, starting at the calendar's first weekday.
        let symbols = cal.shortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let weekdayColor = L.isAero ? L.textSecondary : L.textPrimary
        for col in 0..<7 {
            let raw = symbols[(first + col) % 7].replacingOccurrences(of: ".", with: "")
            let s = Win11TrayDraw.text(String(raw.prefix(2)), font: font, color: weekdayColor, alignment: .center)
            let h = ceil(s.size().height)
            s.draw(in: NSRect(x: pad + CGFloat(col) * colWidth, y: weekdayTop + ((weekdayHeight - h) / 2).rounded(),
                              width: colWidth, height: h))
        }
    }
}

/// Monatsraster: 6×7 Tage, Hover-Feld, heute gefüllt in Akzentfarbe, Auswahl als Ring. Win11 mit
/// runden Feldern, Aero mit abgerundeten Glasfeldern. Mit `showsDots` unter jeder Tageszahl bis zu
/// drei Punkte in den Kalenderfarben der Termine.
private final class Win11CalendarGrid: NSView {
    var month = Date() { didSet { rebuild() } }
    var today = Date() { didSet { needsDisplay = true } }
    var selectedDate = Date() { didSet { needsDisplay = true } }
    /// Start of day → calendar colours (max. 3).
    var dots: [Date: [NSColor]] = [:] { didSet { needsDisplay = true } }
    /// Events on: dots under the (still centred) day numbers.
    var showsDots = false { didSet { if showsDots != oldValue { needsDisplay = true } } }
    var onSelect: ((Date) -> Void)?

    private let cal: Calendar
    private var days: [Date] = []
    private var hovered: Int?
    private var pressed: Int?

    init(calendar: Calendar) {
        cal = calendar
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rebuild() {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -offset, to: first) ?? first
        days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        needsDisplay = true
    }

    private var colWidth: CGFloat { bounds.width / 7 }
    private var rowHeight: CGFloat { bounds.height / 6 }
    private func cellRect(_ i: Int) -> NSRect {
        NSRect(x: CGFloat(i % 7) * colWidth, y: CGFloat(i / 7) * rowHeight, width: colWidth, height: rowHeight)
    }
    private func index(at e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        guard bounds.contains(p), colWidth > 0, rowHeight > 0 else { return nil }
        let i = Int(p.y / rowHeight) * 7 + Int(p.x / colWidth)
        return i < days.count ? i : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        if i != hovered { hovered = i; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = index(at: event); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let i = index(at: event)
        let hit = (i != nil && i == pressed) ? i : nil
        pressed = nil
        hovered = i
        needsDisplay = true
        if let hit { onSelect?(days[hit]) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let L = FlyoutLook.self
        let aero = L.isAero
        let font = NSFont.systemFont(ofSize: 13)
        let d: CGFloat = min(38, min(colWidth, rowHeight) - 2)
        for (i, day) in days.enumerated() {
            let cell = cellRect(i)
            // Win11: circle. Aero: rounded square field like the Windows 7 calendar.
            let field = aero
                ? cell.insetBy(dx: 3, dy: 2).integral
                : NSRect(x: (cell.midX - d / 2).rounded(), y: (cell.midY - d / 2).rounded(), width: d, height: d)
            let radius = aero ? 3 : d / 2
            let isToday = cal.isDate(day, inSameDayAs: today)
            let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
            let isSelected = cal.isDate(day, inSameDayAs: selectedDate)
            var textColor = inMonth ? L.textPrimary : L.textDisabled

            if isToday {
                L.drawAccentFill(field, radius: radius, hovered: hovered == i, pressed: pressed == i)
                textColor = L.onAccent
            } else {
                if pressed == i || hovered == i { L.drawHover(field, radius: radius, pressed: pressed == i) }
                if isSelected {
                    L.accent.setStroke()
                    let inset: CGFloat = aero ? 0.75 : 1
                    let r = field.insetBy(dx: inset, dy: inset)
                    let ring = NSBezierPath(roundedRect: r, xRadius: max(0, radius - inset), yRadius: max(0, radius - inset))
                    ring.lineWidth = aero ? 1.5 : 2
                    ring.stroke()
                }
            }
            let s = Win11TrayDraw.text("\(cal.component(.day, from: day))", font: font, color: textColor, alignment: .center)
            let h = ceil(s.size().height)
            // The number stays centred in its circle/field; the dots sit below it, near the lower edge.
            s.draw(in: NSRect(x: cell.minX, y: (cell.midY - h / 2).rounded(), width: cell.width, height: h))

            if showsDots, let colors = dots[day], !colors.isEmpty {
                drawDots(colors, centerX: cell.midX, y: (cell.midY + 10).rounded(),
                         onAccent: isToday, dimmed: !inMonth)
            }
        }
    }

    private func drawDots(_ colors: [NSColor], centerX: CGFloat, y: CGFloat, onAccent: Bool, dimmed: Bool) {
        let size: CGFloat = 4, gap: CGFloat = 3
        let n = CGFloat(colors.count)
        var x = (centerX - (n * size + (n - 1) * gap) / 2).rounded()
        for c in colors {
            // On today's accent field the calendar colour would vanish: dots in the on-accent colour.
            var fill = onAccent ? FlyoutLook.onAccent.withAlphaComponent(0.9) : c
            if dimmed { fill = fill.withAlphaComponent(fill.alphaComponent * 0.45) }
            fill.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
            x += size + gap
        }
    }
}

/// Terminliste des ausgewählten Tages: Überschrift („Heute“, „Morgen“ oder Datum) und bis zu fünf
/// sichtbare Termine, mehr per Scrollen. Ohne Kalenderzugriff ein Hinweis mit Knopf. Leer (Höhe 0),
/// solange „Termine anzeigen“ aus ist.
private final class Win11CalendarAgenda: NSView {
    var onOpen: ((CalendarEvents.Event) -> Void)?
    /// Access state changed (after the access prompt).
    var onStateChange: (() -> Void)?
    private(set) var preferredHeight: CGFloat = 0

    private enum Mode { case off, list, needsAccess, denied }
    private var mode: Mode = .off
    private var title = ""
    private var events: [CalendarEvents.Event] = []

    private let scroll = Win11FlyoutScrollView()
    private let listView = FlippedView()
    private let button = Win11AccentButton()

    private static let rowHeight: CGFloat = 44
    private static let maxVisibleRows = 5
    private let titleTop: CGFloat = 8
    private let titleHeight: CGFloat = 24
    private var listTop: CGFloat { titleTop + titleHeight + 6 }
    private let hintTop: CGFloat = 12
    private let buttonHeight: CGFloat = 30

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "EEEE, d. MMMM"; return f
    }()
    private static let dayYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "EEEE, d. MMMM yyyy"; return f
    }()

    init() {
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = listView
        button.onClick = { [weak self] in self?.buttonClicked() }
        addSubview(scroll)
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Loads `day` and recomputes `preferredHeight` for `width` (the owner lays out and resizes).
    func show(day: Date, calendar cal: Calendar, width: CGFloat) {
        let ev = CalendarEvents.shared
        if !CalendarEvents.enabled { mode = .off }
        else if ev.isAuthorized { mode = .list }
        else if ev.isDenied { mode = .denied }
        else { mode = .needsAccess }

        events = mode == .list ? ev.events(on: day) : []
        title = Self.title(for: day, calendar: cal)
        rebuildRows(day: day, calendar: cal)

        switch mode {
        case .off:
            preferredHeight = 0
        case .list:
            let rows = min(events.count, Self.maxVisibleRows)
            preferredHeight = listTop + (rows == 0 ? 30 : CGFloat(rows) * Self.rowHeight)
        case .needsAccess, .denied:
            button.title = mode == .denied ? "Systemeinstellungen öffnen" : "Kalenderzugriff erlauben"
            preferredHeight = hintTop + hintHeight(width: width) + 12 + buttonHeight
        }
        scroll.isHidden = mode != .list || events.isEmpty
        button.isHidden = mode != .needsAccess && mode != .denied
        needsLayout = true
        layoutRows()
        needsDisplay = true
    }

    private static func title(for day: Date, calendar cal: Calendar) -> String {
        if cal.isDateInToday(day) { return "Heute" }
        if cal.isDateInTomorrow(day) { return "Morgen" }
        let sameYear = cal.isDate(day, equalTo: Date(), toGranularity: .year)
        return (sameYear ? dayFormatter : dayYearFormatter).string(from: day)
    }

    private func rebuildRows(day: Date, calendar cal: Calendar) {
        listView.subviews.forEach { $0.removeFromSuperview() }
        for e in events {
            let row = Win11CalendarEventRow(event: e, time: Self.timeText(e, on: day, calendar: cal))
            row.onClick = { [weak self] in self?.onOpen?(e) }
            listView.addSubview(row)
        }
        scroll.hasVerticalScroller = events.count > Self.maxVisibleRows
        scroll.contentView.scroll(to: .zero)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "HH:mm"; return f
    }()

    /// „Ganztägig“, „09:00 bis 10:30“ or just „09:00“ (no duration).
    static func timeText(_ e: CalendarEvents.Event, on day: Date, calendar cal: Calendar) -> String {
        if e.isAllDay { return "Ganztägig" }
        let start = cal.startOfDay(for: day)
        if let end = cal.date(byAdding: .day, value: 1, to: start), e.start <= start, e.end >= end {
            return "Ganztägig"   // spans the whole selected day
        }
        let from = timeFormatter.string(from: e.start)
        guard e.end > e.start else { return from }
        return "\(from) bis \(timeFormatter.string(from: e.end))"
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    private func layoutRows() {
        let w = bounds.width
        let rows = min(events.count, Self.maxVisibleRows)
        scroll.frame = NSRect(x: 0, y: listTop, width: w, height: CGFloat(rows) * Self.rowHeight)
        let contentWidth = scroll.contentSize.width > 0 ? scroll.contentSize.width : w
        listView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: CGFloat(events.count) * Self.rowHeight)
        for (i, row) in listView.subviews.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: contentWidth, height: Self.rowHeight)
        }
        let bw = min(w, max(180, button.fittingWidth))
        button.frame = NSRect(x: ((w - bw) / 2).rounded(), y: hintTop + hintHeight(width: w) + 12,
                              width: bw, height: buttonHeight)
    }

    // MARK: Access hint

    private var hintText: String {
        mode == .denied
            ? "Kein Zugriff auf den Kalender. Freigabe unter Systemeinstellungen → Datenschutz & Sicherheit → Kalender."
            : "Für deine Termine braucht die Taskleiste Zugriff auf den Kalender."
    }

    private func hint(color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: hintText, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: style])
    }

    private func hintHeight(width: CGFloat) -> CGFloat {
        let r = hint(color: .labelColor).boundingRect(with: NSSize(width: max(1, width - 16), height: 200),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(r.height)
    }

    private func buttonClicked() {
        switch mode {
        case .needsAccess:
            CalendarEvents.shared.requestAccess { [weak self] _ in self?.onStateChange?() }
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            Win11Flyouts.closeAll()
        default:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let L = FlyoutLook.self
        let w = bounds.width
        switch mode {
        case .off:
            return
        case .needsAccess, .denied:
            hint(color: L.textSecondary).draw(with: NSRect(x: 8, y: hintTop, width: w - 16, height: hintHeight(width: w)),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .list:
            let t = Win11TrayDraw.text(title, font: NSFont.systemFont(ofSize: 14, weight: .semibold), color: L.textPrimary)
            let th = ceil(t.size().height)
            t.draw(in: NSRect(x: 8, y: titleTop + ((titleHeight - th) / 2).rounded(), width: w - 16, height: th))
            if events.isEmpty {
                let s = Win11TrayDraw.text("Keine Termine", font: NSFont.systemFont(ofSize: 13), color: L.textSecondary)
                let h = ceil(s.size().height)
                s.draw(in: NSRect(x: 8, y: listTop + 2, width: w - 16, height: h))
            }
        }
    }
}

/// Ein Termin: Streifen in der Kalenderfarbe, Uhrzeit, Titel (fett), darunter optional der Ort.
private final class Win11CalendarEventRow: NSView {
    let event: CalendarEvents.Event
    let time: String
    var onClick: (() -> Void)?
    private var hovering = false
    private var pressed = false

    private static let timeWidth: CGFloat = 98

    init(event: CalendarEvents.Event, time: String) {
        self.event = event
        self.time = time
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolTip = [displayTitle, time, event.location].compactMap { $0 }.joined(separator: "\n")
    }
    required init?(coder: NSCoder) { fatalError() }

    private var displayTitle: String {
        let t = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Ohne Titel" : t
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let fire = pressed && inside
        pressed = false
        hovering = inside
        needsDisplay = true
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let L = FlyoutLook.self
        if hovering { L.drawHover(bounds.insetBy(dx: 0, dy: 1), pressed: pressed) }

        Win11TrayDraw.fill(NSRect(x: 8, y: 8, width: 3, height: bounds.height - 16), radius: 1.5, event.color)

        let x = 20.0
        let titleX = x + Self.timeWidth + 8
        let titleW = max(0, bounds.width - titleX - 8)
        let title = Win11TrayDraw.text(displayTitle, font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                       color: L.textPrimary)
        let timeStr = Win11TrayDraw.text(time, font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                         color: L.textSecondary)
        let th = ceil(title.size().height)
        let mh = ceil(timeStr.size().height)

        if let loc = event.location {
            let place = Win11TrayDraw.text(loc.replacingOccurrences(of: "\n", with: ", "),
                                           font: NSFont.systemFont(ofSize: 12), color: L.textSecondary)
            let ph = ceil(place.size().height)
            let top = ((bounds.height - th - 1 - ph) / 2).rounded()
            title.draw(in: NSRect(x: titleX, y: top, width: titleW, height: th))
            place.draw(in: NSRect(x: titleX, y: top + th + 1, width: titleW, height: ph))
            timeStr.draw(in: NSRect(x: x, y: top + ((th - mh) / 2).rounded(), width: Self.timeWidth, height: mh))
        } else {
            let top = ((bounds.height - th) / 2).rounded()
            title.draw(in: NSRect(x: titleX, y: top, width: titleW, height: th))
            timeStr.draw(in: NSRect(x: x, y: top + ((th - mh) / 2).rounded(), width: Self.timeWidth, height: mh))
        }
    }
}

/// Knopf in Akzentfarbe (Win11 flach, Aero als Akzentglas).
private final class Win11AccentButton: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovering = false
    private var pressed = false
    private let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { ceil(Win11TrayDraw.text(title, font: font, color: .labelColor).size().width) + 32 }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let fire = pressed && inside
        pressed = false
        hovering = inside
        needsDisplay = true
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        FlyoutLook.drawAccentFill(bounds, radius: FlyoutLook.controlRadius, hovered: hovering, pressed: pressed)
        let s = Win11TrayDraw.text(title, font: font, color: FlyoutLook.onAccent, alignment: .center)
        let h = ceil(s.size().height)
        s.draw(in: NSRect(x: 8, y: ((bounds.height - h) / 2).rounded(), width: bounds.width - 16, height: h))
    }
}

/// Scroll view that hands the wheel to the flyout (month paging) while its content fits.
private final class Win11FlyoutScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let fits = (documentView?.frame.height ?? 0) <= contentView.bounds.height + 0.5
        if fits { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

// MARK: - Media

/// Großes Medien-Flyout: Cover, Titel, Interpret · Album, Quell-App, Spulen, Steuerung.
/// In allen Profilen verfügbar; Farben und Steuerelemente folgen `FlyoutLook`.
final class Win11MediaFlyout: Win11FlyoutContent {
    override var preferredSize: NSSize { NSSize(width: 360, height: info == nil ? 150 : 418) }

    private var info: NowPlaying.Info?
    private var artwork: NSImage?
    private var artworkKey: String?

    private let appButton = Win11FlyoutRowButton(frame: .zero)
    private let slider = Win11Slider(frame: .zero)
    private let prevButton = Win11GlyphButton(symbol: "backward.fill")
    private let playButton = Win11GlyphButton(symbol: "play.fill")
    private let nextButton = Win11GlyphButton(symbol: "forward.fill")

    private var timer: Timer?
    private var fetching = false
    private var refetch = false
    /// Bumped on every command / seek; queries started earlier are discarded.
    private var gen = 0

    // Layout (flipped).
    private let pad: CGFloat = 16
    private let coverSize: CGFloat = 200
    private let coverTop: CGFloat = 16
    private var titleTop: CGFloat { coverTop + coverSize + 14 }
    private var artistTop: CGFloat { titleTop + 24 }
    private var appRowTop: CGFloat { artistTop + 26 }
    private var sliderTop: CGFloat { appRowTop + 26 + 12 }
    private var timesTop: CGFloat { sliderTop + 22 }
    private var buttonsTop: CGFloat { timesTop + 22 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appButton.font = NSFont.systemFont(ofSize: 12)
        appButton.color = { FlyoutLook.textSecondary }
        appButton.iconSize = 16
        appButton.onClick = { [weak self] in self?.bringAppToFront() }
        slider.onChange = { [weak self] _ in self?.needsDisplay = true }   // live time preview
        slider.onCommit = { [weak self] v in self?.seek(to: v) }
        for (b, size) in [(prevButton, 18.0), (playButton, 22.0), (nextButton, 18.0)] {
            b.pointSize = CGFloat(size)
            b.cornerRadius = FlyoutLook.controlRadius
        }
        // Aero: round glass field behind play / pause, like the Windows Media Player button.
        playButton.circular = FlyoutLook.isAero
        prevButton.toolTip = "Zurück"
        nextButton.toolTip = "Weiter"
        prevButton.onClick = { [weak self] in self?.send("previous track") }
        playButton.onClick = { [weak self] in self?.togglePlay() }
        nextButton.onClick = { [weak self] in self?.send("next track") }
        for v in [appButton, slider, prevButton, playButton, nextButton] as [NSView] { addSubview(v) }
        apply(Win11NowPlayingCache.info, notify: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func willShow() {
        fetch()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.fetch() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func didHide() {
        timer?.invalidate()
        timer = nil
    }

    override func layoutContent() {
        let w = bounds.width
        let aw = min(w - 2 * pad, max(80, appButton.fittingWidth))
        appButton.frame = NSRect(x: ((w - aw) / 2).rounded(), y: appRowTop, width: aw, height: 26)
        slider.frame = NSRect(x: pad - 4, y: sliderTop, width: w - 2 * pad + 8, height: 20)
        let bs: CGFloat = 44, gap: CGFloat = 16
        let mid = (w / 2).rounded()
        playButton.frame = NSRect(x: mid - bs / 2, y: buttonsTop, width: bs, height: bs)
        prevButton.frame = NSRect(x: playButton.frame.minX - gap - bs, y: buttonsTop, width: bs, height: bs)
        nextButton.frame = NSRect(x: playButton.frame.maxX + gap, y: buttonsTop, width: bs, height: bs)
    }

    // MARK: Data

    private func fetch() {
        if fetching { refetch = true; return }   // no overlapping osascript queries
        fetching = true
        let g = gen
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let i = NowPlaying.current()
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                if g == self.gen { self.apply(i, notify: true) }
                if self.refetch { self.refetch = false; self.fetch() }
            }
        }
    }

    private func apply(_ i: NowPlaying.Info?, notify: Bool) {
        let sizeChanged = (i == nil) != (info == nil)
        info = i
        Win11NowPlayingCache.info = i
        let has = i != nil
        for v in [appButton, slider, prevButton, playButton, nextButton] as [NSView] { v.isHidden = !has }
        if let i {
            playButton.symbol = i.playing ? "pause.fill" : "play.fill"
            playButton.toolTip = i.playing ? "Pause" : "Wiedergabe"
            if !slider.isDragging { slider.value = i.fraction }
            slider.isEnabled = i.duration > 0
            updateAppButton(for: i)
            if i.trackKey != artworkKey { loadArtwork(for: i) }
        } else {
            artworkKey = nil
            artwork = nil
        }
        layoutContent()
        needsDisplay = true
        if sizeChanged && notify { onSizeChange?() }
    }

    /// Source app row: symbol and name of whatever player is playing (via bundle ID).
    private func updateAppButton(for info: NowPlaying.Info) {
        let app = Win11MediaApp.resolve(info)
        let changed = appButton.title != app.name || (appButton.icon == nil) != (app.icon == nil)
        guard changed else { return }
        appButton.title = app.name
        appButton.icon = app.icon
        appButton.toolTip = "\(app.name) öffnen"
    }

    private func loadArtwork(for i: NowPlaying.Info) {
        let key = i.trackKey
        artworkKey = key
        if Win11NowPlayingCache.artworkKey == key, let img = Win11NowPlayingCache.artwork {
            artwork = img
            return
        }
        artwork = nil
        NowPlaying.artwork(for: i) { [weak self] img in
            guard let self, self.artworkKey == key else { return }
            self.artwork = img
            Win11NowPlayingCache.artwork = img
            Win11NowPlayingCache.artworkKey = key
            self.needsDisplay = true
        }
    }

    // MARK: Actions

    private func togglePlay() {
        guard let i = info else { return }
        let t = i.togglingPlayback()   // optimistic
        info = t
        Win11NowPlayingCache.info = t
        playButton.symbol = t.playing ? "pause.fill" : "play.fill"
        send("playpause")
    }

    private func send(_ cmd: String) {
        guard let app = info?.app else { return }
        gen += 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NowPlaying.command(cmd, app: app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.fetch() }
        }
    }

    private func seek(to fraction: Double) {
        guard let i = info, i.duration > 0 else { return }
        gen += 1
        let seconds = fraction * i.duration
        var moved = i
        moved.fraction = fraction
        moved.position = seconds
        info = moved
        needsDisplay = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NowPlaying.seek(to: seconds, app: i.app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.fetch() }
        }
    }

    private func bringAppToFront() {
        guard let i = info else { return }
        Win11MediaApp.activate(i)
        Win11Flyouts.closeAll()
    }

    // MARK: Drawing

    private static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    override func draw(_ dirtyRect: NSRect) {
        let W = FlyoutLook.self
        let w = bounds.width

        guard let info else {
            if let note = Win11TrayDraw.symbol(["music.note"], pointSize: 28, color: W.textSecondary) {
                Win11TrayDraw.draw(note, centeredIn: NSRect(x: 0, y: 30, width: w, height: 44))
            }
            let s = Win11TrayDraw.text("Keine Wiedergabe", font: NSFont.systemFont(ofSize: 14),
                                       color: W.textSecondary, alignment: .center)
            s.draw(in: NSRect(x: pad, y: 88, width: w - 2 * pad, height: ceil(s.size().height)))
            return
        }

        let cover = NSRect(x: ((w - coverSize) / 2).rounded(), y: coverTop, width: coverSize, height: coverSize)
        let coverRadius: CGFloat = W.isAero ? 3 : 8
        if let art = artwork {
            Win11TrayDraw.drawCover(art, in: cover, radius: coverRadius)
            W.drawImageFrame(cover, radius: coverRadius)
        } else {
            W.drawCoverPlaceholder(in: cover, radius: coverRadius, glyphSize: 48)
        }

        let title = Win11TrayDraw.text(info.title, font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                                       color: W.textPrimary, alignment: .center)
        title.draw(in: NSRect(x: pad, y: titleTop, width: w - 2 * pad, height: ceil(title.size().height)))

        let sub = [info.artist, info.album].filter { !$0.isEmpty }.joined(separator: " · ")
        let artist = Win11TrayDraw.text(sub, font: NSFont.systemFont(ofSize: 13),
                                        color: W.textSecondary, alignment: .center)
        artist.draw(in: NSRect(x: pad, y: artistTop, width: w - 2 * pad, height: ceil(artist.size().height)))

        // Times: while dragging, the elapsed time follows the thumb.
        let elapsed = slider.isDragging ? slider.value * info.duration : info.position
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let left = Win11TrayDraw.text(Self.mmss(elapsed), font: font, color: W.textSecondary)
        let right = Win11TrayDraw.text(info.duration > 0 ? Self.mmss(info.duration) : "", font: font,
                                       color: W.textSecondary, alignment: .right)
        let h = ceil(left.size().height)
        left.draw(in: NSRect(x: pad + 2, y: timesTop, width: 80, height: h))
        right.draw(in: NSRect(x: w - pad - 2 - 80, y: timesTop, width: 80, height: h))
    }
}
