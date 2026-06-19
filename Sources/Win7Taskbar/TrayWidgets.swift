import AppKit
import CoreWLAN

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
    override func mouseDown(with event: NSEvent) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func refresh() {
        let ssid = CWWiFiClient.shared().interface()?.ssid()
        connected = (ssid != nil)
        toolTip = ssid ?? "Kein WLAN"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.accent(brightness: 1.2, alpha: 0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 8), xRadius: 4, yRadius: 4).fill()
        }
        let name = connected ? "wifi" : "wifi.slash"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            (self.connected ? NSColor.white : NSColor(calibratedWhite: 0.6, alpha: 1)).set()
            rect.fill(using: .sourceAtop)
            return true
        }
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        NSAttributedString(string: "CPU \(cpu)%", attributes: attrs)
            .draw(at: NSPoint(x: 6, y: bounds.midY + 1))
        NSAttributedString(string: "RAM \(ram)%", attributes: attrs)
            .draw(at: NSPoint(x: 6, y: bounds.midY - 15))

        // Tiny bars on the right.
        drawBar(value: cpu, y: bounds.midY + 3)
        drawBar(value: ram, y: bounds.midY - 11)
    }

    private func drawBar(value: Int, y: CGFloat) {
        let track = NSRect(x: bounds.minX + 54, y: y, width: 18, height: 6)
        NSColor(calibratedWhite: 1, alpha: 0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fillW = track.width * CGFloat(value) / 100
        let color = value >= 85 ? NSColor.systemRed : Theme.accent(brightness: 1.2)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: fillW, height: track.height),
                     xRadius: 2, yRadius: 2).fill()
    }
}
