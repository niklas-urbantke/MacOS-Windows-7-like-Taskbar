import AppKit

/// The Windows 7 window colour ("Fensterfarbe und -darstellung"), shared by the Windows-7 taskbar and
/// the original Start menu: one of the 16 Windows 7 colours, a custom colour, the macOS accent colour
/// or no colourisation at all, plus the colour intensity and the transparency switch.
/// The presets are the values AeroGlassBlur pulls directly from Windows 7 (kcm/mainwindow.h,
/// aeroshell-kwin-components): ARGB with the intensity in the alpha byte.
enum AeroColor {
    struct Preset { let id: String; let name: String; let rgb: UInt32; let intensity: Int }

    static let presets: [Preset] = [
        Preset(id: "sky", name: "Himmel", rgb: 0x74b8fc, intensity: 0x6b),
        Preset(id: "twilight", name: "Dämmerung", rgb: 0x0046ad, intensity: 0xa8),
        Preset(id: "sea", name: "Meer", rgb: 0x32cdcd, intensity: 0x80),
        Preset(id: "leaf", name: "Blatt", rgb: 0x14a600, intensity: 0x66),
        Preset(id: "lime", name: "Limone", rgb: 0x97d937, intensity: 0x66),
        Preset(id: "sun", name: "Sonne", rgb: 0xfadc0e, intensity: 0x54),
        Preset(id: "pumpkin", name: "Kürbis", rgb: 0xff9c00, intensity: 0x80),
        Preset(id: "ruby", name: "Rubin", rgb: 0xce0f0f, intensity: 0xa8),
        Preset(id: "fuchsia", name: "Fuchsie", rgb: 0xff0099, intensity: 0x66),
        Preset(id: "blush", name: "Rouge", rgb: 0xfcc7f8, intensity: 0x70),
        Preset(id: "violet", name: "Violett", rgb: 0x6e3ba1, intensity: 0x85),
        Preset(id: "lavender", name: "Lavendel", rgb: 0x8d5a94, intensity: 0x52),
        Preset(id: "taupe", name: "Taupe", rgb: 0x98844c, intensity: 0x66),
        Preset(id: "chocolate", name: "Schokolade", rgb: 0x4f1b1b, intensity: 0xa8),
        Preset(id: "slate", name: "Schiefer", rgb: 0x555555, intensity: 0x80),
        Preset(id: "frost", name: "Frost", rgb: 0xfcfcfc, intensity: 0x54),
    ]

    enum Mode: String { case preset, custom, accent, none }

    /// What the glass is coloured with: `color == nil` means clear glass (blur only).
    struct Spec { var color: NSColor?; var intensity: Int; var transparent: Bool }

    /// The Windows 7 colour-intensity slider range.
    static let intensityRange = 26...217
    static let defaultPresetID = "sky"

    private static var ud: UserDefaults { .standard }

    static var mode: Mode { Mode(rawValue: ud.string(forKey: "aeroColorMode") ?? "") ?? .preset }
    static var preset: Preset {
        let id = ud.string(forKey: "aeroPreset") ?? defaultPresetID
        return presets.first { $0.id == id } ?? presets[0]
    }
    static var customColor: NSColor {
        guard let hex = ud.string(forKey: "aeroCustomColor"), let v = UInt32(hex, radix: 16) else { return color(presets[0].rgb) }
        return color(v)
    }
    static var intensity: Int {
        let v = ud.object(forKey: "aeroIntensity") as? Int ?? preset.intensity
        return min(intensityRange.upperBound, max(intensityRange.lowerBound, v))
    }
    static var transparency: Bool { ud.object(forKey: "aeroTransparency") as? Bool ?? true }

    static var current: Spec {
        let c: NSColor?
        switch mode {
        case .preset: c = color(preset.rgb)
        case .custom: c = customColor
        case .accent: c = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        case .none: c = nil
        }
        return Spec(color: c, intensity: intensity, transparent: transparency)
    }

    /// Name of the current choice, for the settings ("Aktuelle Farbe: …").
    static var displayName: String {
        switch mode {
        case .preset: return preset.name
        case .custom: return "Eigene Farbe"
        case .accent: return "macOS-Akzentfarbe"
        case .none: return "Ohne Einfärbung"
        }
    }

    /// Choosing a Windows 7 colour also takes over its intensity, as Windows 7 does.
    static func select(preset p: Preset) {
        ud.set(Mode.preset.rawValue, forKey: "aeroColorMode")
        ud.set(p.id, forKey: "aeroPreset")
        ud.set(p.intensity, forKey: "aeroIntensity")
    }
    static func select(mode m: Mode) { ud.set(m.rawValue, forKey: "aeroColorMode") }
    static func setCustomColor(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? c
        let v = (UInt32((s.redComponent * 255).rounded()) << 16) | (UInt32((s.greenComponent * 255).rounded()) << 8)
            | UInt32((s.blueComponent * 255).rounded())
        ud.set(String(format: "%06x", v), forKey: "aeroCustomColor")
        select(mode: .custom)
    }
    static func setIntensity(_ v: Int) {
        ud.set(min(intensityRange.upperBound, max(intensityRange.lowerBound, v)), forKey: "aeroIntensity")
    }
    static func setTransparency(_ on: Bool) { ud.set(on, forKey: "aeroTransparency") }

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

/// Windows 7 DWM colourisation as implemented by AeroGlassBlur (advanced.frag + wackyfunc.h):
/// result = colour·primary + colour·luma(backdrop)·afterglow + backdrop·blur.
enum AeroGlass {
    /// getColorBalances() from wackyfunc.h (ALTaleX's dwm_colorization_calculator): percentages.
    static func balances(_ slider: Int) -> (primary: CGFloat, afterglow: CGFloat, blur: CGFloat) {
        if slider == 0 { return (100, 0, 100) }
        let balance = Int((Double(slider) / 255.0 - 0.1) / 0.75 * 100.0 + 10.0)
        if balance < 50 { let b = 100 - balance; return (5, CGFloat(100 - 5 - b), CGFloat(b)) }
        if balance < 95 { let a = 95 - balance, b = 50 - ((balance - 50) >> 1); return (CGFloat(100 - a - b), CGFloat(a), CGFloat(b)) }
        return (CGFloat(balance - 25), 0, CGFloat(100 - (balance - 25)))
    }

    /// Opaque glass (transparency off, opaque.frag): colour·A + 0.871·(1 − A), A = (intensity − 26)/191.
    private static func opaque(_ c: [CGFloat], intensity: Int) -> [CGFloat] {
        let a = max(0, min(1, CGFloat(intensity - 26) / 191))
        return c.map { $0 * a + 0.871 * (1 - a) }
    }

    private static func rgb(_ color: NSColor) -> [CGFloat] {
        let c = color.usingColorSpace(.sRGB) ?? color
        return [c.redComponent, c.greenComponent, c.blueComponent]
    }

    /// The colourisation as a uniform overlay over the blurred backdrop (fallback without the
    /// backdrop layer): alpha = 1 − blur balance, colour = (primary + afterglow·L)/alpha · colour,
    /// with L the typical luma of the blurred backdrop.
    static func overlay(_ s: AeroColor.Spec, assumedLuma L: CGFloat = 0.4) -> NSColor {
        guard let color = s.color else { return .clear }
        let c = rgb(color)
        if !s.transparent {
            let o = opaque(c, intensity: s.intensity)
            return NSColor(srgbRed: o[0], green: o[1], blue: o[2], alpha: 1)
        }
        let b = balances(s.intensity)
        let a = max(0.01, 1 - b.blur / 100)
        let f = (b.primary / 100 + b.afterglow / 100 * L) / a
        return NSColor(srgbRed: min(1, c[0] * f), green: min(1, c[1] * f), blue: min(1, c[2] * f), alpha: a)
    }

    /// The exact colourisation as a 4×5 colour matrix applied to the blurred backdrop:
    /// out = blur·B + afterglow·C·dot(B, (0.299, 0.587, 0.114)) + primary·C, alpha 1.
    /// Clear glass (no colour) is the identity; opaque glass a constant colour.
    static func matrix(_ s: AeroColor.Spec) -> [Float] {
        var m = [Float](repeating: 0, count: 20)
        m[19] = 1
        guard let color = s.color else {
            m[0] = 1; m[6] = 1; m[12] = 1
            return m
        }
        let c = rgb(color)
        if !s.transparent {
            let o = opaque(c, intensity: s.intensity)
            for row in 0..<3 { m[row * 5 + 4] = Float(o[row]) }
            return m
        }
        let b = balances(s.intensity)
        let C = c.map(Float.init)
        let p = Float(b.primary / 100), a = Float(b.afterglow / 100), bl = Float(b.blur / 100)
        let luma: [Float] = [0.299, 0.587, 0.114]
        for row in 0..<3 {
            for col in 0..<3 { m[row * 5 + col] = C[row] * a * luma[col] + (row == col ? bl : 0) }
            m[row * 5 + 4] = C[row] * p
        }
        return m
    }

    /// BlurStrength 3 of AeroGlassBlur = dual Kawase, 2 iterations, offset 2.5 — about a
    /// Gaussian with σ ≈ 3.9 px (measured on the shader's impulse response).
    static let blurSigma: CGFloat = 3.9

    /// Radius of the Start menu dialog frame's rounded top corners (its outline runs from (6,0) to
    /// (0,6)); the glass must stay inside it so it doesn't show as a second corner.
    static let cornerRadius: CGFloat = 6

    /// Outline of a glass body: rounded top corners, square bottom (radius 0 = plain rectangle).
    static func bodyPath(_ r: NSRect, radius: CGFloat, topIsMinY: Bool) -> CGPath {
        guard radius > 0 else { return CGPath(rect: r, transform: nil) }
        let p = CGMutablePath()
        let top = topIsMinY ? r.minY : r.maxY, bottom = topIsMinY ? r.maxY : r.minY
        let inward: CGFloat = topIsMinY ? 1 : -1
        p.move(to: CGPoint(x: r.minX, y: bottom))
        p.addLine(to: CGPoint(x: r.minX, y: top + inward * radius))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: top), tangent2End: CGPoint(x: r.minX + radius, y: top), radius: radius)
        p.addLine(to: CGPoint(x: r.maxX - radius, y: top))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: top), tangent2End: CGPoint(x: r.maxX, y: top + inward * radius), radius: radius)
        p.addLine(to: CGPoint(x: r.maxX, y: bottom))
        p.closeSubpath()
        return p
    }
}

/// Behind-window glass like AeroGlassBlur: a window-server backdrop layer with the original's
/// light blur and the DWM colour matrix — none of the macOS material's darkening fill/tone layers.
/// Falls back to an NSVisualEffectView (plus the overlay approximation) if the backdrop layer
/// class is unavailable.
final class AeroBackdropView: NSView {
    private let backdrop: CALayer?
    private let fallback: NSVisualEffectView?
    private let shape = CAShapeLayer()
    /// Radius of the rounded top corners (0 = rectangle, e.g. the taskbar).
    var topRadius: CGFloat = AeroGlass.cornerRadius { didSet { needsLayout = true } }
    var usesFallback: Bool { backdrop == nil }

    init() {
        if let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type {
            let l = cls.init()
            l.setValue(true, forKey: "windowServerAware")
            backdrop = l; fallback = nil
        } else {
            let v = NSVisualEffectView()
            v.material = .underWindowBackground
            v.blendingMode = .behindWindow
            v.state = .active
            v.appearance = NSAppearance(named: .darkAqua)
            backdrop = nil; fallback = v
        }
        super.init(frame: .zero)
        wantsLayer = true
        if let b = backdrop {
            layer?.addSublayer(b)
            b.mask = shape
        } else if let v = fallback {
            addSubview(v)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `sigma` in points (0 = no blur), `spec` the window colour.
    func configure(sigma: CGFloat, spec: AeroColor.Spec, fallbackAlpha: CGFloat) {
        guard let b = backdrop else { fallback?.alphaValue = fallbackAlpha; return }
        var filters: [NSObject] = []
        if sigma > 0.05, let blur = Self.filter("gaussianBlur") {
            blur.setValue(sigma, forKey: "inputRadius")
            blur.setValue(true, forKey: "inputNormalizeEdges")
            filters.append(blur)
        }
        if let cm = Self.filter("colorMatrix") {
            let m = AeroGlass.matrix(spec)
            let value = m.withUnsafeBytes {
                NSValue(bytes: $0.baseAddress!, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
            }
            cm.setValue(value, forKey: "inputColorMatrix")
            filters.append(cm)
        }
        b.filters = filters
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        shape.frame = bounds
        let inset: CGFloat = topRadius > 0 ? 0.5 : 0
        shape.path = AeroGlass.bodyPath(bounds.insetBy(dx: inset, dy: inset), radius: topRadius, topIsMinY: isFlipped)
        CATransaction.commit()
        if let v = fallback {
            v.frame = bounds
            let r = topRadius
            v.maskImage = r <= 0 ? nil : NSImage(size: bounds.size, flipped: false) { rect in
                NSColor.black.setFill()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: rect.minX, y: rect.minY))
                p.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                p.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY), to: NSPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
                p.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.maxY - r), radius: r)
                p.close()
                p.fill()
                return true
            }
        }
    }

    private static func filter(_ type: String) -> NSObject? {
        guard let cls: AnyObject = NSClassFromString("CAFilter") else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel, with: type)?.takeUnretainedValue() as? NSObject
    }
}
