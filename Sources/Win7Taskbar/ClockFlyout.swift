import AppKit

// 1:1 rebuild of AeroThemePlasma's clock flyout (plasma/plasmoids/io.gitgud.wackyideas.digitalclocklite,
// CalendarView.qml / CustomMonthView.qml / DaysCalendar.qml / DayDelegate.qml / Clock.qml). Window 352 × 263
// (content 336 × 247 in the solid dialog frame); coordinates below are the original's window pixels ("W"),
// scaled by `k` inside the native 8 px frame:
// - date header W(20,20)-(332,36), #0066cc, centred; click = back to today
// - month view 168 × 150 at W(20,55): navigation row (10 px arrows from svgs/icons.svg, month label), weekday
//   row, 6 × 7 day cells of 22 × 15 (column step 23), viewitem "hover" highlight (selected .8 / pressed .3 /
//   hover .6), today framed in #0066cc; the label switches to year (4 × 3 months) and decade views
// - analog clock 128 × 128 at W(204,48) from svgs/clock.svg (face, hands, dot, shine), digital time below
// - footer "Datum- und Uhrzeiteinstellungen ändern..." and the pin (8 px from the content edge)

private func cfText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .center,
                    underline: Bool = false, dy: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = .byClipping
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    let str = NSAttributedString(string: s, attributes: attrs)
    let h = ceil(str.size().height)
    str.draw(with: NSRect(x: rect.minX, y: (rect.midY - h / 2 + dy).rounded(), width: rect.width, height: h),
             options: [.usesLineFragmentOrigin])
}

/// Text that reacts like a link (#0066cc, underline on hover), e.g. the date header.
private final class CFLinkLabel: M7HoverView {
    var text = "" { didSet { needsDisplay = true } }
    var k: CGFloat = 1
    var onClick: (() -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        cfText(text, in: bounds, font: TF.font(k), color: TF.hex(0x0066cc), underline: hovering)
    }
}

/// Flat 17 × 16 tool button with a 10 px arrow; "-active" (#0066cc) variant on hover, normal while pressed.
private final class CFArrow: M7HoverView {
    let name: String
    var k: CGFloat = 1
    var onClick: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    init(_ name: String) { self.name = name; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let s = (10 * k).rounded()
        Menu7Assets.draw(Menu7Assets.image(hovering && !pressed ? "wf-\(name)-active" : "wf-\(name)"),
                         in: NSRect(x: ((bounds.width - s) / 2).rounded(), y: ((bounds.height - s) / 2).rounded(),
                                    width: s, height: s))
    }
}

// MARK: - Calendar grid (month / year / decade)

private final class CFCalendar: M7FlippedView {
    enum Mode { case month, year, decade }
    var k: CGFloat = 1
    var mode: Mode = .month
    /// First day of the shown month (month view), January of the shown year, or of the decade start.
    var shown = Date()
    var selected = Date()
    var onChange: (() -> Void)?
    private var hover: Int?
    private var pressed: Int?
    private let cal: Calendar = {
        var c = Calendar.current
        c.locale = Locale.current
        return c
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    // Geometry relative to this view (= the grid area, origin at W(27,77) for the month view).
    private var cols: Int { mode == .month ? 7 : 4 }
    private var cellW: CGFloat { r(mode == .month ? 22 : 40) }
    private var cellH: CGFloat { r(mode == .month ? 15 : 36) }
    private var headerH: CGFloat { mode == .month ? r(15) : 0 }

    func resetToToday() {
        selected = Date()
        shown = cal.date(from: cal.dateComponents([.year, .month], from: selected)) ?? selected
        mode = .month
        needsDisplay = true
    }

    /// Previous / next month, year or decade.
    func step(_ d: Int) {
        let unit: Calendar.Component = mode == .month ? .month : .year
        let amount = mode == .decade ? 10 * d : d
        shown = cal.date(byAdding: unit, value: amount, to: shown) ?? shown
        needsDisplay = true
        onChange?()
    }

    /// Label of the navigation row: "Oktober 2026", "2026" or "2020-2029".
    var title: String {
        let y = cal.component(.year, from: shown)
        switch mode {
        case .month:
            let f = DateFormatter(); f.locale = Locale.current; f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return f.string(from: shown)
        case .year: return "\(y)"
        case .decade: let d = y - y % 10; return "\(d)-\(d + 9)"
        }
    }

    func zoomOut() {
        if mode == .month { mode = .year } else if mode == .year { mode = .decade }
        needsDisplay = true
        onChange?()
    }

    // MARK: Cells

    /// Month view: the 42 days starting at the first week containing the 1st.
    private var monthDays: [Date] {
        let first = shown
        let wd = cal.component(.weekday, from: first)
        let back = (wd - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -back, to: first) ?? first
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var cellCount: Int { mode == .month ? 42 : 12 }

    private func cellRect(_ i: Int) -> NSRect {
        let c = i % cols, row = i / cols
        let stepX = cellW + r(1)
        let gridW = CGFloat(cols) * cellW + CGFloat(cols - 1) * r(1)
        let x0 = bounds.width - r(1) - gridW
        return NSRect(x: x0 + CGFloat(c) * stepX, y: headerH + CGFloat(row) * cellH, width: cellW, height: cellH)
    }

    private func index(at p: NSPoint) -> Int? {
        (0..<cellCount).first { cellRect($0).contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = index(at: convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        guard let i = index(at: convert(event.locationInWindow, from: nil)), i == pressed else { return }
        switch mode {
        case .month:
            selected = monthDays[i]                      // selects only, no month change (like the original)
        case .year:
            var dc = cal.dateComponents([.year], from: shown); dc.month = i + 1; dc.day = 1
            shown = cal.date(from: dc) ?? shown
            mode = .month
        case .decade:
            let y = cal.component(.year, from: shown)
            var dc = DateComponents(); dc.year = y - y % 10 - 1 + i; dc.month = 1; dc.day = 1
            shown = cal.date(from: dc) ?? shown
            mode = .year
        }
        onChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = TF.font(k)
        if mode == .month {
            // Weekday header (2 letters, ~8 pt) and the 1 px #f5f5f5 separator.
            let small = Menu7Font.font(size: max(10.67 * k, cellH / 3))
            let syms = cal.shortWeekdaySymbols
            for c in 0..<7 {
                let name = String(syms[(cal.firstWeekday - 1 + c) % 7].prefix(2))
                let rr = cellRect(c)
                cfText(name, in: NSRect(x: rr.minX, y: 0, width: cellW, height: headerH), font: small, color: .black)
            }
            TF.hex(0xf5f5f5).setFill()
            let gridW = 7 * cellW + 6 * r(1)
            NSRect(x: bounds.width - r(1) - gridW, y: headerH, width: gridW, height: 1).fill()
        }
        let today = Date()
        for i in 0..<cellCount {
            let rect = cellRect(i)
            var label = "", isToday = false, isSelected = false, dim = false
            switch mode {
            case .month:
                let d = monthDays[i]
                label = "\(cal.component(.day, from: d))"
                isToday = cal.isDate(d, inSameDayAs: today)
                isSelected = cal.isDate(d, inSameDayAs: selected)
                dim = cal.component(.month, from: d) != cal.component(.month, from: shown)
            case .year:
                label = String(cal.shortStandaloneMonthSymbols[i].replacingOccurrences(of: ".", with: "").prefix(3))
                isToday = cal.component(.year, from: shown) == cal.component(.year, from: today)
                    && cal.component(.month, from: today) == i + 1
                isSelected = cal.component(.year, from: shown) == cal.component(.year, from: selected)
                    && cal.component(.month, from: selected) == i + 1
            case .decade:
                let y0 = cal.component(.year, from: shown)
                let y = y0 - y0 % 10 - 1 + i
                label = "\(y)"
                isToday = y == cal.component(.year, from: today)
                isSelected = y == cal.component(.year, from: selected)
                dim = i == 0 || i == 11
            }
            let hovered = hover == i, isPressed = pressed == i
            let alpha: CGFloat = isSelected ? 0.8 : isPressed ? 0.3 : hovered ? 0.6 : 0
            if alpha > 0 { Menu7Assets.draw(Menu7Assets.frame("wf-hover", 3, 3, 3, 3), in: rect, alpha: alpha) }
            if isToday {
                TF.hex(0x0066cc).setStroke()
                let p = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                p.lineWidth = 1
                p.stroke()
            }
            let blue = isToday || (hovered && !isPressed)
            var color = blue ? TF.hex(0x0066cc) : NSColor.black
            if dim { color = color.withAlphaComponent(0.5) }
            if mode == .month {
                cfText(label, in: NSRect(x: rect.minX, y: rect.minY, width: rect.width - r(5), height: rect.height - r(1)),
                       font: font, color: color, alignment: .right)
            } else {
                cfText(label, in: rect, font: font, color: color)
            }
        }
    }
}

// MARK: - Analog clock

private final class CFAnalogClock: M7FlippedView {
    var date = Date() { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let s = b.width / 128   // the original is laid out at 128 px
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 2 * s, height: -2 * s)
        shadow.shadowBlurRadius = 3 * s
        shadow.shadowColor = NSColor(white: 0, alpha: 0x16 / 255.0)
        shadow.set()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        Menu7Assets.draw(Menu7Assets.image("wf-clockface"), in: b)
        let cal = Calendar.current
        let h = cal.component(.hour, from: date) % 12, m = cal.component(.minute, from: date), sec = cal.component(.second, from: date)
        let c = CGPoint(x: b.midX, y: b.midY)

        /// A hand pointing to `angle` (clockwise from 12) from `-tail` to `length` px, `width` px wide.
        func hand(angle: CGFloat, length: CGFloat, tail: CGFloat, width: CGFloat, fill: (CGRect) -> Void) {
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: angle * .pi / 180)      // flipped view: +y points down, so 12 o'clock is −y
            fill(CGRect(x: -width * s / 2, y: -length * s, width: width * s, height: (length + tail) * s))
            ctx.restoreGState()
        }
        // Second hand under the others: #546770 at 75 %, 47 px forward, 18 px tail.
        hand(angle: CGFloat(sec) * 6, length: 47, tail: 18, width: 1) { r in
            NSColor(srgbRed: 0x54 / 255.0, green: 0x67 / 255.0, blue: 0x70 / 255.0, alpha: 0xbf / 255.0).setFill()
            r.fill()
        }
        // Minute (47) and hour (36) hands: 2 px, #5c6c74 at 87.5 % → 93.7 % → 87.5 % across their width.
        let handColor = { (a: CGFloat) in NSColor(srgbRed: 0x5c / 255.0, green: 0x6c / 255.0, blue: 0x74 / 255.0, alpha: a) }
        let gradient = NSGradient(colors: [handColor(0xdf / 255.0), handColor(0xef / 255.0), handColor(0xdf / 255.0)])
        for (angle, len) in [(CGFloat(m) * 6, CGFloat(47)), (CGFloat(h) * 30 + CGFloat(m) * 0.5, CGFloat(36))] {
            hand(angle: angle, length: len, tail: 0, width: 2) { r in
                let p = NSBezierPath(roundedRect: r, xRadius: 1 * s, yRadius: 1 * s)
                gradient?.draw(in: p, angle: 0)
            }
        }
        let dot = 5 * s
        Menu7Assets.draw(Menu7Assets.image("wf-clockdot"), in: NSRect(x: c.x - dot / 2, y: c.y - dot / 2, width: dot, height: dot))
        Menu7Assets.draw(Menu7Assets.image("wf-clockshine"), in: b)

        ctx.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Digital time below the clock ("HH:mm:ss", black, centred).
private final class CFTimeLabel: M7FlippedView {
    var k: CGFloat = 1
    var text = "" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        cfText(text, in: bounds, font: TF.font(k), color: .black)
    }
}

// MARK: - Controller

final class ClockFlyoutController: NSObject {
    private let host = TrayFlyoutHost(footer: "Datum- und Uhrzeiteinstellungen ändern...")
    private let header = CFLinkLabel()
    private let prev = CFArrow("left")
    private let next = CFArrow("right")
    private let monthLabel = CFMonthLabel()
    private let grid = CFCalendar()
    private let clock = CFAnalogClock()
    private let time = CFTimeLabel()
    private var timer: Timer?

    var isVisible: Bool { host.isVisible }

    override init() {
        super.init()
        host.pinMargin = 8
        host.onHide = { [weak self] in self?.timer?.invalidate(); self?.timer = nil }
        host.footer.onClick = { [weak self] in
            TF.openSettings("com.apple.Date-Time-Settings.extension")
            self?.host.hide()
        }
        header.onClick = { [weak self] in self?.grid.resetToToday(); self?.refresh() }
        prev.onClick = { [weak self] in self?.grid.step(-1) }
        next.onClick = { [weak self] in self?.grid.step(1) }
        monthLabel.onClick = { [weak self] in self?.grid.zoomOut() }
        grid.onChange = { [weak self] in self?.refresh() }
        for v in [header, prev, next, monthLabel, grid, clock, time] as [NSView] { host.root.addSubview(v) }
    }

    func toggle(anchor: NSRect, on screen: NSScreen) {
        if host.isVisible { host.hide() } else { show(anchor: anchor, on: screen) }
    }

    func show(anchor: NSRect, on screen: NSScreen) {
        host.setMainSize(width: 336, height: 247)
        layout()
        grid.resetToToday()
        refresh()
        host.show(anchor: anchor, on: screen)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func hide() { host.hide() }

    /// Window coordinate of the original's W(x/y): the 8 px frame stays native, the rest scales.
    private func w(_ v: CGFloat) -> CGFloat { 8 + host.r(v - 8) }
    private func r(_ v: CGFloat) -> CGFloat { host.r(v) }

    private func layout() {
        let k = host.k
        header.k = k; prev.k = k; next.k = k; monthLabel.k = k; grid.k = k; time.k = k
        header.frame = NSRect(x: w(20), y: w(20), width: r(312), height: r(16))
        prev.frame = NSRect(x: w(24), y: w(55), width: r(17), height: r(16))
        next.frame = NSRect(x: w(171), y: w(55), width: r(17), height: r(16))
        monthLabel.frame = NSRect(x: w(41), y: w(55), width: r(130), height: r(16))
        // Grid area: x 20…188 (cells right-aligned, 1 px margin), from the weekday row at y 77.
        grid.frame = NSRect(x: w(20), y: w(77), width: r(168), height: r(15) * 7 + 1)
        clock.frame = NSRect(x: w(204), y: w(48), width: r(128), height: r(128))
        time.frame = NSRect(x: w(204), y: w(183), width: r(128), height: r(16))
    }

    private func tick() {
        let now = Date()
        clock.date = now
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        time.text = f.string(from: now)
        // Date line (and the today frame) change at midnight.
        let hf = DateFormatter(); hf.locale = Locale.current; hf.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
        let h = hf.string(from: now)
        if header.text != h { header.text = h; grid.needsDisplay = true }
    }

    private func refresh() {
        tick()
        monthLabel.text = grid.title
        monthLabel.needsDisplay = true
        grid.needsDisplay = true
    }
}

/// Month / year / decade label of the navigation row: black, #0066cc on hover; click zooms out.
private final class CFMonthLabel: M7HoverView {
    var text = "" { didSet { needsDisplay = true } }
    var k: CGFloat = 1
    var onClick: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        cfText(text.capitalized(with: Locale.current), in: bounds, font: TF.font(k),
               color: hovering && !pressed ? TF.hex(0x0066cc) : .black)
    }
}
