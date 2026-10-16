import AppKit
import Collaboration

// 1:1 rebuild of AeroThemePlasma's "SevenStart" menu (plasma/plasmoids/io.gitgud.wackyideas.SevenStart).
// Geometry follows MenuRepresentation.qml in its reference pixels (Kirigami: small 4, medium 6,
// large 8 spacing; icons 16/22/32/64) and is scaled by `k` = taskbar height / 40 — like Windows scales
// the menu together with the 40 px taskbar. The chrome comes from the original SVGs: every FrameSvg
// piece is rendered onto the pixel grid (1× and @2x, ThemeResources/sm-*) and drawn at native pixel
// size, so borders stay sharp; only the inner areas stretch. The glass follows the AeroGlassBlur
// effect (aeroshell-kwin-components, see AeroGlass.swift): uniform DWM colourisation in the window
// colour from the settings (default "Himmel"/Sky at intensity 107) plus the screen-space reflection
// texture at 75 % — no gradient.

// MARK: - Assets

enum Menu7Assets {
    private static var cache: [String: NSImage] = [:]

    /// A native-resolution asset: `name.png` (1×) plus `name@2x.png` when present; AppKit picks the
    /// representation matching the screen. `insets` (points) make it a stretchable 9-slice frame.
    static func native(_ name: String, insets: NSEdgeInsets? = nil) -> NSImage? {
        if let c = cache[name] { return c }
        guard let url1 = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "theme"),
              let rep1 = NSImageRep(contentsOf: url1) else { return nil }
        let size = NSSize(width: rep1.pixelsWide, height: rep1.pixelsHigh)
        rep1.size = size
        let img = NSImage(size: size)
        img.addRepresentation(rep1)
        if let url2 = Bundle.main.url(forResource: name + "@2x", withExtension: "png", subdirectory: "theme"),
           let rep2 = NSImageRep(contentsOf: url2) {
            rep2.size = size
            img.addRepresentation(rep2)
        }
        if let i = insets {
            img.capInsets = i
            img.resizingMode = .stretch
        }
        cache[name] = img
        return img
    }

    /// A stretchable frame at native pixel size (borders are never scaled, so they stay crisp).
    static func frame(_ name: String, _ t: CGFloat, _ l: CGFloat, _ b: CGFloat, _ r: CGFloat) -> NSImage? {
        native(name, insets: NSEdgeInsets(top: t, left: l, bottom: b, right: r))
    }

    /// Plain image (arrows, icons); its size is set by the rect it is drawn into.
    static func image(_ name: String) -> NSImage? { native(name) }

    static func draw(_ img: NSImage?, in rect: NSRect, alpha: CGFloat = 1) {
        guard let img else { return }
        let i = img.capInsets
        let sliced = i.top != 0 || i.left != 0 || i.bottom != 0 || i.right != 0
        guard sliced, NSGraphicsContext.current?.isFlipped == true else {
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            return
        }
        // AppKit ignores respectFlipped for images with cap insets (they would come out upside
        // down in a flipped view), so mirror the context around the rect instead.
        NSGraphicsContext.saveGraphicsState()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: rect.minY + rect.maxY)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Segoe UI, Windows 7's UI font (the original menu uses it at 12 px). It is not bundled (Microsoft
/// licence): it's used when installed on the system or placed in
/// `~/Library/Application Support/Win7Taskbar/fonts` (registered for this process only);
/// otherwise the system font is used.
enum Menu7Font {
    static let families = ["Segoe UI", "Segoe UI This"]

    static var userDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Win7Taskbar/fonts", isDirectory: true)
    }

    private static let family: String? = {
        let files = (try? FileManager.default.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)) ?? []
        for url in files where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return families.first { installed.contains($0) }
    }()

    static func font(size: CGFloat, italic: Bool = false) -> NSFont {
        if let fam = family {
            if let f = NSFontManager.shared.font(withFamily: fam, traits: italic ? .italicFontMask : [], weight: 5, size: size),
               !italic || f.fontDescriptor.symbolicTraits.contains(.italic) {
                return f
            }
            // No italic face installed (segoeuii.ttf): slant the regular one, like fontconfig does.
            if italic, let f = NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: size) {
                let slant = AffineTransform(m11: size, m12: 0, m21: size * 0.2, m22: size, tX: 0, tY: 0)
                return NSFont(descriptor: f.fontDescriptor, textTransform: slant) ?? f
            }
        }
        let f = NSFont.systemFont(ofSize: size)
        return italic ? NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) : f
    }
}

/// Shared helpers for the menu's views.
private enum M7 {
    static func font(_ k: CGFloat, _ size: CGFloat = 12, italic: Bool = false) -> NSFont {
        Menu7Font.font(size: size * k, italic: italic)
    }
    static func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255,
                blue: CGFloat(h & 0xff) / 255, alpha: a)
    }
    /// Draws a single line of text vertically centred in `rect` (with an optional offset).
    static func text(_ s: String, in rect: NSRect, font: NSFont, color: NSColor, dy: CGFloat = 0,
                     alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let h = ceil(str.size().height)
        str.draw(with: NSRect(x: rect.minX, y: (rect.midY - h / 2 + dy).rounded(), width: rect.width, height: h),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

class M7FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A view with a hover state (tracking area) that redraws on enter/exit.
class M7HoverView: M7FlippedView {
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true; onHover?(hovering) } } }
    var onHover: ((Bool) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

// MARK: - Chrome (glass, reflection, dialog frame, white left panel, search band)

private final class M7Chrome: M7FlippedView {
    var k: CGFloat = 1
    var leftRef: CGFloat = 254   // width of the left panel in reference px (grows when resized)
    var searching = false { didSet { needsDisplay = true } }
    var glass: NSColor = .clear { didSet { needsDisplay = true } }
    var reflection: CGFloat = 0.75   // ReflectionIntensity 75
    func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    /// The white left panel (background.svg). Spans the whole width while searching.
    var panelRect: NSRect {
        NSRect(x: r(7), y: r(7), width: searching ? bounds.width - 2 * r(7) : r(leftRef), height: bounds.height - 2 * r(7))
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        guard b.width > 40, b.height > 40 else { return }   // not laid out yet

        // Uniform Aero glass (no gradient). The colourisation normally lives in AeroBackdropView's colour
        // matrix; `glass` is only the overlay fallback.
        let shape = NSBezierPath(cgPath: AeroGlass.bodyPath(b.insetBy(dx: 0.5, dy: 0.5), radius: AeroGlass.cornerRadius, topIsMinY: true))
        glass.setFill()
        shape.fill()

        // Reflection streaks: the texture spans the whole screen (screen-space UVs) and shifts
        // horizontally with the window's distance to the screen centre (TranslateTexture).
        if reflection > 0, let tex = Menu7Assets.image("sm-reflection"), let win = window, let scr = win.screen {
            let mine = win.convertToScreen(convert(b, to: nil))
            let sf = scr.frame
            let ts = tex.size
            let dx = (sf.midX - mine.midX) / 10
            let src = NSRect(x: (mine.minX - sf.minX + dx) / sf.width * ts.width,
                             y: (mine.minY - sf.minY) / sf.height * ts.height,
                             width: mine.width / sf.width * ts.width,
                             height: mine.height / sf.height * ts.height)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            tex.draw(in: b, from: src, operation: .sourceOver, fraction: reflection, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Dialog frame (dialog.svgz), native pixels: rounded top, square bottom on the taskbar.
        Menu7Assets.draw(Menu7Assets.frame("sm-dialog", 6, 6, 6, 6), in: b)

        // White left panel (background.svg).
        let p = panelRect
        Menu7Assets.draw(Menu7Assets.frame("sm-leftpanel", 6, 6, 6, 6), in: p)

        // Search band at the bottom of the panel (#f1f5fb, radius 3) with its 4 px top border gradient.
        let rightInset: CGFloat = searching ? 3 : 2
        let band = NSRect(x: p.minX + 2, y: p.maxY - 2 - r(45), width: p.width - 2 - rightInset, height: r(45))
        M7.hex(0xf1f5fb).setFill()
        NSBezierPath(roundedRect: band, xRadius: 3, yRadius: 3).fill()
        NSGradient(starting: M7.hex(0xccd9ea), ending: M7.hex(0xf0f4fa))?
            .draw(in: NSRect(x: band.minX, y: band.minY, width: band.width, height: r(4)), angle: 90)

        // Separator above "Alle Programme" (13 px from the panel's left, largeSpacing+1 from its right).
        if !searching {
            M7.hex(0xd6e5f5).setFill()
            NSRect(x: r(20), y: b.height - r(85), width: r(leftRef - 22), height: 1).fill()
        }
    }
}

// MARK: - Left list rows

private final class M7AppRow: M7HoverView, StartMenuIconDisplaying {
    let title: String
    let k: CGFloat
    let small: Bool
    let indent: CGFloat
    var icon: NSImage?
    var onClick: (() -> Void)?
    var onContext: ((NSEvent) -> Void)?

    init(title: String, icon: NSImage?, small: Bool, indent: CGFloat = 0, k: CGFloat) {
        self.title = title; self.icon = icon; self.small = small; self.indent = indent; self.k = k
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    func updateIcon(_ img: NSImage?) { icon = img; needsDisplay = true }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onContext?(event) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            let m = small ? r(3) : r(4)   // smallSpacing/2+1 resp. smallSpacing
            Menu7Assets.draw(Menu7Assets.frame("sm-item-hover", 2, 2, 2, 2),
                             in: NSRect(x: m, y: 0, width: bounds.width - 2 * m, height: bounds.height))
        }
        let s = small ? r(16) : r(32)
        let ix = indent + (small ? r(5) : r(7))
        icon?.draw(in: NSRect(x: ix, y: ((bounds.height - s) / 2).rounded(), width: s, height: s),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let tx = ix + s + (small ? r(5) : r(8))
        M7.text(title, in: NSRect(x: tx, y: 0, width: bounds.width - tx - r(8), height: bounds.height),
                font: M7.font(k), color: .black)
    }
}

/// Search-result category heading ("Programme (3)") with the thin line after it.
private final class M7SectionHeader: M7FlippedView {
    let title: String
    let k: CGFloat
    init(title: String, k: CGFloat) { self.title = title; self.k = k; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r: (CGFloat) -> CGFloat = { ($0 * self.k).rounded() }
        let font = M7.font(k, 13)
        let w = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        M7.text(title, in: NSRect(x: r(8), y: 0, width: w + 2, height: bounds.height), font: font, color: M7.hex(0x1d3287))
        let lx = r(8) + w + r(7)
        M7.hex(0xe5e5e5).setFill()
        NSRect(x: lx, y: (bounds.height / 2).rounded() + 1, width: max(0, bounds.width - lx - r(9)), height: max(1, r(1))).fill()
    }
}

/// A 1 px separator inside the list (between pinned and recent programs).
private final class M7ListSeparator: M7FlippedView {
    override func draw(_ dirtyRect: NSRect) { M7.hex(0xd6e5f5).setFill(); bounds.fill() }
}

// MARK: - "Alle Programme" / "Zurück"

private final class M7AllProgramsRow: M7HoverView {
    var k: CGFloat = 1
    var back = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func draw(_ dirtyRect: NSRect) {
        let r: (CGFloat) -> CGFloat = { ($0 * self.k).rounded() }
        if hovering { Menu7Assets.draw(Menu7Assets.frame("sm-item-hover", 2, 2, 2, 2), in: bounds) }
        // The arrow element is stretched into a 16×16 box (iconSizes.small), as the KSvg.SvgItem does.
        let box = NSRect(x: r(4), y: ((bounds.height - r(16)) / 2).rounded() - r(1), width: r(16), height: r(16))
        Menu7Assets.draw(Menu7Assets.image(back ? "sm-arrow-allprog-left" : "sm-arrow-allprog-right"), in: box)
        M7.text("    " + (back ? "Zurück" : "Alle Programme"),
                in: NSRect(x: box.maxX + r(6), y: 0, width: bounds.width - box.maxX - r(6), height: bounds.height),
                font: M7.font(k), color: .black, dy: -r(1))
    }
}

// MARK: - Search box (lineedit.svg "base" frame, placeholder and gtk-search icon)

private final class M7SearchBox: M7FlippedView {
    var k: CGFloat = 1
    var empty = true { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let r: (CGFloat) -> CGFloat = { ($0 * self.k).rounded() }
        Menu7Assets.draw(Menu7Assets.frame("sm-search-base", 6, 6, 6, 6), in: bounds)
        guard empty else { return }
        M7.text(" Programme/Dateien durchsuchen",
                in: NSRect(x: r(7), y: 0, width: bounds.width - r(30), height: bounds.height),
                font: M7.font(k, italic: true), color: M7.hex(0x707070, 0.55), dy: -r(1))
        let s = r(16)
        Menu7Assets.image("sm-search-icon")?.draw(
            in: NSRect(x: bounds.width - r(5) - s, y: ((bounds.height - s) / 2).rounded() - r(0.5), width: s, height: s),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Borderless text field inside the search box. Keeps the I-beam on the whole field.
private final class M7SearchField: NSTextField {}

// MARK: - Right column

private final class M7SideRow: M7HoverView {
    let title: String
    let k: CGFloat
    var onClick: (() -> Void)?
    init(title: String, k: CGFloat) { self.title = title; self.k = k; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func draw(_ dirtyRect: NSRect) {
        let r: (CGFloat) -> CGFloat = { ($0 * self.k).rounded() }
        if hovering {
            Menu7Assets.draw(Menu7Assets.frame("sm-side-hover", 5, 5, 5, 5),
                             in: NSRect(x: 0, y: 0, width: bounds.width - r(1), height: bounds.height))
        }
        // Seven Black colour scheme: Window foreground 255,255,255 — no shadow.
        M7.text(title, in: NSRect(x: r(8), y: 0, width: bounds.width - r(16), height: bounds.height),
                font: M7.font(k), color: .white, dy: -r(1))
    }
}

/// sidebarseparator.svg "separator-line": an engraved 2 px line (group opacity 0.35) — a black line
/// over a white one (fill-opacity 0.49). Drawn directly so both stay exactly 1 px at any scale.
private final class M7SideSeparator: M7FlippedView {
    var k: CGFloat = 1
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSColor(calibratedWhite: 1, alpha: 0.49 * 0.35).setFill()
        NSRect(x: 0, y: 1, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Shut-down split button (startmenu-buttons.svg)

private final class M7PowerButton: M7HoverView {
    enum Part { case main, arrow }
    let part: Part
    var k: CGFloat = 1
    var lit = false { didSet { needsDisplay = true } }      // hover of either half lights both
    var pressed = false { didSet { needsDisplay = true } }
    var dark = false { didSet { needsDisplay = true } }      // on the white search panel
    var onClick: (() -> Void)?
    init(part: Part) { self.part = part; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    static let title = "Herunterfahren"
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let state = pressed ? "pressed" : (lit ? "hover" : "normal")
        let name = part == .main ? "sm-shut-\(state)" : "sm-shut-rtl-\(state)"
        Menu7Assets.draw(Menu7Assets.frame(name, 3, 3, 3, 3), in: bounds)
        switch part {
        case .main:
            M7.text(Self.title, in: bounds, font: M7.font(k), color: dark ? M7.hex(0x202020) : .white,
                    dy: -(k).rounded(), alignment: .center)
        case .arrow:
            // The arrow element is stretched into 20×21 (smallMedium − smallSpacing/2, +1), centred, −1 x.
            let w = (20 * k).rounded(), h = (21 * k).rounded()
            Menu7Assets.draw(Menu7Assets.image(dark ? "sm-arrow-more-black" : "sm-arrow-more-light"),
                             in: NSRect(x: ((bounds.width - w) / 2).rounded() - k.rounded(),
                                        y: ((bounds.height - h) / 2).rounded(), width: w, height: h))
        }
    }
}

// MARK: - Floating avatar (user.png frame + account picture; cross-fades to the hovered item's icon)

private final class M7Avatar: M7FlippedView {
    var k: CGFloat = 1 { didSet { photo.k = k; needsDisplay = true } }
    var onClick: (() -> Void)?
    private let photo = Photo()
    private let iconView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        photo.autoresizingMask = [.width, .height]
        iconView.autoresizingMask = [.width, .height]
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.alphaValue = 0
        addSubview(photo)
        addSubview(iconView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        photo.frame = bounds
        iconView.frame = bounds
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows `icon` instead of the framed picture (nil = back to the picture), cross-faded (350 ms).
    func show(icon: NSImage?) {
        if let icon { iconView.image = icon }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            iconView.animator().alphaValue = icon == nil ? 0 : 1
            photo.animator().alphaValue = icon == nil ? 1 : 0
        }
    }
    func resetIcon() { iconView.alphaValue = 0; photo.alphaValue = 1 }

    private final class Photo: M7FlippedView {
        var k: CGFloat = 1
        private static let accountImage: NSImage? = {
            guard let id = CBIdentity(name: NSUserName(), authority: CBIdentityAuthority.default()) else { return nil }
            return id.image
        }()
        override func draw(_ dirtyRect: NSRect) {
            let inset = (8 * k).rounded()   // smallSpacing*2
            let inner = bounds.insetBy(dx: inset, dy: inset)
            if !UserDefaults.standard.bool(forKey: "demoMode"), let img = Self.accountImage {
                img.draw(in: inner, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSColor(calibratedWhite: 0.93, alpha: 1).setFill(); inner.fill()
                let glyph = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: inner.height * 0.6, weight: .regular))
                if let glyph {
                    let gs = glyph.size
                    glyph.draw(in: NSRect(x: inner.midX - gs.width / 2, y: inner.midY - gs.height / 2,
                                          width: gs.width, height: gs.height),
                               from: .zero, operation: .sourceOver, fraction: 0.5, respectFlipped: true, hints: nil)
                }
            }
            // user.png is a 64 px BorderImage with 11 px borders.
            Menu7Assets.draw(Menu7Assets.frame("sm-user-frame", 11, 11, 11, 11), in: bounds)
        }
    }
}

// MARK: - Resize grip (top-right corner)

/// Invisible handle in the menu's top-right corner: drag it to enlarge the menu (wider left panel,
/// taller menu). Reports the screen-space delta since mouse-down (x to the right, y upwards).
private final class M7ResizeGrip: M7FlippedView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var start: NSPoint = .zero
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        if #available(macOS 15.0, *) {
            addCursorRect(bounds, cursor: NSCursor.frameResize(position: .topRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; onBegin?() }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        onDrag?(p.x - start.x, p.y - start.y)
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

// MARK: - All-programs tree

private enum M7Node {
    case app(AppEntry)
    case folder(String, [AppEntry])
}

// MARK: - Controller

/// Windows 7 Start menu, rebuilt 1:1 after AeroThemePlasma's SevenStart.
final class StartMenu7Controller: NSObject, NSTextFieldDelegate {
    var onVisibilityChanged: ((Bool) -> Void)?
    weak var taskbarController: TaskbarController?

    private let window: KeyableWindow
    private let root = M7FlippedView()
    private let body = M7FlippedView()
    private let blur = AeroBackdropView()
    private let chrome = M7Chrome()
    private let listScroll = NSScrollView()
    private let listDoc = M7FlippedView()
    private let allRow = M7AllProgramsRow()
    private let searchBox = M7SearchBox()
    private let searchField = M7SearchField()
    private let powerMain = M7PowerButton(part: .main)
    private let powerArrow = M7PowerButton(part: .arrow)
    private let avatar = M7Avatar()
    private var sideViews: [NSView] = []

    private enum Mode { case home, allPrograms, search }
    private var mode: Mode = .home
    private var allApps: [AppEntry] = []
    private var tree: [M7Node] = []
    private var expanded: Set<String> = []
    private var firstResult: AppEntry?
    private let fileSearch = StartMenuFileSearch()
    private var listY: CGFloat = 0
    private var avatarTimer: Timer?
    private var allProgramsTimer: Timer?
    private var powerTimer: Timer?

    // Geometry (points). `k` scales the QML reference pixels.
    private var k: CGFloat = 1
    private var W: CGFloat = 0
    private var H: CGFloat = 0
    private var overhang: CGFloat = 0
    private var colRef: CGFloat = 139
    // User resize (top-right corner): extra left-panel width and extra height in reference px.
    private var extraW = CGFloat(UserDefaults.standard.double(forKey: "startMenu7ExtraW"))
    private var extraH = CGFloat(UserDefaults.standard.double(forKey: "startMenu7ExtraH"))
    private var resizeStart: (w: CGFloat, h: CGFloat) = (0, 0)
    private let grip = M7ResizeGrip()
    /// Width of the white left panel in reference px (254 in the original, plus the user's resize).
    private var panelRef: CGFloat { 254 + extraW }
    private func r(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    override init() {
        window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false   // the macOS window shadow adds a dark 1 px outline around the menu
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.onCancel = { [weak self] in self?.escape() }
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(resignedKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(appUninstalled),
                                               name: AppUninstaller.didUninstallNotification, object: nil)
    }

    // MARK: Build (once)

    private func build() {
        window.contentView = root
        root.addSubview(body)

        body.addSubview(blur)
        body.addSubview(chrome)

        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .legacy
        listScroll.appearance = NSAppearance(named: .aqua)   // white panel: light scroller
        listScroll.documentView = listDoc
        listScroll.borderType = .noBorder
        body.addSubview(listScroll)

        allRow.onClick = { [weak self] in self?.toggleAllPrograms() }
        allRow.onHover = { [weak self] on in self?.allRowHover(on) }
        body.addSubview(allRow)

        body.addSubview(searchBox)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .black
        searchField.appearance = NSAppearance(named: .aqua)
        searchField.delegate = self
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        body.addSubview(searchField)

        powerMain.onClick = { [weak self] in StartMenuPower.run(.shutdown); self?.hide() }
        powerArrow.onClick = { [weak self] in self?.showPowerMenu() }
        for b in [powerMain, powerArrow] {
            b.onHover = { [weak self] _ in self?.powerHoverChanged() }
            body.addSubview(b)
        }

        grip.onBegin = { [weak self] in
            guard let self else { return }
            self.resizeStart = (self.extraW, self.extraH)
        }
        grip.onDrag = { [weak self] dx, dy in self?.resize(dx: dx, dy: dy) }
        grip.onEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.extraW), forKey: "startMenu7ExtraW")
            UserDefaults.standard.set(Double(self.extraH), forKey: "startMenu7ExtraH")
        }
        body.addSubview(grip)

        avatar.onClick = { [weak self] in
            MenuActionRunner.perform(MenuEntryStore.avatarAction()); self?.hide()
        }
        root.addSubview(avatar)
    }

    // MARK: Appearance

    /// Glass like AeroGlassBlur (BlurStrength 3) in the window colour from the settings (AeroColor,
    /// default "Himmel" at intensity 107). The classic menu's transparency sliders don't apply here.
    func applyAppearance() {
        let spec = AeroColor.current
        blur.configure(sigma: AeroGlass.blurSigma * k, spec: spec, fallbackAlpha: 1)
        chrome.glass = blur.usesFallback ? AeroGlass.overlay(spec) : .clear
        window.appearance = Theme.nsAppearance   // context menus follow the colour mode
    }

    // MARK: Layout

    private enum SideSpec { case item(String, MenuAction), separator }

    private func sideSpecs() -> [SideSpec] {
        var specs: [SideSpec] = [.item(displayUserName(), MenuAction(.home))]
        for e in MenuEntryStore.entries() {
            // Windows 7 has separator lines only — a plain gap (from the earlier variant) is dropped.
            if e.separatorBefore { specs.append(.separator) }
            specs.append(.item(e.title, e.action))
        }
        return specs
    }

    private func displayUserName() -> String {
        UserDefaults.standard.bool(forKey: "demoMode")
            ? "Max Mustermann"
            : (NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
    }

    private func homeEntries() -> (pinned: [AppEntry], recent: [AppEntry]) {
        let pinned = StartPins.entries()
        let ids = Set(pinned.compactMap { $0.bundleID })
        let recent = Array(RecentsStore.recent().filter { !ids.contains($0.bundleID ?? "") }.prefix(8))
        return (pinned, recent)
    }

    /// Computes the menu size like MenuRepresentation.qml (minimum 377 + margins) and places
    /// everything. Called on every show (item counts and the taskbar scale may have changed).
    private func layoutMenu(on screen: NSScreen) {
        k = max(1, Theme.barHeight / 40)
        let specs = sideSpecs()

        // Right column: at least 139, wide enough for the longest label (+ largeSpacing*2+1).
        let refFont = Menu7Font.font(size: 12)
        var widest: CGFloat = 0
        for case let .item(t, _) in specs {
            widest = max(widest, (t as NSString).size(withAttributes: [.font: refFont]).width)
        }
        colRef = max(139, ceil(widest) + 17)
        extraW = max(0, min(extraW, (screen.visibleFrame.width - 16) / k - (colRef + 272)))
        let wRef = colRef + 272 + extraW   // panel + mediumSpacing + column + 2·mediumSpacing

        let home = homeEntries()
        let listRef = CGFloat(home.pinned.count + home.recent.count) * 36
            + ((home.pinned.isEmpty || home.recent.isEmpty) ? 0 : 5)
        var sideRef: CGFloat = 0
        for s in specs {
            switch s { case .item: sideRef += 35; case .separator: sideRef += 5 }
        }
        let sidePanelRef = 4 + 45 + sideRef + 36
        let maxH = (screen.visibleFrame.height - 8) / k - 28
        let baseH = max(listRef + 84, sidePanelRef, 377) + 14
        extraH = max(0, min(extraH, maxH - baseH))
        let hRef = min(baseH + extraH, maxH)

        W = r(wRef); H = r(hRef); overhang = r(28)
        // The rows are placed with rounded heights (r(36) each), so the list can be a few pixels
        // taller than listRef·k — make sure the list area (top r(11), bottom r(87)) holds it.
        let both = !home.pinned.isEmpty && !home.recent.isEmpty
        let listPx = CGFloat(home.pinned.count + home.recent.count) * r(36) + (both ? 2 * r(2) + max(1, r(1)) : 0)
        H = min(max(H, listPx + r(11) + r(87)), r(maxH))
        window.setContentSize(NSSize(width: W, height: H + overhang))
        root.frame = NSRect(x: 0, y: 0, width: W, height: H + overhang)
        body.frame = NSRect(x: 0, y: overhang, width: W, height: H)
        blur.frame = body.bounds
        chrome.frame = body.bounds
        chrome.k = k
        chrome.leftRef = panelRef
        grip.frame = NSRect(x: W - r(16), y: 0, width: r(16), height: r(16))

        allRow.k = k
        allRow.frame = NSRect(x: r(11), y: H - r(81), width: r(panelRef - 8), height: r(23))

        searchBox.k = k
        searchBox.frame = NSRect(x: r(20), y: H - r(43), width: r(panelRef - 30), height: r(24))
        searchField.font = M7.font(k)
        let fh = ceil(searchField.font!.boundingRectForFont.height) + 2
        searchField.frame = NSRect(x: searchBox.frame.minX + r(7), y: (searchBox.frame.midY - fh / 2).rounded() - r(1),
                                   width: searchBox.frame.width - r(14), height: fh)

        // Shut-down split button: 22 high, text + 2·(largeSpacing−1)+1 wide; arrow height+1 wide.
        powerMain.k = k; powerArrow.k = k
        let tw = ceil((StartMenuPowerTitle.shutDown as NSString).size(withAttributes: [.font: M7.font(k)]).width)
        let bh = r(22)
        let bx = r(panelRef + 13)
        powerMain.frame = NSRect(x: bx, y: H - r(20) - bh, width: tw + r(15), height: bh)
        powerArrow.frame = NSRect(x: powerMain.frame.maxX - r(1), y: powerMain.frame.minY, width: bh + r(1), height: bh)

        layoutSideColumn(specs)

        // Avatar: 64 px, half above the top edge, centred over the right column.
        avatar.k = k
        let s = r(64)
        avatar.frame = NSRect(x: r(panelRef + 12) + r(colRef) / 2 - s / 2 + r(1), y: 0, width: s, height: s)
        avatar.resetIcon()
    }

    private func layoutSideColumn(_ specs: [SideSpec]) {
        sideViews.forEach { $0.removeFromSuperview() }
        sideViews = []
        let x = r(panelRef + 12), w = r(colRef)
        var y = r(44)   // huge/2 + 2·mediumSpacing
        for spec in specs {
            switch spec {
            case .item(let title, let action):
                let row = M7SideRow(title: title, k: k)
                row.frame = NSRect(x: x, y: y, width: w, height: r(33))
                row.onClick = { [weak self] in MenuActionRunner.perform(action); self?.hide() }
                row.onHover = { [weak self] on in self?.sideHover(on ? action : nil) }
                body.addSubview(row)
                sideViews.append(row)
                y += r(35)
            case .separator:
                let sep = M7SideSeparator()
                sep.k = k
                sep.frame = NSRect(x: x + (w - r(124)) / 2, y: y + r(1), width: r(124), height: r(2))
                body.addSubview(sep)
                sideViews.append(sep)
                y += r(5)
            }
        }
    }

    // MARK: Modes

    private func setMode(_ m: Mode) {
        mode = m
        applyModeFrames()
        reloadList()
    }

    /// Visibility and list placement for the current mode (no list rebuild — used while resizing).
    private func applyModeFrames() {
        let m = mode
        let searching = m == .search
        chrome.searching = searching
        allRow.isHidden = searching
        allRow.back = m == .allPrograms
        for v in sideViews { v.isHidden = searching }
        avatar.isHidden = searching
        powerMain.dark = searching
        powerArrow.dark = searching

        switch m {
        case .home:        listScroll.frame = NSRect(x: r(7), y: r(11), width: r(panelRef), height: H - r(87) - r(11))
        case .allPrograms: listScroll.frame = NSRect(x: r(7), y: r(3), width: r(panelRef), height: H - r(87) - r(3))
        case .search:      listScroll.frame = NSRect(x: r(8), y: r(13), width: W - r(14), height: H - r(67))
        }
        listScroll.hasVerticalScroller = m != .home
        listDoc.frame.size.width = listScroll.contentSize.width   // rows follow (autoresizing)
    }

    /// Live resize from the corner grip: the bottom-left stays on the taskbar.
    private func resize(dx: CGFloat, dy: CGFloat) {
        guard let screen = window.screen else { return }
        extraW = max(0, resizeStart.w + dx / k)
        extraH = max(0, resizeStart.h + dy / k)
        let origin = window.frame.origin
        layoutMenu(on: screen)
        applyModeFrames()
        window.setFrameOrigin(origin)
        chrome.needsDisplay = true
    }

    private func toggleAllPrograms() {
        allProgramsTimer?.invalidate()
        switch mode {
        case .home:        expanded = []; setMode(.allPrograms)
        case .allPrograms: setMode(.home)
        case .search:      searchField.stringValue = ""; searchBox.empty = true; setMode(.home)
        }
        fadeList()
    }

    /// Hovering "Alle Programme" for 800 ms opens the program list (Windows behaviour).
    private func allRowHover(_ on: Bool) {
        allProgramsTimer?.invalidate()
        guard on, mode == .home else { return }
        allProgramsTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            guard let self, self.mode == .home, self.allRow.hovering else { return }
            self.toggleAllPrograms()
        }
    }

    private func fadeList() {
        listScroll.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            listScroll.animator().alphaValue = 1
        }
    }

    private func escape() {
        if mode == .search { searchField.stringValue = ""; searchBox.empty = true; setMode(.home) }
        else if mode == .allPrograms { setMode(.home); fadeList() }
        else { hide() }
    }

    // MARK: Left list

    private func resetList() {
        listDoc.subviews.forEach { $0.removeFromSuperview() }
        listY = 0
    }

    private func append(_ v: NSView, height: CGFloat, x: CGFloat = 0, width: CGFloat? = nil) {
        let w = listScroll.contentSize.width
        v.frame = NSRect(x: x, y: listY, width: width ?? (w - x), height: height)
        v.autoresizingMask = [.width]
        listDoc.addSubview(v)
        listY += height
        listDoc.frame = NSRect(x: 0, y: 0, width: w, height: max(listY, listScroll.contentSize.height))
    }

    private func appRow(_ e: AppEntry, small: Bool, indent: CGFloat = 0, file: Bool = false,
                        pending: inout [(StartMenuIconDisplaying, String)]) -> M7AppRow {
        let row = M7AppRow(title: e.name, icon: StartMenuIcons.cached(e.url.path), small: small, indent: indent, k: k)
        if row.icon == nil { pending.append((row, e.url.path)) }
        row.onClick = { [weak self] in
            if file { StartMenuLaunch.open(e, isFile: true) } else { StartMenuLaunch.launch(e) }
            self?.hide()
        }
        row.onContext = { [weak self, weak row] event in
            guard let self, let row else { return }
            let pinned = StartPins.isPinned(e.bundleID)
            let menu = StartMenuContextMenu.make(
                for: e, pinned: file ? false : pinned,
                onTogglePin: { [weak self] in StartPins.toggle(e.bundleID); self?.relayoutKeepingMode() },
                onPinTaskbar: file ? nil : { [weak self] in
                    self?.taskbarController?.pinToTaskbar(bundleID: e.bundleID); self?.hide()
                })
            NSMenu.popUpContextMenu(menu, with: event, for: row)
        }
        return row
    }

    private func reloadList() {
        resetList()
        var pending: [(StartMenuIconDisplaying, String)] = []
        let y0 = listScroll.contentView.bounds.origin
        switch mode {
        case .home:
            let home = homeEntries()
            firstResult = (home.pinned + home.recent).first
            for e in home.pinned { append(appRow(e, small: false, pending: &pending), height: r(36)) }
            if !home.pinned.isEmpty && !home.recent.isEmpty {
                listY += r(2)
                append(M7ListSeparator(), height: max(1, r(1)), x: r(11), width: r(panelRef - 18))
                listY += r(2)
            }
            for e in home.recent { append(appRow(e, small: false, pending: &pending), height: r(36)) }

        case .allPrograms:
            firstResult = nil
            listY = r(8)   // the list starts largeSpacing above the program area
            for node in tree {
                switch node {
                case .app(let e):
                    append(appRow(e, small: true, pending: &pending), height: r(20))
                case .folder(let name, let apps):
                    let folder = M7AppRow(title: name, icon: Menu7Assets.image("sm-folder"),
                                          small: true, k: k)
                    folder.onClick = { [weak self] in self?.toggleFolder(name) }
                    append(folder, height: r(20))
                    if expanded.contains(name) {
                        for e in apps { append(appRow(e, small: true, indent: r(16), pending: &pending), height: r(20)) }
                    }
                }
            }
            listScroll.contentView.scroll(to: y0)

        case .search:
            let needle = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            let lower = needle.lowercased()
            let apps = allApps.filter { $0.name.lowercased().contains(lower) }
            firstResult = apps.first
            if !apps.isEmpty {
                append(M7SectionHeader(title: "Programme (\(apps.count))", k: k), height: r(31))
                for e in apps.prefix(60) { append(appRow(e, small: true, pending: &pending), height: r(20)) }
            }
            if needle.count >= 2 {
                fileSearch.search(needle, isCurrent: { [weak self] q in
                    self?.searchField.stringValue.trimmingCharacters(in: .whitespaces) == q
                }, completion: { [weak self] files in
                    self?.appendFiles(files)
                })
            }
        }
        StartMenuIcons.load(pending)
    }

    private func appendFiles(_ files: [AppEntry]) {
        guard mode == .search, !files.isEmpty else { return }
        var pending: [(StartMenuIconDisplaying, String)] = []
        append(M7SectionHeader(title: "Dateien (\(files.count))", k: k), height: r(31))
        for e in files { append(appRow(e, small: true, file: true, pending: &pending), height: r(20)) }
        StartMenuIcons.load(pending)
    }

    private func toggleFolder(_ name: String) {
        if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
        reloadList()
    }

    private func relayoutKeepingMode() {
        guard let screen = window.screen else { reloadList(); return }
        let m = mode
        layoutMenu(on: screen)
        setMode(m)
    }

    /// Windows-style "Alle Programme": programs first (alphabetical), then folders — "Dienstprogramme"
    /// and program folders inside /Applications (e.g. "Microsoft Office").
    private static func buildTree(_ apps: [AppEntry]) -> [M7Node] {
        let utilityDirs: Set<String> = ["/Applications/Utilities", "/System/Applications/Utilities"]
        var rootApps: [AppEntry] = []
        var utilities: [AppEntry] = []
        for a in apps {
            if utilityDirs.contains(a.url.deletingLastPathComponent().path) { utilities.append(a) } else { rootApps.append(a) }
        }
        var folders: [(String, [AppEntry])] = []
        if !utilities.isEmpty { folders.append(("Dienstprogramme", utilities)) }

        let fm = FileManager.default
        for base in ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")] {
            guard let items = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for item in items where !item.hasSuffix(".app") && !item.hasPrefix(".") && item != "Utilities" {
                let dir = (base as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                      let inner = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                let found = inner.filter { $0.hasSuffix(".app") }.map { name -> AppEntry in
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                    return AppEntry(name: (name as NSString).deletingPathExtension, url: url,
                                    bundleID: Bundle(url: url)?.bundleIdentifier)
                }
                if !found.isEmpty {
                    folders.append((item, found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }))
                }
            }
        }
        folders.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        return rootApps.map { .app($0) } + folders.map { .folder($0.0, $0.1) }
    }

    // MARK: Right column hover → avatar icon (after 250 ms, like the original's delayTimer)

    private func sideHover(_ action: MenuAction?) {
        avatarTimer?.invalidate()
        avatarTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self else { return }
            let anyHovered = self.sideViews.contains { ($0 as? M7SideRow)?.hovering == true }
            if let action, anyHovered { self.avatar.show(icon: MenuActionRunner.icon(for: action)) }
            else if !anyHovered { self.avatar.show(icon: nil) }
        }
    }

    // MARK: Power

    private func powerHoverChanged() {
        let lit = powerMain.hovering || powerArrow.hovering
        powerMain.lit = lit
        powerArrow.lit = lit
        powerTimer?.invalidate()
        if powerArrow.hovering {   // hovering the arrow for 700 ms opens the menu
            powerTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
                guard let self, self.powerArrow.hovering else { return }
                self.showPowerMenu()
            }
        }
    }

    private func showPowerMenu() {
        powerTimer?.invalidate()
        let menu = NSMenu()
        func add(_ title: String, _ action: MenuAction) {
            menu.addItem(ClosureMenuItem(title) { [weak self] in self?.hide(); MenuActionRunner.perform(action) })
        }
        add("Sperren", MenuAction(.lock))
        add("Abmelden", MenuAction(.logout))
        menu.addItem(.separator())
        add("Energie sparen", MenuAction(.sleep))
        menu.addItem(.separator())
        add("Neu starten", MenuAction(.restart))
        // Opens to the right of the arrow, bottom-aligned with the button (RightPosedBottomAlignedPopup).
        let b = powerArrow.bounds
        menu.popUp(positioning: nil, at: NSPoint(x: b.maxX, y: b.maxY - menu.size.height), in: powerArrow)
    }

    // MARK: Show / hide

    func toggle(relativeTo orbScreenRect: NSRect, on screen: NSScreen) {
        if window.isVisible { hide() } else { show(relativeTo: orbScreenRect, on: screen) }
    }

    func show(relativeTo orbScreenRect: NSRect, on screen: NSScreen) {
        allApps = AppScanner.installedApps()
        tree = Self.buildTree(allApps)
        expanded = []
        searchField.stringValue = ""
        searchBox.empty = true
        layoutMenu(on: screen)
        applyAppearance()   // after layout: the blur radius scales with k
        setMode(.home)

        // Bottom edge on the taskbar, left edge at the orb (clamped to the screen).
        var x = max(screen.frame.minX, orbScreenRect.minX)
        x = min(x, screen.visibleFrame.maxX - W)
        window.setFrameOrigin(NSPoint(x: x, y: orbScreenRect.maxY + 1))

        NSApp.activate()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.alphaValue = reduce ? 1 : 0
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        if !reduce {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 1
            }
        }
        onVisibilityChanged?(true)
    }

    func hide() {
        guard window.isVisible else { return }
        avatarTimer?.invalidate(); allProgramsTimer?.invalidate(); powerTimer?.invalidate()
        onVisibilityChanged?(false)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { window.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window.orderOut(nil)
            self?.window.alphaValue = 1
        })
    }

    /// Right-column entries changed in the editor: rebuilt on the next show (sizes depend on them).
    func reloadRightColumn() {
        if window.isVisible, let screen = window.screen { layoutMenu(on: screen); setMode(mode) }
    }

    @objc private func resignedKey() { hide() }

    @objc private func appUninstalled() {
        allApps = AppScanner.installedApps()
        tree = Self.buildTree(allApps)
        if window.isVisible { reloadList() }
    }

    // MARK: Search field

    func controlTextDidChange(_ obj: Notification) {
        let empty = searchField.stringValue.isEmpty
        searchBox.empty = empty
        if empty { setMode(.home) } else { setMode(.search) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), let e = firstResult {
            StartMenuLaunch.launch(e); hide()
            return true
        }
        return false
    }
}

/// Labels shared with the power button (kept in one place for the width calculation).
private enum StartMenuPowerTitle {
    static let shutDown = M7PowerButton.title
}

// MARK: - Common interface of the two Vista/Windows-7 Start menus

/// The 1:1 SevenStart rebuild and the earlier variant behind one interface (chosen in the settings).
protocol ClassicStartMenu: AnyObject {
    var onVisibilityChanged: ((Bool) -> Void)? { get set }
    var taskbarController: TaskbarController? { get set }
    func toggle(relativeTo orbScreenRect: NSRect, on screen: NSScreen)
    func hide()
    func applyAppearance()
    func reloadRightColumn()
}

extension StartMenuController: ClassicStartMenu {}
extension StartMenu7Controller: ClassicStartMenu {}
