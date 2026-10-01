import AppKit
import CoreWLAN

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

/// Wi-Fi status icon: shows connection state, SSID as tooltip, opens Wi-Fi settings on click.
final class WifiView: NSView {
    private var connected = false
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

    func refresh() {
        // Without Location permission macOS hides the SSID, so a signal (RSSI) also counts as connected.
        let iface = CWWiFiClient.shared().interface()
        let ssid = iface?.ssid()
        connected = ssid != nil || (iface?.powerOn() == true && (iface?.rssiValue() ?? 0) != 0)
        toolTip = ssid ?? (connected ? "WLAN verbunden" : "Kein WLAN")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering { ClassicTray.fillHover(bounds.insetBy(dx: 1, dy: 8)) }
        let name = connected ? "wifi" : "wifi.slash"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15 * Theme.scale, weight: .regular)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let color = connected ? ClassicTray.text
            : ClassicTray.pick(NSColor(calibratedWhite: 0.6, alpha: 1), Theme.Aero.disabledText)
        let tinted = ClassicTray.tinted(img, color)
        let s = tinted.size
        tinted.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2,
                               width: s.width, height: s.height))
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
        let w = max(Theme.s(8), min(Theme.s(18), bounds.width - x - Theme.s(2)))
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
