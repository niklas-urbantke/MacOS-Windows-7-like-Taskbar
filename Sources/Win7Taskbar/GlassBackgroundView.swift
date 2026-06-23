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
        }

        // Highlight while an app is dragged over the bar.
        if dragActive {
            Theme.accent(brightness: 1.3, alpha: 0.22).setFill()
            bounds.fill()
            Theme.accent(brightness: 1.3, alpha: 0.9).setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
        }
    }

    /// Original dark Aero strip (Windows Vista profile).
    private func drawVista() {
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

    /// Windows 7 profile: draw the original taskbar texture stretched to fill the bar.
    private func drawWin7() {
        guard let tex = ThemeAssets.image("taskbarBackground") else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        // The view's alphaValue already applies `taskbarOpacity`, so draw the texture fully.
        tex.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}
