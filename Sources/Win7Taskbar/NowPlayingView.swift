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
        let s: CGFloat = 22
        let y = (bounds.height - s) / 2
        nextButton.frame = NSRect(x: bounds.maxX - s - 6, y: y, width: s, height: s)
        playButton.frame = NSRect(x: nextButton.frame.minX - s - 4, y: y, width: s, height: s)
        prevButton.frame = NSRect(x: playButton.frame.minX - s - 4, y: y, width: s, height: s)
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
        if changed { needsDisplay = true }       // avoid needless redraws/flicker
    }

    // MARK: - Actions

    @objc private func playAction() {
        // Optimistic: flip the icon immediately so it feels instant.
        if let i = info {
            info = NowPlaying.Info(app: i.app, title: i.title, artist: i.artist, playing: !i.playing)
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
        guard let info else {
            let s = NSAttributedString(string: "♪ —", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1)])
            s.draw(at: NSPoint(x: 8, y: (bounds.height - s.size().height) / 2))
            return
        }

        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white, .paragraphStyle: style]
        let artistAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1), .paragraphStyle: style]

        let textW = controlsLeft - 12
        guard textW > 30 else { return }
        NSAttributedString(string: info.title, attributes: titleAttrs)
            .draw(in: NSRect(x: 8, y: bounds.midY + 1, width: textW, height: 15))
        NSAttributedString(string: info.artist, attributes: artistAttrs)
            .draw(in: NSRect(x: 8, y: bounds.midY - 15, width: textW, height: 13))
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
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }
}
