import AppKit

// Tray elements of the Windows 11 profile. All views draw with the Theme.Win11 palette (colours
// are read at draw time, the colour mode can change at any moment) and handle their own clicks.
// The taskbar places them in the bar (full bar height) and calls `refresh()` from the bar timer.

// MARK: - Shared helpers (also used by Win11Flyouts.swift)

/// Last known now-playing state, shared between compact tray view and the media flyout.
enum Win11NowPlayingCache {
    static var info: NowPlaying.Info?
    static var artwork: NSImage?
    static var artworkKey: String?
}

extension NowPlaying.Info {
    /// Copy with the playback state flipped (optimistic play/pause).
    func togglingPlayback() -> NowPlaying.Info {
        var t = NowPlaying.Info(app: app, title: title, artist: artist, playing: !playing, fraction: fraction)
        t.album = album
        t.position = position
        t.duration = duration
        t.artworkURL = artworkURL
        t.bundleID = bundleID
        return t
    }
}

/// Die Quell-App einer Wiedergabe (beliebiger Player: Spotify, Musik, TIDAL, Browser …).
/// Aufgelöst über `Info.bundleID`, ersatzweise über den App-Namen unter den laufenden Apps.
enum Win11MediaApp {
    struct Resolved {
        let name: String
        let icon: NSImage?
        let bundleID: String?
        let url: URL?
    }

    private static var cache: [String: Resolved] = [:]

    static func resolve(_ info: NowPlaying.Info) -> Resolved {
        let key = info.bundleID.isEmpty ? "name:" + info.app : info.bundleID
        if let r = cache[key] { return r }
        let r = lookup(info)
        // Only cache hits: an app that is not found yet (e.g. still launching) is retried later.
        if r.url != nil || r.icon != nil {
            if cache.count > 30 { cache.removeAll() }
            cache[key] = r
        }
        return r
    }

    private static func lookup(_ info: NowPlaying.Info) -> Resolved {
        let fallbackName = info.app == "Music" ? "Musik" : info.app
        var bundleID: String? = info.bundleID.isEmpty ? nil : info.bundleID
        var running: NSRunningApplication?
        if let id = bundleID {
            running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        } else if !info.app.isEmpty {
            // No bundle ID: match the name against the running apps (localized or bundle name).
            running = NSWorkspace.shared.runningApplications.first { app in
                app.localizedName == info.app || app.localizedName == fallbackName
                    || app.bundleURL?.deletingPathExtension().lastPathComponent == info.app
            }
            bundleID = running?.bundleIdentifier
        }
        let url = running?.bundleURL ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }

        var name = running?.localizedName
        if name == nil, let url, let b = Bundle(url: url) {
            name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
        }
        if name == nil, let url { name = FileManager.default.displayName(atPath: url.path) }
        if let n = name, n.hasSuffix(".app") { name = String(n.dropLast(4)) }
        if name?.isEmpty ?? true { name = fallbackName }

        let icon = running?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        return Resolved(name: name ?? fallbackName, icon: icon, bundleID: bundleID, url: url)
    }

    /// Brings the player to the front (per bundle ID), launching it if it is not running.
    static func activate(_ info: NowPlaying.Info) {
        let r = resolve(info)
        if let id = r.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            if app.isHidden { app.unhide() }
            app.activate(options: [.activateAllWindows])
            return
        }
        guard let url = r.url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
}

enum Win11TrayDraw {
    /// Damped scale for tray text and small controls: with a big bar (icons in Dock size,
    /// k = 1.5) the tray text would otherwise grow to 18 pt. Half of the growth is enough.
    static var tk: CGFloat { 1 + (Theme.Win11.k - 1) * 0.5 }
    static func t(_ base: CGFloat) -> CGFloat { (base * tk).rounded() }
    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size * tk, weight: weight)
    }
    static func digitFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size * tk, weight: weight)
    }

    /// First available SF symbol of `names`, tinted with `color`.
    static func symbol(_ names: [String], pointSize: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        for name in names {
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { continue }
            // Colour first, then the glyph as alpha mask: keeps the colour's own alpha
            // (textSecondary etc. are translucent), unlike a sourceAtop tint.
            return NSImage(size: base.size, flipped: false) { rect in
                color.setFill()
                rect.fill()
                base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }
        }
        return nil
    }

    /// Draws `image` pixel-aligned in the centre of `r` (works in flipped views too).
    static func draw(_ image: NSImage, centeredIn r: NSRect) {
        let s = image.size
        let rect = NSRect(x: (r.midX - s.width / 2).rounded(), y: (r.midY - s.height / 2).rounded(),
                          width: s.width, height: s.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func fill(_ rect: NSRect, radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// Hover field of a tray element: horizontally `rect`, vertically a bit shorter than the bar
    /// (Win11 hover fields have the height of a taskbar slot).
    static func hoverRect(_ rect: NSRect, in bounds: NSRect) -> NSRect {
        let dy = max(Theme.Win11.s(4), ((bounds.height - Theme.Win11.slotHeight) / 2).rounded())
        return NSRect(x: rect.minX, y: bounds.minY + dy, width: rect.width, height: max(0, bounds.height - 2 * dy))
    }

    static func text(_ s: String, font: NSFont, color: NSColor,
                     alignment: NSTextAlignment = .left) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    /// Draws a cover aspect-filled into a rounded rect.
    static func drawCover(_ image: NSImage, in rect: NSRect, radius: CGFloat) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        let scale = max(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Cover placeholder: `music.note` on a subtle control fill.
    static func drawCoverPlaceholder(in rect: NSRect, radius: CGFloat, glyphSize: CGFloat) {
        fill(rect, radius: radius, Theme.Win11.controlFill)
        Theme.Win11.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
        border.lineWidth = 1
        border.stroke()
        if let note = symbol(["music.note"], pointSize: glyphSize, color: Theme.Win11.textSecondary) {
            draw(note, centeredIn: rect)
        }
    }

    /// `rect` (in `view` coordinates) in screen coordinates.
    static func screenRect(of view: NSView, _ rect: NSRect) -> NSRect? {
        guard let w = view.window else { return nil }
        return w.convertToScreen(view.convert(rect, to: nil))
    }

    static func screen(of view: NSView) -> NSScreen? { view.window?.screen ?? NSScreen.main }
}

// MARK: - Base: hover / press handling

/// Base class for the tray views: tracks hover and press, reports a click (mouse up inside).
class Win11TrayControl: NSView {
    private(set) var hovering = false
    private(set) var pressed = false
    /// Current mouse position in view coordinates while hovering (or dragging).
    private(set) var mousePoint: NSPoint?
    private var pressPoint: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    // The bar is a non-activating panel: the first click must act right away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }

    override func mouseEntered(with event: NSEvent) { hovering = true; mousePoint = point(event); needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { mousePoint = point(event); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; mousePoint = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        pressPoint = point(event)
        mousePoint = pressPoint
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { mousePoint = point(event); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        let wasPressed = pressed
        pressed = false
        if !bounds.contains(p) { hovering = false; mousePoint = nil }
        needsDisplay = true
        if wasPressed && bounds.contains(p) { clicked(at: pressPoint) }
    }

    /// Override: a click landed at `point` (the mouse-down location).
    func clicked(at point: NSPoint) {}

    /// Fill for the hover field of `region`: pressed while the press started (and stays) in it,
    /// hover while the mouse is in it, otherwise nil.
    func highlight(for region: NSRect) -> NSColor? {
        guard let m = mousePoint, region.contains(m) else { return nil }
        if pressed { return region.contains(pressPoint) ? Theme.Win11.pressedFill : nil }
        return hovering ? Theme.Win11.hoverFill : nil
    }
}

/// Small glyph button with hover / pressed field (used in the tray and in the flyouts). Draws via
/// `FlyoutLook`: Win11 flat fill, or Aero glass when the media flyout is open in Vista / Windows 7.
final class Win11GlyphButton: NSView {
    var symbol: String { didSet { if symbol != oldValue { needsDisplay = true } } }
    var pointSize: CGFloat = 12 { didSet { if pointSize != oldValue { needsDisplay = true } } }
    var weight: NSFont.Weight = .regular
    var cornerRadius: CGFloat = 4
    /// Round hover field instead of a rounded rect.
    var circular = false
    var isEnabled = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovering = false
    private var pressed = false

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        hovering = bounds.contains(convert(event.locationInWindow, from: nil)); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let fire = pressed && inside
        pressed = false
        hovering = inside
        needsDisplay = true
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let L = FlyoutLook.self
        if isEnabled && hovering {
            let r = circular ? min(bounds.width, bounds.height) / 2 : cornerRadius
            let rect = circular
                ? NSRect(x: bounds.midX - r, y: bounds.midY - r, width: 2 * r, height: 2 * r)
                : bounds
            L.drawHover(rect, radius: r, pressed: pressed)
        }
        let color = !isEnabled ? L.textDisabled : (pressed ? L.textSecondary : L.textPrimary)
        if let img = Win11TrayDraw.symbol([symbol], pointSize: pointSize, weight: weight, color: color) {
            Win11TrayDraw.draw(img, centeredIn: bounds)
        }
    }
}

// MARK: - Clock

/// Zweizeilige Uhr (Uhrzeit oben, Datum unten, rechtsbündig). Klick → Win11Flyouts.showCalendar.
/// Mit `Theme.clockShowsSeconds` zeigt sie „HH:mm:ss“ und tickt dann auf die volle Sekunde genau.
final class Win11ClockButton: Win11TrayControl {
    var preferredWidth: CGFloat { Theme.Win11.clockWidth }
    /// Nur auf dem Hauptbildschirm öffnet ein Klick den Kalender; sonst weder Klick noch Hover-Feld.
    var opensCalendar = true { didSet { needsDisplay = true } }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "HH:mm"; return f
    }()
    private static let secondsFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "dd.MM.yyyy"; return f
    }()
    private static let tipFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateStyle = .full; f.timeStyle = .none; return f
    }()
    private var time = ""
    private var date = ""
    /// Own timer aligned to whole seconds: the bar timer runs at an arbitrary phase, which makes a
    /// seconds display visibly skip or stall.
    private var tickTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tickTimer?.invalidate()
        tickTimer = nil
        guard window != nil else { return }
        let next = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate) + 1.02)
        let t = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
        refresh()
    }

    func refresh() {
        let now = Date()
        let t = (Theme.clockShowsSeconds ? Self.secondsFormatter : Self.timeFormatter).string(from: now)
        let d = Self.dateFormatter.string(from: now)
        let tip = Self.tipFormatter.string(from: now)
        if toolTip != tip { toolTip = tip }
        time = t
        date = d
        needsDisplay = true   // also picks up colour-mode changes
    }

    override func clicked(at point: NSPoint) {
        guard opensCalendar,
              let anchor = Win11TrayDraw.screenRect(of: self, bounds),
              let screen = Win11TrayDraw.screen(of: self) else { return }
        Win11Flyouts.showCalendar(anchor: anchor, screen: screen)
    }

    /// Right padding inside the hover field (the text is right-aligned).
    private var rightPad: CGFloat { Theme.Win11.s(10) }

    /// 12 pt (scaled), shrunk if time or date would not fit the width. Tabular digits keep the
    /// right-aligned time from jittering while the seconds change.
    private func fittingFont() -> NSFont {
        let W = Theme.Win11.self
        let avail = bounds.width - rightPad - W.s(6)
        var size = 12 * Win11TrayDraw.tk
        while size > 9 {
            let f = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            let widest = [time, date].map { ($0 as NSString).size(withAttributes: [.font: f]).width }.max() ?? 0
            if ceil(widest) <= avail { return f }
            size -= 0.5
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        let W = Theme.Win11.self
        let field = Win11TrayDraw.hoverRect(bounds.insetBy(dx: W.s(2), dy: 0), in: bounds)
        if opensCalendar, let c = highlight(for: bounds) { Win11TrayDraw.fill(field, radius: W.buttonRadius, c) }

        let font = fittingFont()
        let timeStr = Win11TrayDraw.text(time, font: font, color: W.textPrimary, alignment: .right)
        let dateStr = Win11TrayDraw.text(date, font: font, color: W.textPrimary, alignment: .right)
        let th = ceil(timeStr.size().height), dh = ceil(dateStr.size().height)
        let gap = W.s(1)
        let y0 = ((bounds.height - th - dh - gap) / 2).rounded()
        let w = bounds.width - rightPad
        dateStr.draw(in: NSRect(x: 0, y: y0, width: w, height: dh))
        timeStr.draw(in: NSRect(x: 0, y: y0 + dh + gap, width: w, height: th))
    }
}

// MARK: - Now playing (compact)

/// Kompakte Medienanzeige (Cover, Titel/Interpret, Steuerung). Klick auf Cover/Titel →
/// Win11Flyouts.showMedia.
final class Win11MediaView: Win11TrayControl {
    var preferredWidth: CGFloat { Theme.Win11.s(230) }

    private var info: NowPlaying.Info?
    private var artwork: NSImage?
    private var artworkKey: String?
    private let prevButton = Win11GlyphButton(symbol: "backward.fill")
    private let playButton = Win11GlyphButton(symbol: "play.fill")
    private let nextButton = Win11GlyphButton(symbol: "forward.fill")

    private var fetching = false
    private var refetch = false
    private var lastFetch = Date.distantPast
    /// Bumped on every command; queries started before it are discarded (optimistic state wins).
    private var gen = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prevButton.onClick = { [weak self] in self?.send("previous track") }
        playButton.onClick = { [weak self] in self?.togglePlay() }
        nextButton.onClick = { [weak self] in self?.send("next track") }
        for b in [prevButton, playButton, nextButton] { addSubview(b) }
        layoutControls()
        apply(Win11NowPlayingCache.info)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutControls()
    }

    // MARK: Geometry

    private func layoutControls() {
        let W = Theme.Win11.self
        let bw = Win11TrayDraw.t(28), bh = Win11TrayDraw.t(32)
        let y = ((bounds.height - bh) / 2).rounded()
        var x = bounds.maxX - W.s(4) - bw
        for b in [nextButton, playButton, prevButton] {
            b.frame = NSRect(x: x, y: y, width: bw, height: bh)
            b.pointSize = Win11TrayDraw.t(12)
            b.cornerRadius = W.buttonRadius
            x -= bw
        }
    }

    private var hasTrack: Bool { info != nil }
    private var coverRect: NSRect {
        let c = Theme.Win11.s(32)
        return NSRect(x: Theme.Win11.s(8), y: ((bounds.height - c) / 2).rounded(), width: c, height: c)
    }
    private var controlsLeft: CGFloat { hasTrack ? prevButton.frame.minX : bounds.maxX - Theme.Win11.s(4) }
    /// Cover + text: hover field and click target for the flyout.
    private var infoRect: NSRect {
        let x = Theme.Win11.s(2)
        return NSRect(x: x, y: 0, width: max(0, controlsLeft - Theme.Win11.s(2) - x), height: bounds.height)
    }

    // MARK: Data

    func refresh() {
        guard Date().timeIntervalSince(lastFetch) >= 0.9 else { return }
        fetch()
    }

    private func fetch() {
        if fetching { refetch = true; return }   // no overlapping osascript queries
        fetching = true
        lastFetch = Date()
        let g = gen
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let i = NowPlaying.current()
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                if g == self.gen { self.apply(i) }
                if self.refetch { self.refetch = false; self.fetch() }
            }
        }
    }

    private func apply(_ i: NowPlaying.Info?) {
        info = i
        Win11NowPlayingCache.info = i
        for b in [prevButton, playButton, nextButton] { b.isHidden = (i == nil) }
        playButton.symbol = (i?.playing ?? false) ? "pause.fill" : "play.fill"
        if let i {
            if i.trackKey != artworkKey { loadArtwork(for: i) }
        } else {
            artworkKey = nil
            artwork = nil
        }
        needsDisplay = true
    }

    private func loadArtwork(for i: NowPlaying.Info) {
        let key = i.trackKey
        artworkKey = key
        if Win11NowPlayingCache.artworkKey == key, let img = Win11NowPlayingCache.artwork {
            artwork = img
            return
        }
        artwork = nil
        NowPlaying.artwork(for: i) { [weak self] img in
            guard let self, self.artworkKey == key else { return }
            self.artwork = img
            Win11NowPlayingCache.artwork = img
            Win11NowPlayingCache.artworkKey = key
            self.needsDisplay = true
        }
    }

    // MARK: Actions

    private func togglePlay() {
        guard let i = info else { return }
        // Optimistic: flip the icon immediately so it feels instant.
        let t = i.togglingPlayback()
        info = t
        Win11NowPlayingCache.info = t
        playButton.symbol = t.playing ? "pause.fill" : "play.fill"
        send("playpause")
    }

    private func send(_ cmd: String) {
        guard let app = info?.app else { return }
        gen += 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NowPlaying.command(cmd, app: app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.fetch() }
        }
    }

    override func clicked(at point: NSPoint) {
        guard infoRect.contains(point),
              let anchor = Win11TrayDraw.screenRect(of: self, infoRect),
              let screen = Win11TrayDraw.screen(of: self) else { return }
        Win11Flyouts.showMedia(anchor: anchor, screen: screen)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let W = Theme.Win11.self
        if let c = highlight(for: infoRect) {
            Win11TrayDraw.fill(Win11TrayDraw.hoverRect(infoRect, in: bounds), radius: W.buttonRadius, c)
        }
        let cover = coverRect
        let radius = max(2, W.s(4))
        let tx = cover.maxX + W.s(8)

        guard let info else {
            Win11TrayDraw.drawCoverPlaceholder(in: cover, radius: radius, glyphSize: Win11TrayDraw.t(14))
            let s = Win11TrayDraw.text("Keine Wiedergabe", font: Win11TrayDraw.font(12), color: W.textSecondary)
            let h = ceil(s.size().height)
            s.draw(in: NSRect(x: tx, y: ((bounds.height - h) / 2).rounded(),
                              width: max(0, bounds.maxX - W.s(6) - tx), height: h))
            return
        }

        if let art = artwork {
            Win11TrayDraw.drawCover(art, in: cover, radius: radius)
        } else {
            Win11TrayDraw.drawCoverPlaceholder(in: cover, radius: radius, glyphSize: Win11TrayDraw.t(14))
        }

        let tw = controlsLeft - W.s(6) - tx
        guard tw > W.s(20) else { return }
        let title = Win11TrayDraw.text(info.title, font: Win11TrayDraw.font(12, weight: .medium), color: W.textPrimary)
        let artist = Win11TrayDraw.text(info.artist, font: Win11TrayDraw.font(11), color: W.textSecondary)
        let th = ceil(title.size().height), ah = ceil(artist.size().height)
        let lineH = max(2, W.s(2))
        let gap = W.s(3)
        var y = (bounds.midY - (th + ah + gap + lineH) / 2).rounded()

        // Thin progress line under the text.
        let track = NSRect(x: tx, y: y, width: tw, height: lineH)
        Win11TrayDraw.fill(track, radius: lineH / 2, W.controlFill)
        let fw = (tw * CGFloat(max(0, min(1, info.fraction)))).rounded()
        if fw > 0 {
            Win11TrayDraw.fill(NSRect(x: tx, y: y, width: fw, height: lineH), radius: lineH / 2, W.accent)
        }
        y += lineH + gap
        artist.draw(in: NSRect(x: tx, y: y, width: tw, height: ah))
        y += ah
        title.draw(in: NSRect(x: tx, y: y, width: tw, height: th))
    }
}

// MARK: - Performance (CPU / RAM)

/// CPU/RAM-Leistungsübersicht. Klick → Aktivitätsanzeige.
final class Win11PerformanceView: Win11TrayControl {
    var preferredWidth: CGFloat { Win11TrayDraw.t(108) }

    private let stats = SystemStats()
    private var cpu = 0
    private var ram = 0
    private var lastSample = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Aktivitätsanzeige öffnen"
        _ = stats.cpuUsagePercent()   // prime the CPU delta
        ram = stats.ramUsagePercent()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        needsDisplay = true
        // Mach calls are cheap, but the CPU value is a delta: sample at most about once a second.
        guard Date().timeIntervalSince(lastSample) >= 0.9 else { return }
        lastSample = Date()
        cpu = stats.cpuUsagePercent()
        ram = stats.ramUsagePercent()
    }

    override func clicked(at point: NSPoint) {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    override func draw(_ dirtyRect: NSRect) {
        let W = Theme.Win11.self
        let field = Win11TrayDraw.hoverRect(bounds.insetBy(dx: W.s(2), dy: 0), in: bounds)
        if let c = highlight(for: bounds) { Win11TrayDraw.fill(field, radius: W.buttonRadius, c) }

        let rowOffset = Win11TrayDraw.t(7)
        drawRow("CPU", value: cpu, centerY: bounds.midY + rowOffset)
        drawRow("RAM", value: ram, centerY: bounds.midY - rowOffset)
    }

    private func drawRow(_ label: String, value: Int, centerY: CGFloat) {
        let W = Theme.Win11.self
        let T = Win11TrayDraw.self
        let pad = W.s(8)
        let labelW = T.t(24)
        let valueW = T.t(30)

        let l = Win11TrayDraw.text(label, font: T.font(10, weight: .medium), color: W.textSecondary)
        let lh = ceil(l.size().height)
        l.draw(in: NSRect(x: pad, y: (centerY - lh / 2).rounded(), width: labelW, height: lh))

        let pct = Win11TrayDraw.text("\(value) %",
            font: T.digitFont(10.5),
            color: W.textPrimary, alignment: .right)
        let ph = ceil(pct.size().height)
        let valueX = bounds.maxX - pad - valueW
        pct.draw(in: NSRect(x: valueX, y: (centerY - ph / 2).rounded(), width: valueW, height: ph))

        // Fully rounded pill bar.
        let barX = pad + labelW
        let barW = valueX - W.s(4) - barX
        guard barW > 4 else { return }
        let h = max(4, T.t(5))
        let track = NSRect(x: barX, y: (centerY - h / 2).rounded(), width: barW, height: h)
        Win11TrayDraw.fill(track, radius: h / 2, W.controlFill)
        Theme.Win11.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2 - 0.5, yRadius: h / 2 - 0.5)
        border.lineWidth = 1
        border.stroke()
        let fw = max(h, (barW * CGFloat(value) / 100).rounded())
        if value > 0 {
            Win11TrayDraw.fill(NSRect(x: barX, y: track.minY, width: min(barW, fw), height: h), radius: h / 2,
                               value >= 85 ? W.warning : W.accent)
        }
    }
}
