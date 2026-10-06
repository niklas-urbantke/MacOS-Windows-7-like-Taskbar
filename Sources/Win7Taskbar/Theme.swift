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

    // Configurable icon-frame width (px at the reference height, then scaled). Default 60.
    static let defaultIconWidth: CGFloat = 60
    static var iconWidthValue: CGFloat {
        let v = UserDefaults.standard.object(forKey: "iconWidth") as? Double ?? Double(defaultIconWidth)
        return CGFloat(min(160, max(36, v)))
    }
    static var buttonWidth: CGFloat { s(iconWidthValue) }

    // Configurable gap between the Start orb and the first icon (px, scaled). Default 20.
    static let defaultOrbGap: CGFloat = 20
    static var orbGapValue: CGFloat {
        let v = UserDefaults.standard.object(forKey: "orbGap") as? Double ?? Double(defaultOrbGap)
        return CGFloat(min(120, max(0, v)))
    }
    static var orbGap: CGFloat { s(orbGapValue) }
    static var buttonHeight: CGFloat { s(56) }
    static var buttonSpacing: CGFloat { s(2) }
    static var iconSize: CGFloat { s(56) }
    static var clockWidth: CGFloat { s(clockShowsSeconds ? 110 : 92) }
    static var showDesktopWidth: CGFloat { s(23) }

    // Taskleisten-Stil-Profil (Glas-Optik + empfohlene Blur-/Deckkraftwerte).
    enum TaskbarStyle: String { case vista, win7, win11 }
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
    /// Multiplier (0…1) for the Windows 7 icon-slot glass strength (1.0 = full).
    static var win7GlassStrength: CGFloat { clamped01("win7GlassStrength", 1.0) }
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

// MARK: - Clock & screens

extension Notification.Name {
    /// Posted when the taskbars must be recreated (e.g. "show on all screens" toggled).
    static let taskbarRebuildScreens = Notification.Name("de.batix.win7taskbar.rebuildScreens")
}

extension Theme {
    /// Uhr mit Sekunden (Standard: an).
    static var clockShowsSeconds: Bool {
        UserDefaults.standard.object(forKey: "clockSeconds") == nil ? true : UserDefaults.standard.bool(forKey: "clockSeconds")
    }

    /// Fenstervorschau beim Hovern: eigene Vorschau, DockDoor (per AppleScript) oder aus.
    enum PreviewMode: String { case builtin, dockdoor, off }
    static let dockDoorBundleID = "com.ethanbills.DockDoor"
    static var isDockDoorInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: dockDoorBundleID) != nil
    }
    /// Standard: DockDoor, wenn installiert, sonst die eigene Vorschau.
    static var previewMode: PreviewMode {
        if let raw = UserDefaults.standard.string(forKey: "previewMode"), let m = PreviewMode(rawValue: raw) { return m }
        return isDockDoorInstalled ? .dockdoor : .builtin
    }
    /// Taskleiste auf allen Bildschirmen (Standard: an). Nebenbildschirme ohne Medien/Leistung.
    static var showOnAllScreens: Bool {
        UserDefaults.standard.object(forKey: "allScreens") == nil ? true : UserDefaults.standard.bool(forKey: "allScreens")
    }
}

// MARK: - Farbmodus (alle Profile) + Aero-Palette für Vista/Win7

extension Theme {
    /// Farbmodus für alle Profile (System / Hell / Dunkel). Gespeichert unter dem bisherigen
    /// Schlüssel `win11Appearance`, damit bestehende Einstellungen erhalten bleiben.
    static var appearanceMode: Win11Appearance { win11Appearance }
    static var isDark: Bool { win11Dark }
    static var nsAppearance: NSAppearance { win11NSAppearance }

    /// Palette of the classic Aero profiles (Vista, Windows 7) in dark and light mode.
    /// Dark = the familiar dark Aero glass; light = bright frosted Aero glass with dark text.
    enum Aero {
        private static var dark: Bool { Theme.isDark }
        private static func mono(_ w: CGFloat, _ a: CGFloat) -> NSColor { NSColor(calibratedWhite: w, alpha: a) }

        /// Text and glyphs on the taskbar and on glass panels.
        static var text: NSColor { dark ? mono(0.96, 1) : mono(0.08, 0.92) }
        static var secondaryText: NSColor { dark ? mono(0.85, 1) : mono(0.20, 0.72) }
        static var disabledText: NSColor { dark ? mono(0.60, 1) : mono(0.35, 0.50) }
        /// Extra wash drawn over the taskbar glass/texture in light mode (clear in dark mode).
        static var barWash: NSColor { dark ? .clear : mono(1, 0.55) }
        /// Glass panels (flyouts, window preview): vertical gradient top → bottom.
        static var panelTop: NSColor { dark ? mono(0.30, 0.55) : mono(1.00, 0.72) }
        static var panelBottom: NSColor { dark ? mono(0.04, 0.72) : mono(0.86, 0.82) }
        /// Outer border and the bright inner highlight line of glass panels.
        static var stroke: NSColor { dark ? mono(1, 0.30) : mono(0, 0.28) }
        static var innerHighlight: NSColor { dark ? mono(1, 0.22) : mono(1, 0.85) }
        /// Hover / pressed glass on controls inside panels and the tray.
        static var hover: NSColor { dark ? mono(1, 0.18) : mono(1, 0.60) }
        static var pressed: NSColor { dark ? mono(1, 0.10) : mono(0, 0.08) }
        /// Tracks of sliders / progress bars.
        static var track: NSColor { dark ? mono(1, 0.25) : mono(0, 0.15) }
        /// Accent (progress fill, today marker …), lifted a bit on dark glass.
        static var accent: NSColor { dark ? Theme.accent(brightness: 1.3) : Theme.accent }
    }
}

// MARK: - Windows 11 profile

extension Theme {
    static var isWin11: Bool { taskbarStyle == .win11 }

    /// Farbmodus des Win11-Profils: System (Standard), Hell oder Dunkel.
    enum Win11Appearance: String { case system, light, dark }
    static var win11Appearance: Win11Appearance {
        Win11Appearance(rawValue: UserDefaults.standard.string(forKey: "win11Appearance") ?? "") ?? .system
    }
    /// Effective dark/light for the Win11 profile (System follows the macOS appearance).
    static var win11Dark: Bool {
        switch win11Appearance {
        case .light: return false
        case .dark: return true
        case .system: return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
    }
    static var win11NSAppearance: NSAppearance {
        NSAppearance(named: win11Dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }
    /// Acryl-Look: everything slightly translucent (blur behind). Off = opaque surfaces. Default on.
    static var win11Acrylic: Bool {
        UserDefaults.standard.object(forKey: "win11Acrylic") == nil ? true : UserDefaults.standard.bool(forKey: "win11Acrylic")
    }
    /// Icon alignment: centred (Win11 default) or left.
    static var win11Centered: Bool { UserDefaults.standard.string(forKey: "win11Alignment") != "left" }

    /// Metrics and palette of the Windows 11 look. Metrics are designed at a 48 px bar and scale
    /// with the configured bar height (`Win11.s`), independent of the 60 px Win7 reference.
    enum Win11 {
        static let referenceHeight: CGFloat = 48
        static var k: CGFloat { Theme.barHeight / referenceHeight }
        static func s(_ base: CGFloat) -> CGFloat { (base * k).rounded() }
        static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.systemFont(ofSize: size * k, weight: weight)
        }

        /// Icon size of the macOS Dock (`com.apple.dock tilesize`), default 48.
        static var dockTileSize: CGFloat {
            let v = CFPreferencesCopyAppValue("tilesize" as CFString, "com.apple.dock" as CFString) as? Double ?? 48
            return CGFloat(min(96, max(24, v)))
        }
        /// Recommended bar height derived from the Dock size: icons at about 83 % of the Dock icons
        /// (icon = 75 % of the bar), e.g. Dock 54 → bar 60 with 45 px icons.
        static var recommendedBarHeight: CGFloat {
            min(Theme.maxHeight, max(Theme.minHeight, (dockTileSize * 0.83 / 0.75).rounded()))
        }

        // Taskbar metrics (scaled). Icons fill 75 % of the bar.
        static var iconSize: CGFloat { s(36) }
        static var slotWidth: CGFloat { s(46) }
        static var slotHeight: CGFloat { s(44) }
        static var slotSpacing: CGFloat { s(3) }
        static var startWidth: CGFloat { s(46) }
        static var startLogoSize: CGFloat { s(22) }
        static var buttonRadius: CGFloat { max(3, s(4)) }
        static var pillHeight: CGFloat { max(2, s(3)) }
        static var pillShort: CGFloat { s(6) }
        static var pillLong: CGFloat { s(16) }
        static var showDesktopWidth: CGFloat { s(8) }
        /// The tray text grows only half as fast as the bar (see `Win11TrayDraw.tk`), so does the clock.
        static var clockWidth: CGFloat {
            ((Theme.clockShowsSeconds ? 86 : 78) * (1 + (k - 1) * 0.5)).rounded()
        }
        // Panels (start menu, flyouts) are not scaled.
        static let panelRadius: CGFloat = 8

        // MARK: Palette (dark / light)

        private static var dark: Bool { Theme.win11Dark }
        private static func mono(_ white: CGFloat, _ alpha: CGFloat) -> NSColor {
            NSColor(calibratedWhite: white, alpha: alpha)
        }

        /// The three Acryl surfaces. Same effect by default, each adjustable on its own.
        enum Surface: String, CaseIterable { case bar, menu, flyout }

        static let defaultFrost: CGFloat = 0.88
        static let defaultTint: CGFloat = 0.25
        private static func stored(_ key: String, _ fallback: CGFloat) -> CGFloat {
            guard let v = UserDefaults.standard.object(forKey: key) as? Double else { return fallback }
            return CGFloat(min(1, max(0, v)))
        }
        /// Frost (the grainy blur layer) of a surface, 0…1.
        static func frost(_ role: Surface) -> CGFloat { stored("win11Frost.\(role.rawValue)", defaultFrost) }
        /// Tönung (opacity of the colour layer above the frost) of a surface, 0…1.
        static func tint(_ role: Surface) -> CGFloat { stored("win11Tint.\(role.rawValue)", defaultTint) }

        /// Base fill of a surface: the tint colour with the surface's Tönung (opaque when Acryl is off).
        /// Light mode gets a little more tint, otherwise dark text loses contrast.
        static func surface(_ role: Surface) -> NSColor {
            let on = Theme.win11Acrylic
            let t = tint(role)
            let white: CGFloat = role == .bar ? (dark ? 0.11 : 0.94) : (dark ? 0.16 : 0.95)
            return mono(white, on ? (dark ? t : min(1, t + 0.08)) : 1)
        }
        /// Configures the frost layer of a Win11 surface (hidden when Acryl is off).
        static func configureBlur(_ v: NSVisualEffectView, for role: Surface = .menu) {
            v.material = .underWindowBackground
            v.blendingMode = .behindWindow
            v.state = .active
            v.appearance = Theme.win11NSAppearance
            v.alphaValue = frost(role)
            v.isHidden = !Theme.win11Acrylic
        }

        static var hoverFill: NSColor { dark ? mono(1, 0.08) : mono(0, 0.05) }
        static var pressedFill: NSColor { dark ? mono(1, 0.05) : mono(0, 0.03) }
        static var activeFill: NSColor { dark ? mono(1, 0.12) : mono(1, 0.70) }
        static var activeStroke: NSColor { dark ? mono(1, 0.06) : mono(0, 0.06) }
        /// Subtle fill for controls (search pill, sliders' track, tiles).
        static var controlFill: NSColor { dark ? mono(1, 0.06) : mono(1, 0.75) }
        static var controlStroke: NSColor { dark ? mono(1, 0.08) : mono(0, 0.08) }
        static var runningPill: NSColor { dark ? mono(1, 0.55) : mono(0, 0.45) }
        static var hairline: NSColor { dark ? mono(1, 0.08) : mono(0, 0.08) }
        static var panelStroke: NSColor { dark ? mono(1, 0.10) : mono(0, 0.10) }
        static var textPrimary: NSColor { dark ? mono(1, 0.96) : mono(0, 0.90) }
        static var textSecondary: NSColor { dark ? mono(1, 0.64) : mono(0, 0.60) }
        static var textDisabled: NSColor { dark ? mono(1, 0.30) : mono(0, 0.28) }
        /// System accent colour, lifted a bit in dark mode (like Win11 does).
        static var accent: NSColor { dark ? Theme.accent(brightness: 1.25, saturation: 0.8) : Theme.accent }
        /// Text/icon colour on top of an accent fill.
        static var onAccent: NSColor { dark ? mono(0, 0.92) : mono(1, 1) }
        static var warning: NSColor { NSColor.systemOrange }
    }
}
