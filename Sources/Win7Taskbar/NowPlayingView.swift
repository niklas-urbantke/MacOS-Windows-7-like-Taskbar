import AppKit

/// Compact "now playing" widget for the classic taskbar (Vista / Windows 7): small cover,
/// track title + artist, prev / play-pause / next. Works with any player (`NowPlaying` reads the
/// system-wide media info). A click on cover / title opens the large media flyout.
final class NowPlayingView: NSView {
    private var info: NowPlaying.Info?
    private var artwork: NSImage?
    private var artworkKey: String?
    private let prevButton = NowPlayingView.makeButton("backward.fill")
    private let playButton = NowPlayingView.makeButton("play.fill")
    private let nextButton = NowPlayingView.makeButton("forward.fill")
    private var hoveringInfo = false

    /// Width in the tray: the classic width plus room for the cover.
    var preferredWidth: CGFloat { Theme.nowPlayingWidth + coverSize + Theme.s(6) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prevButton.target = self; prevButton.action = #selector(prevAction)
        playButton.target = self; playButton.action = #selector(playAction)
        nextButton.target = self; nextButton.action = #selector(nextAction)
        prevButton.toolTip = "Zurück"
        nextButton.toolTip = "Weiter"
        addSubview(prevButton); addSubview(playButton); addSubview(nextButton)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        layoutButtons()
        apply(Win11NowPlayingCache.info)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); layoutButtons() }

    private func layoutButtons() {
        let s = Theme.s(22)
        let gap = Theme.s(4)
        let y = (bounds.height - s) / 2
        nextButton.frame = NSRect(x: bounds.maxX - s - Theme.s(6), y: y, width: s, height: s)
        playButton.frame = NSRect(x: nextButton.frame.minX - s - gap, y: y, width: s, height: s)
        prevButton.frame = NSRect(x: playButton.frame.minX - s - gap, y: y, width: s, height: s)
    }

    private var controlsLeft: CGFloat { prevButton.frame.minX }
    private var pad: CGFloat { Theme.s(8) }
    private var coverSize: CGFloat { Theme.s(32) }
    private var coverRect: NSRect {
        NSRect(x: pad, y: ((bounds.height - coverSize) / 2).rounded(), width: coverSize, height: coverSize)
    }
    /// Cover + text: hover field and click target for the media flyout.
    private var infoRect: NSRect {
        let x = Theme.s(3)
        let right = info == nil ? bounds.maxX - Theme.s(3) : controlsLeft - Theme.s(3)
        return NSRect(x: x, y: 0, width: max(0, right - x), height: bounds.height)
    }

    // MARK: - Data

    private var refreshing = false
    /// Bumped on every command; queries started before it are discarded (optimistic state wins).
    private var gen = 0

    func refresh() {
        if refreshing { return }                 // skip overlapping queries
        refreshing = true
        let g = gen
        DispatchQueue.global(qos: .utility).async {
            let info = NowPlaying.current()
            DispatchQueue.main.async {
                self.refreshing = false
                if g == self.gen { self.apply(info) }
            }
        }
    }

    private func apply(_ info: NowPlaying.Info?) {
        self.info = info
        Win11NowPlayingCache.info = info          // the media flyout opens with the current state
        let hasTrack = info != nil
        prevButton.isHidden = !hasTrack
        playButton.isHidden = !hasTrack
        nextButton.isHidden = !hasTrack
        playButton.image = NowPlayingView.symbol((info?.playing ?? false) ? "pause.fill" : "play.fill")
        if let info {
            if info.trackKey != artworkKey { loadArtwork(for: info) }
        } else {
            artworkKey = nil
            artwork = nil
        }
        needsDisplay = true                       // keeps the progress bar fresh
    }

    /// Cover of the current track, shared with the media flyout via `Win11NowPlayingCache`.
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

    // MARK: - Actions

    @objc private func playAction() {
        // Optimistic: flip the icon immediately so it feels instant (the copy keeps bundle id,
        // album, position and duration).
        if let i = info {
            let t = i.togglingPlayback()
            info = t
            Win11NowPlayingCache.info = t
            playButton.image = NowPlayingView.symbol(t.playing ? "pause.fill" : "play.fill")
        }
        send("playpause", refreshAfter: 0.35)
    }
    @objc private func nextAction() { send("next track", refreshAfter: 0.45) }
    @objc private func prevAction() { send("previous track", refreshAfter: 0.45) }

    private func send(_ cmd: String, refreshAfter delay: TimeInterval) {
        guard let app = info?.app else { return }
        gen += 1
        DispatchQueue.global(qos: .userInitiated).async { NowPlaying.command(cmd, app: app) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }

    // MARK: - Mouse (cover / title opens the media flyout)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateHover(_ event: NSEvent?) {
        let inside = event.map { infoRect.contains(convert($0.locationInWindow, from: nil)) } ?? false
        if inside != hoveringInfo { hoveringInfo = inside; needsDisplay = true }
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { updateHover(nil) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard infoRect.contains(p), let window else { return }
        // Toggle: the flyout leaves clicks on its anchor to us, so a second click closes it.
        let anchor = window.convertToScreen(convert(infoRect, to: nil))
        Win11Flyouts.showMedia(anchor: anchor, screen: window.screen ?? NSScreen.main ?? NSScreen.screens[0])
    }

    // MARK: - Drawing

    override func viewWillDraw() {
        super.viewWillDraw()
        // Glyph colour follows the colour mode (white on dark glass, dark on bright glass).
        let tint = ClassicTray.text
        for b in [prevButton, playButton, nextButton] where b.contentTintColor != tint {
            b.contentTintColor = tint
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hoveringInfo { ClassicTray.fillHover(infoRect.insetBy(dx: 0, dy: Theme.s(4))) }

        let cover = coverRect
        drawCover(in: cover)
        let tx = cover.maxX + Theme.s(6)

        guard let info else {
            let s = NSAttributedString(string: "Keine Wiedergabe", attributes: [
                .font: Theme.font(11),
                .foregroundColor: ClassicTray.pick(NSColor(calibratedWhite: 0.75, alpha: 1), Theme.Aero.secondaryText)])
            s.draw(at: NSPoint(x: tx, y: (bounds.height - s.size().height) / 2))
            return
        }

        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(11.5, weight: .medium),
            .foregroundColor: ClassicTray.text, .paragraphStyle: style]
        let artistAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(10),
            .foregroundColor: ClassicTray.pick(NSColor(calibratedWhite: 0.85, alpha: 1), Theme.Aero.secondaryText),
            .paragraphStyle: style]

        let textW = controlsLeft - tx - Theme.s(4)
        guard textW > 30 else { return }
        NSAttributedString(string: info.title, attributes: titleAttrs)
            .draw(in: NSRect(x: tx, y: bounds.midY + Theme.s(3), width: textW, height: Theme.s(15)))
        NSAttributedString(string: info.artist, attributes: artistAttrs)
            .draw(in: NSRect(x: tx, y: bounds.midY - Theme.s(12), width: textW, height: Theme.s(13)))

        // Progress bar.
        let by = Theme.s(7)
        let track = NSRect(x: tx, y: by, width: textW, height: Theme.s(2))
        ClassicTray.pick(NSColor(calibratedWhite: 1, alpha: 0.25), Theme.Aero.track).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        ClassicTray.pick(Theme.accent(brightness: 1.3), Theme.Aero.accent).setFill()
        let fraction = CGFloat(max(0, min(1, info.fraction)))
        NSBezierPath(roundedRect: NSRect(x: tx, y: by, width: textW * fraction, height: Theme.s(2)),
                     xRadius: 1, yRadius: 1).fill()
    }

    /// Small cover in an Aero frame (dark outer rim, bright inner line); a note glyph without one.
    private func drawCover(in rect: NSRect) {
        let radius: CGFloat = 2
        if let art = artwork, info != nil {
            Win11TrayDraw.drawCover(art, in: rect, radius: radius)
        } else {
            ClassicTray.pick(NSColor(calibratedWhite: 1, alpha: 0.12), Theme.Aero.track).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            let cfg = NSImage.SymbolConfiguration(pointSize: 14 * Theme.scale, weight: .regular)
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                let color = ClassicTray.pick(NSColor(calibratedWhite: 0.85, alpha: 1), Theme.Aero.secondaryText)
                let img = ClassicTray.tinted(note, color)
                let s = img.size
                img.draw(in: NSRect(x: (rect.midX - s.width / 2).rounded(), y: (rect.midY - s.height / 2).rounded(),
                                    width: s.width, height: s.height))
            }
        }
        NSColor(calibratedWhite: 0, alpha: Theme.isDark ? 0.55 : 0.30).setStroke()
        let outer = NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), xRadius: radius + 0.5, yRadius: radius + 0.5)
        outer.lineWidth = 1
        outer.stroke()
        NSColor(calibratedWhite: 1, alpha: Theme.isDark ? 0.25 : 0.7).setStroke()
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5),
                                 yRadius: max(0, radius - 0.5))
        inner.lineWidth = 1
        inner.stroke()
    }

    // MARK: - Helpers

    private static func makeButton(_ symbol: String) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.image = NowPlayingView.symbol(symbol)
        b.contentTintColor = ClassicTray.text
        return b
    }

    private static func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13 * Theme.scale, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }
}
