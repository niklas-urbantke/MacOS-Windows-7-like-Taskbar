import AppKit
import UniformTypeIdentifiers

/// The Aero-glass strip drawn over the blurred NSVisualEffectView. Also acts as a drop target:
/// dragging an app onto the bar pins it.
final class GlassBackgroundView: NSView {
    override var isFlipped: Bool { false }

    /// Called with the dropped file URLs (the controller filters to apps and pins them).
    var onDropFiles: (([URL]) -> Void)?
    private var dragActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Drag & drop (pin by dropping an app)

    private func hasApp(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { $0.pathExtension.lowercased() == "app" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasApp(sender) else { return [] }
        dragActive = true; needsDisplay = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasApp(sender) ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragActive = false; needsDisplay = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { dragActive = false; needsDisplay = true }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hasApp(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragActive = false; needsDisplay = true
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch Theme.taskbarStyle {
        case .vista: drawVista()
        case .win7:  drawWin7()
        case .win11: drawWin11()
        }

        // Highlight while an app is dragged over the bar.
        if dragActive {
            Theme.accent(brightness: 1.3, alpha: 0.22).setFill()
            bounds.fill()
            Theme.accent(brightness: 1.3, alpha: 0.9).setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
        }
    }

    /// Windows Vista profile: the original dark Aero strip, or bright Aero glass in light mode.
    private func drawVista() {
        guard Theme.isDark else { drawVistaLight(); return }
        let h = bounds.height

        let body = NSGradient(colors: [
            NSColor(calibratedWhite: 0.55, alpha: 0.11),
            NSColor(calibratedWhite: 0.22, alpha: 0.10),
            NSColor(calibratedWhite: 0.05, alpha: 0.16),
            NSColor(calibratedWhite: 0.02, alpha: 0.24),
        ], atLocations: [0.0, 0.42, 0.5, 1.0], colorSpace: .deviceRGB)
        body?.draw(in: bounds, angle: -90)

        let glossRect = NSRect(x: 0, y: h * 0.55, width: bounds.width, height: h * 0.45)
        NSGradient(colors: [
            NSColor(calibratedWhite: 1.0, alpha: 0.28),
            NSColor(calibratedWhite: 1.0, alpha: 0.02),
        ])?.draw(in: glossRect, angle: -90)

        // Bright top hairline.
        NSColor(calibratedWhite: 1.0, alpha: 0.45).setFill()
        NSRect(x: 0, y: h - 1, width: bounds.width, height: 1).fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.12).setFill()
        NSRect(x: 0, y: h - 2, width: bounds.width, height: 1).fill()
    }

    /// Light Vista glass: the same structure as the dark strip (bright upper half, the typical
    /// step at the middle, a slightly darker lower half), but milky white over the light frost.
    /// A dark outer line on top keeps the edge visible against bright windows.
    private func drawVistaLight() {
        let h = bounds.height

        let body = NSGradient(colors: [
            NSColor(calibratedWhite: 1.00, alpha: 0.62),
            NSColor(calibratedWhite: 1.00, alpha: 0.46),
            NSColor(calibratedWhite: 0.90, alpha: 0.40),
            NSColor(calibratedWhite: 0.84, alpha: 0.46),
        ], atLocations: [0.0, 0.48, 0.5, 1.0], colorSpace: .deviceRGB)
        body?.draw(in: bounds, angle: -90)

        let glossRect = NSRect(x: 0, y: h * 0.55, width: bounds.width, height: h * 0.45)
        NSGradient(colors: [
            NSColor(calibratedWhite: 1.0, alpha: 0.45),
            NSColor(calibratedWhite: 1.0, alpha: 0.05),
        ])?.draw(in: glossRect, angle: -90)

        // Dark outer edge, bright inner highlight below it.
        NSColor(calibratedWhite: 0.0, alpha: 0.26).setFill()
        NSRect(x: 0, y: h - 1, width: bounds.width, height: 1).fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.85).setFill()
        NSRect(x: 0, y: h - 2, width: bounds.width, height: 1).fill()
    }

    /// Windows 7 profile: draw the original taskbar texture stretched to fill the bar.
    /// Light mode: the texture plus a milky wash (`Theme.Aero.barWash`) below its two edge rows,
    /// so the original dark/bright top edge stays crisp, like Win7 with a light glass colour.
    private func drawWin7() {
        guard let tex = ThemeAssets.image("taskbarBackground") else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        // The view's alphaValue already applies `taskbarOpacity`, so draw the texture fully.
        tex.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
        guard !Theme.isDark else { return }

        // The texture is 39 px high; its top two rows are the edge (dark line, bright line).
        let edge = ceil(bounds.height * 2 / max(1, tex.size.height))
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - edge))
        Theme.Aero.barWash.setFill()
        body.fill(using: .sourceOver)
        // A faint gloss over the upper half, as the light Win7 glass reflects a little more.
        NSGradient(colors: [
            NSColor(calibratedWhite: 1.0, alpha: 0.22),
            NSColor(calibratedWhite: 1.0, alpha: 0.0),
        ])?.draw(in: NSRect(x: 0, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    }

    /// Windows 11 profile: flat (Acryl-)surface with a thin hairline on top, no gloss.
    /// The surface colour already carries the Acryl translucency; the blur sits underneath.
    private func drawWin11() {
        Theme.Win11.surface(.bar).setFill()
        bounds.fill(using: .sourceOver)
        Theme.Win11.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
    }
}
