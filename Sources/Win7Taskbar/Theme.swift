import AppKit

/// Central place for the Windows-7-ish metrics and colours so the look stays consistent.
enum Theme {
    // Bar — 60px tall, wide Win7 "large icon" frames.
    static let barHeight: CGFloat = 60
    static let orbWidth: CGFloat = 72
    static let buttonWidth: CGFloat = 100
    static let buttonHeight: CGFloat = 56
    static let buttonSpacing: CGFloat = 4
    static let iconSize: CGFloat = 52
    static let clockWidth: CGFloat = 100
    static let showDesktopWidth: CGFloat = 16

    // Aero glass colours (drawn on top of a dark NSVisualEffectView).
    static let glassTop = NSColor(calibratedWhite: 0.30, alpha: 0.55)
    static let glassBottom = NSColor(calibratedWhite: 0.04, alpha: 0.72)
    static let topHighlight = NSColor(calibratedWhite: 1.0, alpha: 0.22)

    // Taskbar button states.
    static let runningFill = NSColor(calibratedWhite: 1.0, alpha: 0.10)
    static let runningStroke = NSColor(calibratedWhite: 1.0, alpha: 0.18)
    static let hoverFill = NSColor(calibratedWhite: 1.0, alpha: 0.22)
    static let activeFillTop = NSColor(calibratedRed: 0.62, green: 0.80, blue: 1.0, alpha: 0.42)
    static let activeFillBottom = NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.95, alpha: 0.42)
    static let activeStroke = NSColor(calibratedRed: 0.70, green: 0.86, blue: 1.0, alpha: 0.65)

    static let labelColor = NSColor(calibratedWhite: 0.96, alpha: 1.0)

    static let orbTop = NSColor(calibratedRed: 0.45, green: 0.74, blue: 1.0, alpha: 1.0)
    static let orbBottom = NSColor(calibratedRed: 0.06, green: 0.30, blue: 0.62, alpha: 1.0)

    // System tray (right side).
    static let batteryWidth: CGFloat = 56
    static let volumeWidth: CGFloat = 30
    static let nowPlayingWidth: CGFloat = 210
    static let wifiWidth: CGFloat = 30
    static let monitorWidth: CGFloat = 80

    // macOS accent colour the user picked in System Settings, with brightness variants.
    static var accent: NSColor { NSColor.controlAccentColor }

    static func accent(brightness mult: CGFloat, saturation satMult: CGFloat = 1, alpha: CGFloat = 1) -> NSColor {
        let base = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * satMult), brightness: min(1, b * mult), alpha: alpha)
    }

    // Start menu.
    static let startWidth: CGFloat = 560
    static let startHeight: CGFloat = 680
    static let startLeftWidth: CGFloat = 330
    static let rightTop = NSColor(calibratedRed: 0.56, green: 0.74, blue: 0.93, alpha: 1.0)
    static let rightBottom = NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.83, alpha: 1.0)
    static let leftHover = NSColor(calibratedRed: 0.83, green: 0.91, blue: 0.99, alpha: 1.0)
    static let leftHoverStroke = NSColor(calibratedRed: 0.55, green: 0.74, blue: 0.95, alpha: 1.0)
    static let rightHover = NSColor(calibratedWhite: 1.0, alpha: 0.22)
}
