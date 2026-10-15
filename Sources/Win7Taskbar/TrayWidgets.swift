import AppKit
import CoreWLAN
import SystemConfiguration

/// Colours and helpers of the classic (Vista / Windows 7) tray. Dark mode keeps the original
/// values exactly, light mode uses the Aero palette (dark glyphs on bright glass).
enum ClassicTray {
    /// `dark` on the dark glass (the original value), `light` on the bright glass.
    static func pick(_ dark: NSColor, _ light: NSColor) -> NSColor { Theme.isDark ? dark : light }

    /// Primary text / glyph colour (white on dark glass).
    static var text: NSColor { pick(.white, Theme.Aero.text) }

    /// Hover field of a tray element: accent-tinted glass, on bright glass with a thin accent rim.
    static func fillHover(_ rect: NSRect, radius: CGFloat = 4) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if Theme.isDark {
            Theme.accent(brightness: 1.2, alpha: 0.22).setFill()
            path.fill()
            return
        }
        Theme.Aero.hover.setFill()
        path.fill()
        Theme.accent(brightness: 1, alpha: 0.16).setFill()
        path.fill()
        Theme.accent(brightness: 1, alpha: 0.45).setStroke()
        let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        rim.lineWidth = 1
        rim.stroke()
    }

    /// Draws an original Windows 7 tray PNG (bundled in ThemeResources, loaded via ThemeAssets),
    /// scaled to `glyph` height and centred in `rect`, preserving aspect ratio. These icons are made
    /// for dark Aero glass (light glyphs), so on the bright glass a soft dark shadow lifts them.
    static func drawIcon(_ name: String, in rect: NSRect, glyph: CGFloat, tint: NSColor? = nil) {
        guard let base = ThemeAssets.image(name) else { return }
        let img = tint.map { tinted(base, $0) } ?? base
        let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
        let h = glyph, w = (h * aspect).rounded()
        let dst = NSRect(x: (rect.width - w) / 2 + rect.minX,
                         y: (rect.height - h) / 2 + rect.minY, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        if !Theme.isDark {
            let sh = NSShadow()
            sh.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.55)
            sh.shadowBlurRadius = 1.5
            sh.shadowOffset = NSSize(width: 0, height: -0.5)
            sh.set()
        }
        img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `image` (an SF symbol) coloured with `color`. The glyph is used as alpha mask, so a
    /// translucent colour keeps its own alpha (same result as a sourceAtop tint for opaque ones).
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
    }
}

/// Network status icon (original Windows 7 symbols): Wi-Fi with signal strength, wired, or
/// disconnected. SSID as tooltip, opens network settings on click.
final class WifiView: NSView {
    private enum State { case wireless(Int), wired, disconnected }   // wireless: 0/25/50/75/100
    private var state: State = .disconnected
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// Any default-route connectivity (used to tell "wired" from "no network" when Wi-Fi is off).
    private func isOnline() -> Bool {
        var addr = sockaddr(); addr.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        addr.sa_family = sa_family_t(AF_INET)
        guard let r = SCNetworkReachabilityCreateWithAddress(nil, &addr) else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(r, &flags) else { return false }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }

    func refresh() {
        let iface = CWWiFiClient.shared().interface()
        // Without Location permission macOS hides the SSID, so a signal (RSSI) also counts as connected.
        let wifiOn = iface?.powerOn() == true
        let ssid = iface?.ssid()
        let rssi = iface?.rssiValue() ?? 0
        let wifiConnected = wifiOn && (ssid != nil || rssi != 0)

        if wifiConnected {
            state = .wireless(Self.bucket(rssi: rssi))
            toolTip = ssid ?? "WLAN verbunden"
        } else if isOnline() {
            state = .wired
            toolTip = "Netzwerk verbunden (LAN)"
        } else {
            state = .disconnected
            toolTip = "Kein Netzwerk"
        }
        needsDisplay = true
    }

    /// RSSI (dBm) → one of the five original signal levels.
    private static func bucket(rssi: Int) -> Int {
        switch rssi {
        case 0: return 100          // connected but RSSI hidden (no Location permission)
        case (-55)...: return 100
        case (-65)...: return 75
        case (-72)...: return 50
        case (-80)...: return 25
        default: return 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering { ClassicTray.fillHover(bounds.insetBy(dx: 1, dy: 8)) }
        let name: String
        switch state {
        case .wireless(let lvl): name = "tray-wifi-\(lvl)"
        case .wired:             name = "tray-wired"
        case .disconnected:      name = "tray-wifi-off"
        }
        ClassicTray.drawIcon(name, in: bounds, glyph: Theme.s(Theme.trayGlyph(for: "network")))
    }
}

/// Volume status icon (original Windows 7 speaker). Level/mute are polled from CoreAudio; click
/// opens the volume slider popover (wired up by the controller).
final class VolumeView: NSView {
    var onClick: (() -> Void)?
    private var level = 100
    private var muted = false
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    func refresh() {
        if let m = SystemInfo.isMutedFast() { muted = m }
        if let v = SystemInfo.outputVolumeFast() { level = v }
        toolTip = muted ? "Ton aus" : "Lautstärke \(level) %"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering { ClassicTray.fillHover(bounds.insetBy(dx: 1, dy: 8)) }
        let name: String
        if muted || level == 0 { name = "tray-vol-muted" }
        else if level < 34 { name = "tray-vol-low" }
        else if level < 67 { name = "tray-vol-medium" }
        else { name = "tray-vol-high" }
        ClassicTray.drawIcon(name, in: bounds, glyph: Theme.s(Theme.trayGlyph(for: "volume")))
    }
}

/// Windows 7 "Action Center" flag. Click opens macOS notification settings (the closest analogue).
final class NotificationFlagView: NSView {
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Benachrichtigungen"
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        SystemInfo.openNotificationCenter()
    }

    func refresh() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovering { ClassicTray.fillHover(bounds.insetBy(dx: 1, dy: 8)) }
        // Original upright Windows 7 flag (already white); light-mode shadow handled by drawIcon.
        ClassicTray.drawIcon("tray-flag", in: bounds, glyph: Theme.s(Theme.trayGlyph(for: "flag")))
    }
}

/// Compact CPU / RAM usage readout. Toggleable via settings.
final class HardwareMonitorView: NSView {
    private let stats = SystemStats()
    private var cpu = 0
    private var ram = 0

    func refresh() {
        cpu = stats.cpuUsagePercent()
        ram = stats.ramUsagePercent()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5 * Theme.scale, weight: .medium),
            .foregroundColor: ClassicTray.text,
        ]
        NSAttributedString(string: "CPU \(cpu)%", attributes: attrs)
            .draw(at: NSPoint(x: Theme.s(6), y: bounds.midY + Theme.s(1)))
        NSAttributedString(string: "RAM \(ram)%", attributes: attrs)
            .draw(at: NSPoint(x: Theme.s(6), y: bounds.midY - Theme.s(15)))

        // Tiny bars on the right, starting after the widest possible label ("RAM 100%").
        let barX = Theme.s(6) + ceil(NSAttributedString(string: "RAM 100%", attributes: attrs).size().width) + Theme.s(4)
        drawBar(value: cpu, x: barX, y: bounds.midY + Theme.s(3))
        drawBar(value: ram, x: barX, y: bounds.midY - Theme.s(11))
    }

    private func drawBar(value: Int, x: CGFloat, y: CGFloat) {
        // Fill the remaining width so the load is actually readable (widen the widget in settings).
        let w = max(Theme.s(12), bounds.width - x - Theme.s(4))
        let track = NSRect(x: bounds.minX + x, y: y, width: w, height: Theme.s(6))
        ClassicTray.pick(NSColor(calibratedWhite: 1, alpha: 0.2), Theme.Aero.track).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fillW = track.width * CGFloat(value) / 100
        let color = value >= 85 ? NSColor.systemRed : ClassicTray.pick(Theme.accent(brightness: 1.2), Theme.Aero.accent)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: fillW, height: track.height),
                     xRadius: 2, yRadius: 2).fill()
    }
}
