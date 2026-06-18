import AppKit

/// The Aero-glass strip drawn over the blurred NSVisualEffectView: a glossy top band,
/// a translucent dark body, a bright top hairline and a faint accent-tinted reflection.
final class GlassBackgroundView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height

        // Body: light glossy top → translucent dark bottom.
        let body = NSGradient(colors: [
            NSColor(calibratedWhite: 0.55, alpha: 0.42),
            NSColor(calibratedWhite: 0.22, alpha: 0.40),
            NSColor(calibratedWhite: 0.05, alpha: 0.55),
            NSColor(calibratedWhite: 0.02, alpha: 0.72),
        ], atLocations: [0.0, 0.42, 0.5, 1.0], colorSpace: .deviceRGB)
        body?.draw(in: bounds, angle: -90)

        // Top gloss highlight over the upper ~45 %.
        let glossRect = NSRect(x: 0, y: h * 0.55, width: bounds.width, height: h * 0.45)
        let gloss = NSGradient(colors: [
            NSColor(calibratedWhite: 1.0, alpha: 0.28),
            NSColor(calibratedWhite: 1.0, alpha: 0.02),
        ])
        gloss?.draw(in: glossRect, angle: -90)

        // Bright top hairline.
        NSColor(calibratedWhite: 1.0, alpha: 0.45).setFill()
        NSRect(x: 0, y: h - 1, width: bounds.width, height: 1).fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.12).setFill()
        NSRect(x: 0, y: h - 2, width: bounds.width, height: 1).fill()
    }
}
