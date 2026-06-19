import AppKit

/// Compact "now playing" widget for the taskbar: track title + prev / play-pause / next.
final class NowPlayingView: NSView {
    private var info: NowPlaying.Info?
    private let prevButton = NowPlayingView.makeButton("backward.fill")
    private let playButton = NowPlayingView.makeButton("play.fill")
    private let nextButton = NowPlayingView.makeButton("forward.fill")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prevButton.target = self; prevButton.action = #selector(prevAction)
        playButton.target = self; playButton.action = #selector(playAction)
        nextButton.target = self; nextButton.action = #selector(nextAction)
        addSubview(prevButton); addSubview(playButton); addSubview(nextButton)
        layoutButtons()
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

    // MARK: - Data

    private var refreshing = false

    func refresh() {
        if refreshing { return }                 // skip overlapping queries
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let info = NowPlaying.current()
            DispatchQueue.main.async {
                self.refreshing = false
                self.apply(info)
            }
        }
    }

    private func apply(_ info: NowPlaying.Info?) {
        let changed = info?.title != self.info?.title
            || info?.artist != self.info?.artist
            || info?.playing != self.info?.playing
            || (info == nil) != (self.info == nil)
        self.info = info
        let hasTrack = info != nil
        prevButton.isHidden = !hasTrack
        playButton.isHidden = !hasTrack
        nextButton.isHidden = !hasTrack
        playButton.image = NowPlayingView.symbol((info?.playing ?? false) ? "pause.fill" : "play.fill")
        if changed || info != nil { needsDisplay = true }   // keep progress bar fresh
    }

    // MARK: - Actions

    @objc private func playAction() {
        // Optimistic: flip the icon immediately so it feels instant.
        if let i = info {
            info = NowPlaying.Info(app: i.app, title: i.title, artist: i.artist,
                                   playing: !i.playing, fraction: i.fraction)
            playButton.image = NowPlayingView.symbol(info!.playing ? "pause.fill" : "play.fill")
        }
        send("playpause", refreshAfter: 0.35)
    }
    @objc private func nextAction() { send("next track", refreshAfter: 0.45) }
    @objc private func prevAction() { send("previous track", refreshAfter: 0.45) }

    private func send(_ cmd: String, refreshAfter delay: TimeInterval) {
        guard let app = info?.app else { return }
        DispatchQueue.global(qos: .userInitiated).async { NowPlaying.command(cmd, app: app) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let pad = Theme.s(8)
        guard let info else {
            let s = NSAttributedString(string: "♪ —", attributes: [
                .font: Theme.font(11),
                .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1)])
            s.draw(at: NSPoint(x: pad, y: (bounds.height - s.size().height) / 2))
            return
        }

        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(11.5, weight: .medium),
            .foregroundColor: NSColor.white, .paragraphStyle: style]
        let artistAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(10),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1), .paragraphStyle: style]

        let textW = controlsLeft - pad - Theme.s(4)
        guard textW > 30 else { return }
        NSAttributedString(string: info.title, attributes: titleAttrs)
            .draw(in: NSRect(x: pad, y: bounds.midY + Theme.s(3), width: textW, height: Theme.s(15)))
        NSAttributedString(string: info.artist, attributes: artistAttrs)
            .draw(in: NSRect(x: pad, y: bounds.midY - Theme.s(12), width: textW, height: Theme.s(13)))

        // Progress bar.
        let by = Theme.s(7)
        let track = NSRect(x: pad, y: by, width: textW, height: Theme.s(2))
        NSColor(calibratedWhite: 1, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        Theme.accent(brightness: 1.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: pad, y: by, width: textW * CGFloat(info.fraction), height: Theme.s(2)),
                     xRadius: 1, yRadius: 1).fill()
    }

    // MARK: - Helpers

    private static func makeButton(_ symbol: String) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.image = NowPlayingView.symbol(symbol)
        b.contentTintColor = .white
        return b
    }

    private static func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13 * Theme.scale, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }
}
