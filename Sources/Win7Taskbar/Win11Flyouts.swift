import AppKit

/// Win11-Flyouts über der Taskleiste. `anchor` ist das auslösende Element in Bildschirmkoordinaten.
/// Jedes show* toggelt: ist dasselbe Flyout schon offen, schließt es. Immer nur eins gleichzeitig.
enum Win11Flyouts {
    fileprivate enum Kind { case calendar, media }

    private static var panel: Win11FlyoutPanel?
    private static var kind: Kind?
    private static var anchor: NSRect = .zero
    private static var monitors: [Any] = []

    static func showCalendar(anchor: NSRect, screen: NSScreen) {
        toggle(.calendar, anchor: anchor, screen: screen, placement: .right) { Win11CalendarFlyout(frame: .zero) }
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

/// Randloses, nicht aktivierendes Panel mit Win11-Fläche (Blur + Acryl-Tönung, Rand, Schatten).
final class Win11FlyoutPanel: NSPanel {
    enum Placement { case right, centered(CGFloat) }

    let content: Win11FlyoutContent
    private let blur = NSVisualEffectView()
    private let background = Win11FlyoutSurface()
    private let stroke = Win11FlyoutStroke()
    private var placement: Placement = .right
    private var screenFrame: NSRect = .zero

    private static let gap: CGFloat = 12
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
        appearance = Theme.win11NSAppearance

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        for v in [blur, background, content, stroke] as [NSView] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        Theme.Win11.configureBlur(blur, for: .flyout)
        blur.maskImage = Self.roundedMask(radius: Theme.Win11.panelRadius)
        contentView = root
        content.onSizeChange = { [weak self] in self?.relayout() }
    }

    // Never steal focus from the frontmost app (Esc is caught by the key monitors).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func targetFrame(for size: NSSize) -> NSRect {
        let sf = screenFrame
        let y = sf.minY + Theme.barHeight + Self.gap
        var x: CGFloat
        switch placement {
        case .right:
            x = sf.maxX - Self.gap - size.width
        case .centered(let mid):
            x = min(max(mid - size.width / 2, sf.minX + Self.gap), sf.maxX - Self.gap - size.width)
        }
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    func present(on screen: NSScreen, placement: Placement) {
        self.placement = placement
        screenFrame = screen.frame
        let target = targetFrame(for: content.preferredSize)
        content.willShow()
        alphaValue = 0
        if reduceMotion {
            setFrame(target, display: true)
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
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

/// Acryl-Tönung der Flyout-Fläche (Farbe zur Zeichenzeit). Auch für die Fenstervorschau.
final class Win11FlyoutSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = Theme.Win11.panelRadius
        Win11TrayDraw.fill(bounds, radius: r, Theme.Win11.surface(.flyout))
    }
}

/// 1-px-Rand über dem Inhalt; lässt Klicks durch. Auch für die Fenstervorschau.
final class Win11FlyoutStroke: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = Theme.Win11.panelRadius
        Theme.Win11.panelStroke.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        p.lineWidth = 1
        p.stroke()
    }
}

// MARK: - Shared controls

/// Text row button with optional icon and Win11 hover fill.
final class Win11FlyoutRowButton: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 13)
    var color: () -> NSColor = { Theme.Win11.textPrimary }
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
        if hovering {
            Win11TrayDraw.fill(bounds, radius: 4, pressed ? Theme.Win11.pressedFill : Theme.Win11.hoverFill)
        }
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

/// Win11-Regler: Spur, gefüllter Anteil in Akzentfarbe, runder Daumen mit Rand.
/// Klicken springt, Ziehen folgt der Maus.
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
}

// MARK: - Calendar

/// Kalender-Flyout: Kopfzeile mit Datum, Monatsnavigation, Monatsraster (6 Wochen).
final class Win11CalendarFlyout: Win11FlyoutContent {
    override var preferredSize: NSSize { NSSize(width: Self.width, height: gridTop + gridHeight + eventsHeight + 12) }

    /// Ausgewählter Tag (Start des Tages). Grundlage für die spätere Terminliste.
    var selectedDate: Date {
        didSet { grid.selectedDate = selectedDate }
    }
    /// Hier sollen später die Termine des ausgewählten Tages erscheinen (EventKit).
    /// Vorerst leer mit Höhe 0; bei Inhalt `eventsHeight` anpassen und `onSizeChange` rufen.
    let eventsContainer = NSView()
    private var eventsHeight: CGFloat = 0

    private static let width: CGFloat = 360
    private let cal: Calendar
    private var month: Date { didSet { grid.month = month; needsDisplay = true } }

    private let header = Win11FlyoutRowButton(frame: .zero)
    private let upButton = Win11GlyphButton(symbol: "chevron.up")
    private let downButton = Win11GlyphButton(symbol: "chevron.down")
    private let grid: Win11CalendarGrid

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
        for b in [upButton, downButton] { b.pointSize = 12; b.weight = .medium; b.cornerRadius = 4 }
        upButton.toolTip = "Vorheriger Monat"
        downButton.toolTip = "Nächster Monat"
        grid.month = month
        grid.selectedDate = selectedDate
        grid.onSelect = { [weak self] day in self?.select(day) }
        for v in [header, upButton, downButton, grid, eventsContainer] as [NSView] { addSubview(v) }
        updateHeader()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func willShow() { goToToday() }

    override func layoutContent() {
        let w = bounds.width
        header.frame = NSRect(x: pad, y: headerTop, width: w - 2 * pad, height: headerHeight)
        let bs: CGFloat = 32
        let by = monthRowTop + (monthRowHeight - bs) / 2
        downButton.frame = NSRect(x: w - pad - bs, y: by, width: bs, height: bs)
        upButton.frame = NSRect(x: downButton.frame.minX - 4 - bs, y: by, width: bs, height: bs)
        grid.frame = NSRect(x: pad, y: gridTop, width: w - 2 * pad, height: gridHeight)
        eventsContainer.frame = NSRect(x: pad, y: gridTop + gridHeight, width: w - 2 * pad, height: eventsHeight)
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
        let W = Theme.Win11.self

        // Hairline under the header.
        W.hairline.setFill()
        NSRect(x: 0, y: hairlineY, width: bounds.width, height: 1).fill()

        // Month title.
        let title = Win11TrayDraw.text(Self.monthFormatter.string(from: month),
                                       font: NSFont.systemFont(ofSize: 14, weight: .semibold), color: W.textPrimary)
        let th = ceil(title.size().height)
        title.draw(in: NSRect(x: pad + 8, y: monthRowTop + ((monthRowHeight - th) / 2).rounded(),
                              width: upButton.frame.minX - pad - 16, height: th))

        // Weekday symbols, starting at the calendar's first weekday.
        let symbols = cal.shortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        for col in 0..<7 {
            let raw = symbols[(first + col) % 7].replacingOccurrences(of: ".", with: "")
            let s = Win11TrayDraw.text(String(raw.prefix(2)), font: font, color: W.textPrimary, alignment: .center)
            let h = ceil(s.size().height)
            s.draw(in: NSRect(x: pad + CGFloat(col) * colWidth, y: weekdayTop + ((weekdayHeight - h) / 2).rounded(),
                              width: colWidth, height: h))
        }
    }
}

/// Monatsraster: 6×7 Tage, Hover-Kreis, heute gefüllt in Akzentfarbe, Auswahl als Ring.
private final class Win11CalendarGrid: NSView {
    var month = Date() { didSet { rebuild() } }
    var today = Date() { didSet { needsDisplay = true } }
    var selectedDate = Date() { didSet { needsDisplay = true } }
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
        let W = Theme.Win11.self
        let font = NSFont.systemFont(ofSize: 13)
        let d: CGFloat = min(38, min(colWidth, rowHeight) - 2)
        for (i, day) in days.enumerated() {
            let cell = cellRect(i)
            let circle = NSRect(x: (cell.midX - d / 2).rounded(), y: (cell.midY - d / 2).rounded(), width: d, height: d)
            let isToday = cal.isDate(day, inSameDayAs: today)
            let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
            let isSelected = cal.isDate(day, inSameDayAs: selectedDate)
            var textColor = inMonth ? W.textPrimary : W.textDisabled

            if isToday {
                var fill = W.accent
                if pressed == i { fill = fill.withAlphaComponent(0.8) }
                else if hovered == i { fill = fill.withAlphaComponent(0.9) }
                fill.setFill()
                NSBezierPath(ovalIn: circle).fill()
                textColor = W.onAccent
            } else {
                if pressed == i {
                    W.pressedFill.setFill(); NSBezierPath(ovalIn: circle).fill()
                } else if hovered == i {
                    W.hoverFill.setFill(); NSBezierPath(ovalIn: circle).fill()
                }
                if isSelected {
                    W.accent.setStroke()
                    let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
                    ring.lineWidth = 2
                    ring.stroke()
                }
            }
            let s = Win11TrayDraw.text("\(cal.component(.day, from: day))", font: font, color: textColor, alignment: .center)
            let h = ceil(s.size().height)
            s.draw(in: NSRect(x: cell.minX, y: (cell.midY - h / 2).rounded(), width: cell.width, height: h))
        }
    }
}

// MARK: - Media

/// Großes Medien-Flyout: Cover, Titel, Interpret · Album, Quell-App, Spulen, Steuerung.
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
        appButton.color = { Theme.Win11.textSecondary }
        appButton.iconSize = 16
        appButton.onClick = { [weak self] in self?.bringAppToFront() }
        slider.onChange = { [weak self] _ in self?.needsDisplay = true }   // live time preview
        slider.onCommit = { [weak self] v in self?.seek(to: v) }
        for (b, size) in [(prevButton, 18.0), (playButton, 22.0), (nextButton, 18.0)] {
            b.pointSize = CGFloat(size)
            b.cornerRadius = 4
        }
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
        let W = Theme.Win11.self
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
        if let art = artwork {
            Win11TrayDraw.drawCover(art, in: cover, radius: 8)
        } else {
            Win11TrayDraw.drawCoverPlaceholder(in: cover, radius: 8, glyphSize: 48)
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
