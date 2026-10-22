import AppKit

// 1:1 rebuild of AeroThemePlasma's notification history flyout (plasma/plasmoids/src/notifications_src/
// notifications: FullRepresentation.qml, DelegateHistory(Grouped).qml, NotificationHeader.qml, Summary.qml,
// Body.qml) in the tray popup frame (TrayFlyoutHost). Content comes from NotificationSources (Mail, Dock badges
// of Slack/Teams/…, calendar events), since macOS doesn't let apps read other apps' notifications.
// - flyout 304 wide (window 320), at least 304 high, growing with the list
// - per app: 22 px icon, name #1d3287 (Heading 3 ≈ 13.8 px), age label (12 px, 90 %) and the red ×
//   (svgs/icons.svg "close" in a 17 × 16 tool button); summary 12 px black at 66 % (max 3 lines), body 12 px
// - more than one entry per app: group head + children with a 3 px bar (black 20 %) in a 16 px slot, at most two
//   shown, then the link "%1 mehr anzeigen" / "Weniger anzeigen" (#0066cc)
// - apps separated by a 1 px black 65 % line (8 px high section, 8 px side margins); list margins 8, spacing 4
// - empty: "checkmark" icon + "Keine ungelesenen Benachrichtigungen"

private enum NF {
    static let nameColor = TF.hex(0x1d3287)
    static func nameFont(_ k: CGFloat) -> NSFont { Menu7Font.font(size: 13.8 * k) }
    static func textFont(_ k: CGFloat) -> NSFont { Menu7Font.font(size: 12 * k) }

    static func attributed(_ s: String, _ font: NSFont, _ color: NSColor, wrap: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    /// Height of `s` wrapped to `width`, capped at `maxLines`.
    static func height(_ s: String, _ font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let full = ceil(attributed(s, font, .black, wrap: true)
            .boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height)
        let line = ceil(font.ascender - font.descender + font.leading)
        return min(full, line * CGFloat(maxLines))
    }

    static func draw(_ s: String, _ font: NSFont, _ color: NSColor, in r: NSRect, wrap: Bool) {
        attributed(s, font, color, wrap: wrap).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// "Gerade eben", "Vor 5 min", "14:30", "Gestern", weekday or date — like the original's age label.
    static func age(_ date: Date?) -> String? {
        guard let d = date, d <= Date() else { return nil }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "Gerade eben" }
        if s < 3600 { return "Vor \(Int(s / 60)) min" }
        let f = DateFormatter()
        f.locale = Locale.current
        if s < 22 * 3600 { f.dateFormat = "HH:mm"; return f.string(from: d) }
        if Calendar.current.isDateInYesterday(d) { return "Gestern" }
        if s < 6 * 86400 { f.dateFormat = "EEEE"; return f.string(from: d) }
        f.dateStyle = .short
        return f.string(from: d)
    }
}

/// The red × of a notification (17 × 16 tool button: frame only on hover / press).
private final class NFClose: M7HoverView {
    var k: CGFloat = 1
    var onClick: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        if pressed {
            Menu7Assets.draw(Menu7Assets.frame("wf-toolbutton-pressed", 2, 2, 2, 2), in: bounds)
        } else if hovering {
            Menu7Assets.draw(Menu7Assets.frame("wf-toolbutton-hover", 2, 2, 2, 2), in: bounds)
        }
        let s = (10 * k).rounded()
        Menu7Assets.draw(Menu7Assets.image("wf-close"), in: NSRect(x: ((bounds.width - s) / 2).rounded(),
                                                                  y: ((bounds.height - s) / 2).rounded(), width: s, height: s))
    }
}

/// One block of the list: an app header (icon, name, age, ×) and/or one entry (summary, body).
/// `child` entries of a group get the grey bar and start 20 px in.
private final class NFBlock: M7FlippedView {
    let app: String
    let icon: NSImage?
    let item: NotificationSources.Item?
    let showHeader: Bool
    let child: Bool
    var k: CGFloat = 1
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    private let close = NFClose()

    init(app: String, icon: NSImage?, item: NotificationSources.Item?, showHeader: Bool, child: Bool) {
        self.app = app; self.icon = icon; self.item = item; self.showHeader = showHeader; self.child = child
        super.init(frame: .zero)
        close.onClick = { [weak self] in self?.onClose?() }
        addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }
    private var textX: CGFloat { child ? r(20) : 0 }
    private var summary: String? {
        guard let t = item?.title, !t.isEmpty,
              t.trimmingCharacters(in: .whitespaces).lowercased() != app.trimmingCharacters(in: .whitespaces).lowercased()
        else { return nil }
        return t
    }
    private var headerH: CGFloat { showHeader ? max(r(22), ceil(NF.nameFont(k).ascender - NF.nameFont(k).descender)) : 0 }
    private var ageText: String? { NF.age(item?.date) }

    /// Width left of the age label and the × (for the summary row of a child).
    private var buttonsW: CGFloat {
        let age = ageText.map { TF.width($0, NF.textFont(k)) + r(2) } ?? 0
        return age + r(17) - r(4)
    }

    func height(for width: CGFloat) -> CGFloat {
        var h = headerH
        let tw = width - textX
        if let s = summary {
            let w = child ? tw - buttonsW : tw
            h += (showHeader ? 0 : 0) + NF.height(s, NF.textFont(k), width: w, maxLines: 3)
        }
        if let b = item?.body, !b.isEmpty { h += NF.height(b, NF.textFont(k), width: tw, maxLines: 4) }
        if child { h += r(4) }
        return max(h, showHeader && item != nil && !child ? r(48) : h)
    }

    override func layout() {
        super.layout()
        close.k = k
        // × top-right, 2 px up, sticking 4 px out on the right.
        let cy = showHeader ? ((headerH - r(16)) / 2).rounded() - r(2) : (child ? r(4) - r(2) : 0)
        close.frame = NSRect(x: bounds.width - r(17) + r(4), y: max(0, cy), width: r(17), height: r(16))
        close.isHidden = !(showHeader || child)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !close.frame.contains(p) { onOpen?() }
    }
    override func resetCursorRects() { if item != nil { addCursorRect(bounds, cursor: .pointingHand) } }

    override func draw(_ dirtyRect: NSRect) {
        let font = NF.textFont(k)
        var y: CGFloat = 0
        let rightEdge = bounds.width - r(17) + r(4) - r(2)
        if showHeader {
            var x: CGFloat = 0
            if let ic = icon {
                ic.draw(in: NSRect(x: 0, y: ((headerH - r(22)) / 2).rounded(), width: r(22), height: r(22)),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x = r(22) + r(4) + r(4)
            }
            var ageW: CGFloat = 0
            if let a = ageText {
                ageW = TF.width(a, font) + r(2)
                NF.draw(a, font, NSColor.black.withAlphaComponent(0.9),
                        in: NSRect(x: rightEdge - ageW, y: ((headerH - ceil(font.ascender - font.descender)) / 2).rounded(),
                                   width: ageW, height: headerH), wrap: false)
            }
            let nf = NF.nameFont(k)
            let nh = ceil(nf.ascender - nf.descender)
            NF.draw(app, nf, NF.nameColor, in: NSRect(x: x, y: ((headerH - nh) / 2).rounded(),
                                                      width: rightEdge - ageW - x - r(4), height: nh), wrap: false)
            y = headerH
        }
        let tw = bounds.width - textX
        if child {
            y += r(4)
            // Grey bar: 3 px, black at 20 %, centred in the 16 px slot.
            NSColor(white: 0, alpha: 0.2).setFill()
            NSRect(x: ((r(16) - r(3)) / 2).rounded(), y: y, width: r(3), height: bounds.height - y).fill()
            if let a = ageText {
                let aw = TF.width(a, font) + r(2)
                NF.draw(a, font, NSColor.black.withAlphaComponent(0.9), in: NSRect(x: rightEdge - aw, y: y, width: aw, height: r(16)), wrap: false)
            }
        }
        if let s = summary {
            let w = child ? tw - buttonsW : tw
            let h = NF.height(s, font, width: w, maxLines: 3)
            NF.draw(s, font, NSColor.black.withAlphaComponent(0.66), in: NSRect(x: textX, y: y, width: w, height: h), wrap: true)
            y += h
        }
        if let b = item?.body, !b.isEmpty {
            let h = NF.height(b, font, width: tw, maxLines: 4)
            NF.draw(b, font, .black, in: NSRect(x: textX, y: y, width: tw, height: h), wrap: true)
        }
    }
}

/// "%1 mehr anzeigen" / "Weniger anzeigen" below a group.
private final class NFMore: M7HoverView {
    var text = ""
    var k: CGFloat = 1
    var onClick: (() -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        var attrs: [NSAttributedString.Key: Any] = [.font: NF.textFont(k), .foregroundColor: TF.hex(0x0066cc)]
        if hovering { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: (20 * k).rounded(), y: 0))
    }
}

/// Section separator between apps: 8 px high, 1 px black at 65 %, 8 px side margins.
private final class NFSeparator: M7FlippedView {
    var k: CGFloat = 1
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.65).setFill()
        NSRect(x: (8 * k).rounded(), y: (bounds.height / 2).rounded(), width: bounds.width - 2 * (8 * k).rounded(), height: 1).fill()
    }
}

/// Empty state: checkmark + "Keine ungelesenen Benachrichtigungen".
private final class NFEmpty: M7FlippedView {
    var k: CGFloat = 1
    var text = "Keine ungelesenen Benachrichtigungen"
    override func draw(_ dirtyRect: NSRect) {
        let s = (64 * k).rounded()
        Menu7Assets.draw(Menu7Assets.image("wf-checkmark"), in: NSRect(x: ((bounds.width - s) / 2).rounded(), y: 0, width: s, height: s),
                         alpha: 0.6)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        NSAttributedString(string: text, attributes: [.font: Menu7Font.font(size: 14.4 * k),
                                                      .foregroundColor: NSColor.black.withAlphaComponent(0.6),
                                                      .paragraphStyle: style])
            .draw(with: NSRect(x: 0, y: s + (8 * k).rounded(), width: bounds.width, height: 60 * k), options: [.usesLineFragmentOrigin])
    }
}

// MARK: - Controller

final class NotificationFlyoutController: NSObject {
    private let host = TrayFlyoutHost(footer: "Mitteilungszentrale öffnen")
    private let scroll = NSScrollView()
    private let listDoc = M7FlippedView()
    private var items: [NotificationSources.Item] = []
    private var dismissed: Set<String> = []
    private var expandedApps: Set<String> = []
    private var refreshTimer: Timer?
    private var anchor = NSRect.zero
    private weak var screen: NSScreen?

    var isVisible: Bool { host.isVisible }
    /// Opens the macOS Notification Center (the footer link).
    var onOpenSystemCenter: (() -> Void)?
    /// Number of entries currently shown (for the flag's active state).
    private(set) var count = 0
    var onCountChange: ((Int) -> Void)?

    override init() {
        super.init()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy
        scroll.borderType = .noBorder
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.documentView = listDoc
        host.root.addSubview(scroll)
        host.footer.onClick = { [weak self] in
            self?.host.hide()
            self?.onOpenSystemCenter?()
        }
        host.onHide = { [weak self] in self?.refreshTimer?.invalidate(); self?.refreshTimer = nil }
    }

    private static func key(_ i: NotificationSources.Item) -> String { "\(i.app)|\(i.title)|\(i.body ?? "")" }

    func toggle(anchor: NSRect, on screen: NSScreen) {
        if host.isVisible { host.hide() } else { show(anchor: anchor, on: screen) }
    }

    func show(anchor: NSRect, on screen: NSScreen) {
        self.anchor = anchor
        self.screen = screen
        expandedApps = []
        reload(open: true)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.reload(open: false) }
    }

    /// Updates only the count (e.g. for the flag), without showing the flyout.
    func refreshCount() {
        NotificationSources.gather { [weak self] list in
            guard let self else { return }
            self.items = list
            self.updateCount()
        }
    }

    private func updateCount() {
        count = items.filter { !dismissed.contains(Self.key($0)) }.count
        onCountChange?(count)
    }

    private func reload(open: Bool) {
        NotificationSources.gather { [weak self] list in
            guard let self else { return }
            self.items = list
            self.updateCount()
            self.build()
            if open, let s = self.screen { self.host.show(anchor: self.anchor, on: s) }
        }
        if open { build(); if let s = screen { host.show(anchor: anchor, on: s) } }   // show at once, fill when ready
    }

    private func build() {
        let visible = items.filter { !dismissed.contains(Self.key($0)) }
        // Group by app, keeping the first appearance order.
        var order: [String] = []
        var groups: [String: [NotificationSources.Item]] = [:]
        for i in visible {
            if groups[i.app] == nil { order.append(i.app) }
            groups[i.app, default: []].append(i)
        }

        let k = max(1, Theme.barHeight / 40)
        func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }
        let mainW: CGFloat = 304
        let L = r(mainW) - 2 * r(8) + 2 * r(2)          // applet width + 2 px each side (scroll margins −2)
        let cw = L - 2 * r(8)                            // delegate padding 8
        listDoc.subviews.forEach { $0.removeFromSuperview() }
        var y = r(8)
        func add(_ v: NSView, _ h: CGFloat, inset: Bool = true) {
            v.frame = NSRect(x: inset ? r(8) : 0, y: y, width: inset ? cw : L, height: h)
            listDoc.addSubview(v)
            y += h + r(4)
        }

        if visible.isEmpty {
            let e = NFEmpty()
            e.k = k
            let ew = L - r(64)
            e.frame = NSRect(x: (L - ew) / 2, y: r(40), width: ew, height: r(64) + r(8) + r(40))
            listDoc.addSubview(e)
            y = e.frame.maxY
        }

        for (gi, app) in order.enumerated() {
            let entries = groups[app] ?? []
            if gi > 0 { let s = NFSeparator(); s.k = k; add(s, r(8), inset: false) }
            let icon = entries.first?.icon
            if entries.count == 1, let e = entries.first {
                let b = NFBlock(app: app, icon: icon, item: e, showHeader: true, child: false)
                b.k = k
                wire(b, e)
                add(b, b.height(for: cw))
            } else {
                let head = NFBlock(app: app, icon: icon, item: nil, showHeader: true, child: false)
                head.k = k
                head.onClose = { [weak self] in
                    guard let self else { return }
                    entries.forEach { self.dismissed.insert(Self.key($0)) }
                    self.updateCount(); self.build()
                }
                add(head, head.height(for: cw))
                let expanded = expandedApps.contains(app)
                for e in (expanded ? entries : Array(entries.prefix(2))) {
                    let b = NFBlock(app: app, icon: icon, item: e, showHeader: false, child: true)
                    b.k = k
                    wire(b, e)
                    add(b, b.height(for: cw))
                }
                if entries.count > 2 {
                    let m = NFMore()
                    m.k = k
                    m.text = expanded ? "Weniger anzeigen" : "\(entries.count - 2) mehr anzeigen"
                    m.onClick = { [weak self] in
                        guard let self else { return }
                        if expanded { self.expandedApps.remove(app) } else { self.expandedApps.insert(app) }
                        self.build()
                    }
                    add(m, r(16))
                }
            }
        }
        let contentH = y - r(4) + r(8)

        // Height: at least 304, growing with the list (capped at 80 % of the screen).
        let maxMain = ((screen?.visibleFrame.height ?? 900) * 0.8 - 16) / k
        let wanted = (contentH / k) + 8 + 46 + 4
        host.setMainSize(width: mainW, height: min(maxMain, max(304, wanted)))
        let a = host.appletRect
        scroll.frame = NSRect(x: a.minX - r(2), y: a.minY, width: a.width + 2 * r(2), height: host.footerTop - a.minY - r(2))
        listDoc.frame = NSRect(x: 0, y: 0, width: L, height: max(contentH, scroll.contentSize.height))
        if host.isVisible, let s = screen { host.reposition(anchor: anchor, on: s) }   // keep it above the flag when the size changes
    }

    private func wire(_ b: NFBlock, _ e: NotificationSources.Item) {
        b.onOpen = { [weak self] in self?.host.hide(); e.open() }
        b.onClose = { [weak self] in
            guard let self else { return }
            self.dismissed.insert(Self.key(e))
            self.updateCount(); self.build()
        }
    }
}
