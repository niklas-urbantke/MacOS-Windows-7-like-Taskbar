import AppKit

/// Loads the original Windows 7 taskbar PNGs (bundled under Resources/theme/) for the
/// "Windows 7" style profile, so the taskbar matches the real thing 1:1.
enum ThemeAssets {
    private static var cache: [String: NSImage] = [:]

    /// The raw image for `<name>.png`, cached.
    static func image(_ name: String) -> NSImage? {
        if let c = cache[name] { return c }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "theme"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }

    /// A horizontally-stretchable copy: the left/right edges (rounded corners) stay fixed while the
    /// middle stretches. Top/bottom are NOT sliced — the vertical glass gradient scales smoothly and,
    /// crucially, no horizontal seam lines appear (which top/bottom caps would introduce).
    static func resizable(_ name: String, caps: CGFloat) -> NSImage? {
        let key = "\(name)#\(caps)"
        if let c = cache[key] { return c }
        guard let base = image(name), let copy = base.copy() as? NSImage else { return image(name) }
        copy.capInsets = NSEdgeInsets(top: 0, left: caps, bottom: 0, right: caps)
        copy.resizingMode = .stretch
        cache[key] = copy
        return copy
    }
}
