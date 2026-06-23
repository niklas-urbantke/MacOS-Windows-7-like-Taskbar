import AppKit

/// Central place for the Windows-7-ish metrics and colours so the look stays consistent.
enum Theme {
    // The bar height is configurable; everything else scales relative to a reference of 60px.
    static let referenceHeight: CGFloat = 60
    static let minHeight: CGFloat = 40
    static let maxHeight: CGFloat = 100

    static var barHeight: CGFloat {
        let v = UserDefaults.standard.object(forKey: "barHeight") as? Double ?? Double(referenceHeight)
        return CGFloat(min(Double(maxHeight), max(Double(minHeight), v)))
    }
    static var scale: CGFloat { barHeight / referenceHeight }
    /// Scale a base measurement (designed at the reference height) to the current height.
    static func s(_ base: CGFloat) -> CGFloat { (base * scale).rounded() }
    /// A system font scaled to the current bar height.
    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size * scale, weight: weight)
    }

    // Bar metrics (base values at the reference height), scaled.
    static var orbWidth: CGFloat { s(72) }
    static var buttonWidth: CGFloat { s(100) }
    static var buttonHeight: CGFloat { s(56) }
    static var buttonSpacing: CGFloat { s(4) }
    static var iconSize: CGFloat { s(56) }
    static var clockWidth: CGFloat { s(92) }
    static var showDesktopWidth: CGFloat { s(16) }

    // Taskleisten-Stil-Profil (Glas-Optik + empfohlene Blur-/Deckkraftwerte).
    enum TaskbarStyle: String { case vista, win7 }
    static var taskbarStyle: TaskbarStyle {
        TaskbarStyle(rawValue: UserDefaults.standard.string(forKey: "taskbarStyle") ?? "vista") ?? .vista
    }
    // Win7 uses a translucent texture overlay, so it carries its own transparency → opacity 1.0.
    static func defaultBlur(for s: TaskbarStyle) -> CGFloat { s == .win7 ? 0.55 : 0.55 }
    static func defaultOpacity(for s: TaskbarStyle) -> CGFloat { 1.0 }

    // Transparenz / Unschärfe (getrennt für Taskleiste und Startmenü), jeweils 0…1.
    // "Blur" steuert die Deckkraft der Frost-Schicht (NSVisualEffectView),
    // "Opacity" die Deckkraft der dunklen Glas-Tönung darüber.
    static let defaultTaskbarBlur: CGFloat = 0.55
    static let defaultTaskbarOpacity: CGFloat = 1.0
    static let defaultMenuBlur: CGFloat = 0.45
    static let defaultMenuOpacity: CGFloat = 1.0

    private static func clamped01(_ key: String, _ fallback: CGFloat) -> CGFloat {
        guard let v = UserDefaults.standard.object(forKey: key) as? Double else { return fallback }
        return CGFloat(min(1.0, max(0.0, v)))
    }
    static var taskbarBlur: CGFloat { clamped01("taskbarBlur", defaultTaskbarBlur) }
    static var taskbarOpacity: CGFloat { clamped01("taskbarOpacity", defaultTaskbarOpacity) }
    static var menuBlur: CGFloat { clamped01("menuBlur", defaultMenuBlur) }
    static var menuOpacity: CGFloat { clamped01("menuOpacity", defaultMenuOpacity) }

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

    // System tray (right side), scaled.
    static var batteryWidth: CGFloat { s(56) }
    static var volumeWidth: CGFloat { s(30) }
    static var nowPlayingWidth: CGFloat { s(210) }
    static var wifiWidth: CGFloat { s(30) }
    static var monitorWidth: CGFloat { s(80) }

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
