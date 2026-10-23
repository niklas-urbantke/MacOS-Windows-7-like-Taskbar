import AppKit
import SystemConfiguration

// 1:1 rebuild of AeroThemePlasma's network flyout (plasma/plasmoids/io.gitgud.wackyideas.networkmanagement,
// hosted in the system tray's popup). Geometry in the original's reference pixels, scaled by `k` like the
// Start menu (taskbar height / 40); the chrome comes from the original SVGs, rasterised onto the pixel grid
// (ThemeResources/wf-*), and is drawn at native pixel size:
// - frame (TrayFlyoutHost in TrayFlyout.swift): Seven-Black solid/dialogs/background.svg (8 px glass edge, white inside), window 288 × 320,
//   main item 272 × 304 inset by 8; Aero glass in the window colour behind the frame's glass band
// - footer: #f1f5fb strip (42 px, 4 px #ccd9ea gradient on top) with the link "Netzwerk- und Freigabecenter öffnen"
// - toolbar: "WLAN" checkbox (Kvantum Windows7Aero checkbox + network-wireless-on/off), flat refresh button;
//   the search field only appears once something is typed
// - list: connected network with a 32 px signal icon on the left and a bold title, the others mirrored with a
//   24 px icon on the right and a #0061bd title; "Verfügbare Verbindungen" section (#40555a, #b1b1b1 line);
//   viewitem "hover" highlight; a click expands the row with Win7 buttons and, if needed, a password field.

// MARK: - List rows

/// Section separator: 1 px #b1b1b1 line 4 px below the top, text #40555a 10 px in, 40 px high.
private final class WFSection: M7FlippedView {
    let title: String
    var k: CGFloat = 1
    init(_ title: String) { self.title = title; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r: (CGFloat) -> CGFloat = { ($0 * self.k).rounded() }
        TF.hex(0xb1b1b1).setFill()
        NSRect(x: 0, y: r(4), width: bounds.width, height: 1).fill()
        TF.text(title, in: NSRect(x: r(10), y: r(4), width: bounds.width - r(10), height: bounds.height - r(4)),
                font: TF.font(k), color: TF.hex(0x40555a))
    }
}

/// Hint row shown while macOS hides the network names (no Location permission).
private final class WFHint: M7FlippedView {
    var k: CGFloat = 1
    var onAllow: (() -> Void)?
    let button = TFButton("Ortungsdienste erlauben")
    private let label = NSTextField(wrappingLabelWithString:
        "macOS zeigt die Namen der WLAN-Netze nur Apps mit Ortungsfreigabe an. Der Standort selbst wird nicht verwendet.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.textColor = .black
        addSubview(label)
        button.onClick = { [weak self] in self?.onAllow?() }
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat {
        let r: (CGFloat) -> CGFloat = { ($0 * self.k).rounded() }
        label.font = TF.font(k)
        label.preferredMaxLayoutWidth = width - r(20)
        let lh = ceil(label.fittingSize.height)
        return r(6) + lh + r(6) + r(23) + r(8)
    }
    override func layout() {
        super.layout()
        let r: (CGFloat) -> CGFloat = { ($0 * self.k).rounded() }
        label.font = TF.font(k)
        label.preferredMaxLayoutWidth = bounds.width - r(20)
        let lh = ceil(label.fittingSize.height)
        label.frame = NSRect(x: r(10), y: r(6), width: bounds.width - r(20), height: lh)
        button.k = k
        let bw = button.preferredWidth
        button.frame = NSRect(x: bounds.width - r(10) - bw, y: r(6) + lh + r(6), width: bw, height: r(23))
    }
}

/// One network. Connected: 32 px icon left, bold black title, connectivity subtitle. Others are mirrored:
/// 24 px icon right, #0061bd title. Clicking expands the row (buttons, optional password field).
private final class WFRow: M7HoverView, NSTextFieldDelegate {
    let net: WifiManager.Network
    var k: CGFloat = 1
    var subtitle: String?
    var expanded = false
    var needsPassword = false
    var onToggleExpand: (() -> Void)?
    var onConnect: ((String?) -> Void)?
    var onDisconnect: (() -> Void)?
    var onContext: ((NSEvent) -> Void)?

    private let actionButton = TFButton("Verbinden")
    private let detailsButton = TFButton("Details")
    private let passwordBox = TFFieldBox(frameName: "wf-lineedit", inset: 3)
    private let password = NSSecureTextField()

    init(_ net: WifiManager.Network) {
        self.net = net
        super.init(frame: .zero)
        actionButton.onClick = { [weak self] in self?.primaryAction() }
        detailsButton.onClick = { TF.openSettings("com.apple.wifi-settings-extension") }
        password.isBordered = false
        password.drawsBackground = false
        password.focusRingType = .none
        password.placeholderString = "Kennwort"
        password.textColor = .black
        password.appearance = NSAppearance(named: .aqua)
        password.delegate = self
        password.target = self
        password.action = #selector(passwordEntered)
        for v in [actionButton, detailsButton, passwordBox, password] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }
    private var connected: Bool { net.current }
    private var iconSize: CGFloat { r(connected ? 32 : 24) }
    private var headHeight: CGFloat { max(iconSize, subtitle != nil ? 2 * r(16) : r(16)) + r(8) }

    /// Expanded area: 4 px margins, buttons (23), then separator + password field if needed.
    private var expandedHeight: CGFloat {
        guard expanded else { return 0 }
        var h = r(4) + r(23) + r(4)
        if needsPassword { h += 1 + r(4) + r(23) + r(4) }
        return h
    }
    var rowHeight: CGFloat { headHeight + expandedHeight }

    /// The Connect action disappears while the password is invalid (8–64 characters), like the original.
    private var passwordValid: Bool { (8...64).contains(password.stringValue.count) }

    private func primaryAction() {
        if connected { onDisconnect?(); return }
        onConnect?(needsPassword ? password.stringValue : nil)
    }
    @objc private func passwordEntered() { if passwordValid { onConnect?(password.stringValue) } }
    func controlTextDidChange(_ obj: Notification) { needsLayout = true }

    func focusPassword() { if needsPassword { window?.makeFirstResponder(password) } }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y <= headHeight { onToggleExpand?() }
    }
    override func rightMouseDown(with event: NSEvent) { onContext?(event) }

    override func layout() {
        super.layout()
        let show = expanded
        actionButton.title = connected ? "Verbindung trennen" : "Verbinden"
        actionButton.isHidden = !show || (needsPassword && !passwordValid)
        detailsButton.isHidden = !show
        passwordBox.isHidden = !(show && needsPassword)
        password.isHidden = passwordBox.isHidden
        guard show else { return }
        actionButton.k = k; detailsButton.k = k
        // Right-to-left flow, first action at the far right, 4 px apart.
        var x = bounds.width - r(4)
        let y = headHeight + r(4)
        for b in [actionButton, detailsButton] where !b.isHidden {
            let w = b.preferredWidth
            x -= w
            b.frame = NSRect(x: x, y: y, width: w, height: r(23))
            x -= r(4)
        }
        if needsPassword {
            let fy = y + r(23) + r(4) + 1 + r(4)
            passwordBox.frame = NSRect(x: r(16), y: fy, width: bounds.width - 2 * r(16), height: r(23))
            password.font = TF.font(k)
            let fh = ceil(password.font!.boundingRectForFont.height) + 2
            password.frame = NSRect(x: passwordBox.frame.minX + r(5), y: (passwordBox.frame.midY - fh / 2).rounded(),
                                    width: passwordBox.frame.width - r(10), height: fh)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering { Menu7Assets.draw(Menu7Assets.frame("wf-hover", 3, 3, 3, 3), in: bounds) }
        let s = iconSize, h = headHeight
        let icon = TF.barsIcon(rssi: net.rssi, secure: net.secure, big: connected)
        let titleFont = TF.font(k, bold: connected)
        let name = net.ssid ?? "WLAN-Netzwerk"
        let textX: CGFloat, textW: CGFloat
        if connected {
            Menu7Assets.draw(icon, in: NSRect(x: r(4), y: ((h - s) / 2).rounded(), width: s, height: s))
            textX = r(4) + s + r(5); textW = bounds.width - textX - r(4)
        } else {
            Menu7Assets.draw(icon, in: NSRect(x: bounds.width - r(4) - s, y: ((h - s) / 2).rounded(), width: s, height: s))
            textX = r(4); textW = bounds.width - r(4) - s - r(5) - textX
        }
        let titleColor = connected ? NSColor.black : TF.hex(0x0061bd)
        if let sub = subtitle {
            let lh = r(16), top = ((h - 2 * lh) / 2).rounded()
            TF.text(name, in: NSRect(x: textX, y: top, width: textW, height: lh), font: titleFont, color: titleColor)
            TF.text(sub, in: NSRect(x: textX, y: top + lh, width: textW, height: lh), font: TF.font(k), color: .black)
        } else {
            TF.text(name, in: NSRect(x: textX, y: 0, width: textW, height: h), font: titleFont, color: titleColor)
        }
        if expanded && needsPassword {
            // widgets/line.svg "horizontal-line": 1 px black at 65 %.
            NSColor(white: 0, alpha: 0.65).setFill()
            NSRect(x: r(4), y: h + r(4) + r(23) + r(4), width: bounds.width - 2 * r(4), height: 1).fill()
        }
    }
}

// MARK: - Controller

final class WifiFlyoutController: NSObject, NSTextFieldDelegate {
    private let host = TrayFlyoutHost(footer: "Netzwerk- und Freigabecenter öffnen")
    private var root: M7FlippedView { host.root }
    private let wifiBox = TFCheckbox("WLAN")
    private let refresh = TFToolButton(icon: "wf-refresh")
    private let searchBox = TFFieldBox(frameName: "wf-search", inset: 6)
    private let search = NSTextField()
    private let scroll = NSScrollView()
    private let listDoc = M7FlippedView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")

    private let wifi = WifiManager.shared
    private var networks: [WifiManager.Network] = []
    private var expanded: String?            // SSID of the expanded row
    private var passwordFor: String?         // SSID whose row asks for the security key
    private var connecting: String?
    private var failed: Set<String> = []
    private var rescan: Timer?
    private var k: CGFloat { host.k }
    private var W: CGFloat { host.W }
    private var H: CGFloat { host.H }
    private func r(_ v: CGFloat) -> CGFloat { host.r(v) }

    var isVisible: Bool { host.isVisible }
    /// Called whenever the Wi-Fi state may have changed (to refresh the tray icon).
    var onStateChange: (() -> Void)?

    override init() {
        super.init()
        host.onEscape = { [weak self] in self?.escape() }
        host.onHide = { [weak self] in self?.rescan?.invalidate(); self?.rescan = nil }
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(wifiChanged),
                                               name: WifiManager.changedNotification, object: nil)
    }

    private func build() {
        wifiBox.onToggle = { [weak self] on in
            self?.wifi.setPower(on)
            self?.networks = []
            self?.reloadList()
            if on { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.scanNow() } }
        }
        refresh.onClick = { [weak self] in self?.scanNow() }
        root.addSubview(wifiBox)
        root.addSubview(refresh)

        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.textColor = .black
        search.appearance = NSAppearance(named: .aqua)
        search.delegate = self
        search.cell?.isScrollable = true
        search.cell?.wraps = false
        root.addSubview(searchBox)
        root.addSubview(search)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy
        scroll.borderType = .noBorder
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.documentView = listDoc
        root.addSubview(scroll)

        placeholder.alignment = .center
        placeholder.textColor = .black
        root.addSubview(placeholder)

        host.footer.onClick = { [weak self] in
            TF.openSettings("com.apple.Network-Settings.extension")
            self?.hide()
        }
    }

    // MARK: Show / hide

    func toggle(anchor: NSRect, on screen: NSScreen) {
        if host.isVisible { hide() } else { show(anchor: anchor, on: screen) }
    }

    func show(anchor: NSRect, on screen: NSScreen) {
        host.setMainSize(width: 272, height: 304)
        search.stringValue = ""
        expanded = nil; passwordFor = nil; failed = []
        networks = DemoMode.on ? DemoMode.wifiNetworks : currentOnly()
        layoutChrome()
        reloadList()

        host.show(anchor: anchor, on: screen)
        host.window.makeFirstResponder(search)
        if wifi.canAskForLocation { wifi.requestLocation() }
        scanNow()
        rescan?.invalidate()
        rescan = Timer.scheduledTimer(withTimeInterval: 10.2, repeats: true) { [weak self] _ in self?.scanNow() }
    }

    func hide() { host.hide() }

    private func escape() {
        if !search.stringValue.isEmpty { search.stringValue = ""; layoutChrome(); reloadList() } else { hide() }
    }

    @objc private func wifiChanged() {
        onStateChange?()
        guard host.isVisible else { return }
        wifiBox.checked = wifi.powerOn
        scanNow()
    }

    // MARK: Data

    /// The current connection before the first scan finishes (so the list isn't empty for seconds).
    private func currentOnly() -> [WifiManager.Network] {
        guard wifi.connected else { return [] }
        return [WifiManager.Network(ssid: wifi.currentSSID, rssi: wifi.currentRSSI, secure: true,
                                    known: true, current: true)]
    }

    private func scanNow() {
        if DemoMode.on { networks = DemoMode.wifiNetworks; reloadList(); return }
        guard wifi.powerOn, !wifi.scanning else { if passwordFor == nil { reloadList() }; return }
        wifi.scan { [weak self] list in
            guard let self, self.host.isVisible else { return }
            var l = list.filter { $0.ssid != nil }
            // Connected but the name is hidden (no Location permission): keep the current connection on top.
            if !l.contains(where: { $0.current }), let cur = self.currentOnly().first { l.insert(cur, at: 0) }
            self.networks = l
            // Don't rebuild the rows while a security key is being typed (it would be lost).
            if self.passwordFor == nil { self.reloadList() }
        }
    }

    private func connect(_ n: WifiManager.Network, password: String?) {
        guard let ssid = n.ssid else { return }
        connecting = ssid
        failed.remove(ssid)
        reloadList()
        wifi.connect(n, password: password) { [weak self] result in
            guard let self else { return }
            self.connecting = nil
            switch result {
            case .success:
                self.expanded = nil; self.passwordFor = nil
            case .failure(.needsPassword):
                self.expanded = ssid; self.passwordFor = ssid
            case .failure(.failed):
                self.failed.insert(ssid)
            }
            self.scanNow()
            self.reloadList()
            if self.passwordFor == ssid { self.rowFor(ssid)?.focusPassword() }
        }
    }

    // MARK: Layout

    private func layoutChrome() {
        // Applet area: main item (8,8, 272 × 304) inset by 8 → window x 16…272, y 16…266.
        let ax = host.appletRect.minX, aw = host.appletRect.width
        wifiBox.k = k
        wifiBox.checked = wifi.powerOn
        wifiBox.enabled = wifi.hasWifi
        wifiBox.frame = NSRect(x: ax + r(2), y: 8 + r(8) + r(2), width: wifiBox.preferredWidth, height: r(22))
        refresh.k = k
        refresh.frame = NSRect(x: ax + aw - r(24) + r(4), y: 8 + r(8) + r(2) - r(4) + r(2), width: r(24), height: r(22))

        // Search field: 0 px while empty, 24 px once something is typed.
        let searching = !search.stringValue.isEmpty
        let sy = wifiBox.frame.maxY + r(5)
        searchBox.frame = NSRect(x: ax, y: sy, width: aw, height: searching ? r(24) : 0)
        searchBox.isHidden = !searching
        search.font = TF.font(k)
        let fh = ceil(search.font!.boundingRectForFont.height) + 2
        search.frame = NSRect(x: ax + r(6), y: searching ? (searchBox.frame.midY - fh / 2).rounded() : sy, width: aw - r(30),
                              height: fh)
        search.alphaValue = searching ? 1 : 0

        // List: full white inner width, from below the heading (6 px padding) to the footer strip.
        let listTop = (searching ? searchBox.frame.maxY : wifiBox.frame.maxY) + r(6)
        scroll.frame = NSRect(x: 8, y: listTop, width: W - 16, height: host.footerTop - listTop)
    }

    private func rowFor(_ ssid: String) -> WFRow? {
        listDoc.subviews.compactMap { $0 as? WFRow }.first { $0.net.ssid == ssid }
    }

    private func reloadList() {
        listDoc.subviews.forEach { $0.removeFromSuperview() }
        let w = scroll.contentSize.width
        var y: CGFloat = 0
        func add(_ v: NSView, _ h: CGFloat) {
            v.frame = NSRect(x: 0, y: y, width: w, height: h)
            v.autoresizingMask = [.width]
            listDoc.addSubview(v)
            y += h + r(4)
        }

        let q = search.stringValue.lowercased()
        let shown = networks.filter { q.isEmpty || ($0.ssid ?? "").lowercased().contains(q) }

        if wifi.powerOn && !wifi.namesVisible {
            let hint = WFHint()
            hint.k = k
            hint.onAllow = { [weak self] in self?.wifi.requestLocation(); self?.hide() }
            add(hint, hint.height(for: w))
        }

        var sectionDone = false
        for n in shown {
            if !n.current && !sectionDone && shown.contains(where: { $0.current }) {
                let s = WFSection("Verfügbare Verbindungen")
                s.k = k
                add(s, r(40))
                sectionDone = true
            }
            let row = WFRow(n)
            row.k = k
            let ssid = n.ssid ?? ""
            if n.current {
                row.subtitle = Self.online() ? "Internetzugriff" : "Kein Internetzugriff"
            } else if connecting == ssid {
                row.subtitle = "Verbindung wird hergestellt …"
            } else if failed.contains(ssid) {
                row.subtitle = "Verbindung fehlgeschlagen"
            }
            row.expanded = expanded == ssid && n.ssid != nil
            row.needsPassword = passwordFor == ssid
            row.onToggleExpand = { [weak self] in
                guard let self, n.ssid != nil else { return }
                self.expanded = self.expanded == ssid ? nil : ssid
                if self.expanded == nil { self.passwordFor = nil }
                self.reloadList()
            }
            row.onConnect = { [weak self] pw in self?.connect(n, password: pw) }
            row.onDisconnect = { [weak self] in
                self?.wifi.disconnect()
                self?.expanded = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.scanNow() }
            }
            row.onContext = { [weak self, weak row] event in
                guard let self, let row else { return }
                let menu = NSMenu()
                let main = NSMenuItem(title: n.current ? "Verbindung trennen" : "Verbinden", action: nil, keyEquivalent: "")
                main.target = self
                main.action = #selector(self.menuAction(_:))
                main.representedObject = { [weak self] in
                    if n.current { self?.wifi.disconnect() } else { self?.connect(n, password: nil) }
                } as () -> Void
                menu.addItem(main)
                let details = NSMenuItem(title: "Details", action: #selector(self.menuAction(_:)), keyEquivalent: "")
                details.target = self
                details.representedObject = { TF.openSettings("com.apple.wifi-settings-extension") } as () -> Void
                menu.addItem(details)
                NSMenu.popUpContextMenu(menu, with: event, for: row)
            }
            add(row, row.rowHeight)
        }
        listDoc.frame = NSRect(x: 0, y: 0, width: w, height: max(y - r(4) + r(8), scroll.contentSize.height))

        // Placeholder, 8 px below the top of the list.
        let text: String? = !wifi.hasWifi ? "Kein WLAN-Adapter gefunden"
            : !wifi.powerOn ? "WLAN ist deaktiviert"
            : shown.isEmpty && !q.isEmpty ? "Keine Übereinstimmungen"
            : shown.isEmpty && wifi.namesVisible && !wifi.scanning ? "Keine verfügbaren Verbindungen" : nil
        placeholder.isHidden = text == nil
        if let t = text {
            placeholder.stringValue = t
            placeholder.font = TF.font(k)
            let pw = scroll.frame.width - 4 * r(8)
            placeholder.preferredMaxLayoutWidth = pw
            let ph = ceil(placeholder.fittingSize.height)
            placeholder.frame = NSRect(x: scroll.frame.minX + 2 * r(8), y: scroll.frame.minY + r(8), width: pw, height: ph)
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === search else { return }
        layoutChrome()
        reloadList()
    }

    private static func online() -> Bool {
        var addr = sockaddr(); addr.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        addr.sa_family = sa_family_t(AF_INET)
        guard let r = SCNetworkReachabilityCreateWithAddress(nil, &addr) else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(r, &flags) else { return false }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }
}
