import AppKit

/// One colour tile of the window-colour picker, drawn like the Windows 7 swatches: a rounded glass
/// tile with a gloss on its upper half and a ring when selected.
final class AeroSwatch: NSView {
    enum Kind { case preset(AeroColor.Preset), custom, accent, none }

    let kind: Kind
    var selected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        switch kind {
        case .preset(let p): toolTip = p.name
        case .custom: toolTip = "Eigene Farbe…"
        case .accent: toolTip = "macOS-Akzentfarbe"
        case .none: toolTip = "Ohne Einfärbung (klares Glas)"
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private var fill: NSColor {
        switch kind {
        case .preset(let p): return AeroColor.color(p.rgb)
        case .custom: return AeroColor.customColor
        case .accent: return .controlAccentColor
        case .none: return NSColor(white: 0.97, alpha: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: tile, xRadius: 4, yRadius: 4)
        fill.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if case .none = kind {
            NSColor.systemRed.withAlphaComponent(0.8).setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: tile.minX, y: tile.minY))
            slash.line(to: NSPoint(x: tile.maxX, y: tile.maxY))
            slash.lineWidth = 2
            slash.stroke()
        }
        // Glass gloss over the upper half.
        NSGradient(colors: [NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0.08)])?
            .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let symbol: String? = {
            switch kind {
            case .custom: return "eyedropper"
            case .accent: return "apple.logo"
            default: return nil
            }
        }()
        if let name = symbol, let img = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                NSColor.white.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let s = tinted.size
            tinted.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2, width: s.width, height: s.height))
        }

        NSColor(white: 0, alpha: 0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        if selected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}

/// The swatch grid: the 16 Windows 7 colours in two rows, then custom colour, macOS accent colour
/// and "no colourisation".
final class AeroSwatchGrid: NSStackView {
    private(set) var swatches: [AeroSwatch] = []
    var onPick: ((AeroSwatch.Kind) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        let presets = AeroColor.presets.map { AeroSwatch(.preset($0)) }
        let extra = [AeroSwatch(.custom), AeroSwatch(.accent), AeroSwatch(.none)]
        swatches = presets + extra
        for row in [Array(presets[0..<8]), Array(presets[8..<16]), extra] {
            let r = NSStackView(views: row)
            r.orientation = .horizontal
            r.spacing = 2
            addArrangedSubview(r)
        }
        for s in swatches { s.onClick = { [weak self, weak s] in if let s { self?.onPick?(s.kind) } } }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Marks the tile of the current choice.
    func sync() {
        let mode = AeroColor.mode, presetID = AeroColor.preset.id
        for s in swatches {
            switch s.kind {
            case .preset(let p): s.selected = mode == .preset && p.id == presetID
            case .custom: s.selected = mode == .custom
            case .accent: s.selected = mode == .accent
            case .none: s.selected = mode == .none
            }
            s.needsDisplay = true   // custom/accent tiles show the current colours
        }
    }
}
