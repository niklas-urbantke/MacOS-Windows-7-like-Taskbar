import AppKit

/// Now-playing info for any player (Tidal, Spotify, Music, browsers …).
///
/// Primary source is the system-wide MediaRemote info, read by a small helper that runs
/// inside `/usr/bin/perl` (see `MediaRemoteHelper/`): since macOS 15.4 MediaRemote hands
/// third-party apps an empty dictionary, but Apple-signed binaries still get everything.
/// Without the helper (or while it reports nothing) Spotify / Apple Music are queried
/// directly via AppleScript as before.
enum NowPlaying {
    struct Info {
        let app: String; let title: String; let artist: String
        let playing: Bool; var fraction: Double
        var album: String = ""
        /// Playback position and track length in seconds.
        var position: Double = 0
        var duration: Double = 0
        /// Spotify only: cover URL (Music covers are fetched via `artwork(for:)`).
        var artworkURL: String = ""
        /// Bundle identifier of the playing app (e.g. "com.tidal.desktop"), empty if unknown.
        var bundleID: String = ""

        /// Identifies the track (used as artwork cache key).
        var trackKey: String { "\(app)|\(title)|\(artist)|\(album)" }
    }

    /// Latest state; cheap when the helper runs (no process spawn per call).
    static func current() -> Info? {
        if let info = MediaRemoteHelper.shared.currentInfo() { return info }
        return scriptCurrent()
    }

    /// Jump to `seconds` in the current track.
    static func seek(to seconds: Double, app: String) {
        let helper = MediaRemoteHelper.shared
        if helper.handles(app: app) {
            helper.seek(to: max(0, seconds))
            return
        }
        let v = String(format: "%.2f", max(0, seconds)).replacingOccurrences(of: ",", with: ".")
        scriptCommand("set player position to \(v)", app: app)
    }

    /// cmd is the AppleScript verb: "playpause", "next track", "previous track".
    static func command(_ cmd: String, app: String) {
        let helper = MediaRemoteHelper.shared
        if let line = helperCommand(cmd), helper.handles(app: app) {
            helper.send(line)
            return
        }
        scriptCommand(cmd, app: app)
    }

    private static func helperCommand(_ cmd: String) -> String? {
        switch cmd {
        case "playpause": return "toggle"
        case "play": return "play"
        case "pause": return "pause"
        case "next track": return "next"
        case "previous track": return "prev"
        default: return nil
        }
    }

    // MARK: - Artwork

    private static var artworkCache: [String: NSImage] = [:]
    private static let artworkQueue = DispatchQueue(label: "nowplaying.artwork")

    /// Cover of the given track, fetched in the background and cached per track.
    /// `completion` runs on the main queue (nil if the player offers no cover).
    static func artwork(for info: Info, completion: @escaping (NSImage?) -> Void) {
        let key = info.trackKey
        if let img = artworkCache[key] { completion(img); return }
        artworkQueue.async {
            // Helper data first (covers every player); the cover may arrive a moment
            // after the title, so wait briefly for it.
            var img = MediaRemoteHelper.shared.artwork(for: info, timeout: 3)
            if img == nil {
                if info.app == "Spotify" {
                    if let url = URL(string: info.artworkURL), let data = try? Data(contentsOf: url) {
                        img = NSImage(data: data)
                    }
                } else if info.app == "Music" {
                    img = musicArtwork()
                }
            }
            DispatchQueue.main.async {
                if let img {
                    if artworkCache.count > 20 { artworkCache.removeAll() }
                    artworkCache[key] = img
                }
                completion(img)
            }
        }
    }

    // MARK: - AppleScript fallback (Spotify / Music)

    private static let sep = "|||"

    private static func scriptCurrent() -> Info? {
        let script = """
        set sep to "\(sep)"
        try
            if application "Spotify" is running then
                tell application "Spotify"
                    if player state is not stopped then
                        return "Spotify" & sep & (player state as text) & sep & (name of current track) & sep & (artist of current track) & sep & (player position as text) & sep & ((duration of current track) as text) & sep & (album of current track) & sep & (artwork url of current track)
                    end if
                end tell
            end if
        end try
        try
            if application "Music" is running then
                tell application "Music"
                    if player state is not stopped then
                        return "Music" & sep & (player state as text) & sep & (name of current track) & sep & (artist of current track) & sep & (player position as text) & sep & ((duration of current track) as text) & sep & (album of current track) & sep & ""
                    end if
                end tell
            end if
        end try
        return ""
        """
        let parts = run(script).components(separatedBy: sep)
        guard parts.count >= 6 else { return nil }
        let app = parts[0]
        let title = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let pos = Double(parts[4].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) ?? 0
        var dur = Double(parts[5].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) ?? 0
        if app == "Spotify" { dur /= 1000 }   // Spotify reports duration in milliseconds
        let fraction = dur > 0 ? max(0, min(1, pos / dur)) : 0

        func part(_ i: Int) -> String {
            i < parts.count ? parts[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        return Info(app: app,
                    title: title,
                    artist: part(3),
                    playing: parts[1].lowercased().contains("playing"),
                    fraction: fraction,
                    album: part(6),
                    position: pos,
                    duration: dur,
                    artworkURL: part(7),
                    bundleID: app == "Spotify" ? "com.spotify.client" : "com.apple.Music")
    }

    /// Apple Music exposes the cover only as raw data → written to a temp file via AppleScript.
    private static func musicArtwork() -> NSImage? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Win7Taskbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("nowplaying-artwork.dat")
        try? FileManager.default.removeItem(at: file)
        let script = """
        try
            tell application "Music" to set d to raw data of artwork 1 of current track
            set f to open for access (POSIX file "\(file.path)") with write permission
            set eof f to 0
            write d to f
            close access f
            return "ok"
        on error
            try
                close access (POSIX file "\(file.path)")
            end try
            return ""
        end try
        """
        guard run(script).contains("ok"), let data = try? Data(contentsOf: file) else { return nil }
        return NSImage(data: data)
    }

    private static func scriptCommand(_ cmd: String, app: String) {
        _ = run("try\nif application \"\(app)\" is running then tell application \"\(app)\" to \(cmd)\nend try")
    }

    @discardableResult
    private static func run(_ script: String) -> String {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - MediaRemote helper process

/// Long-running `/usr/bin/perl` process with the MediaRemote dylib
/// (`Contents/Resources/mediaremote/`). Reports JSON lines on stdout, takes commands on
/// stdin and exits when stdin closes (i.e. when this app quits). All state is guarded by
/// `cond`; callers may come from any thread.
private final class MediaRemoteHelper {
    static let shared = MediaRemoteHelper()

    /// Apps whose AppleScript names the rest of the UI uses ("Spotify", "Music").
    private static let scriptNames = ["com.spotify.client": "Spotify", "com.apple.Music": "Music"]

    private struct State {
        var title = "", artist = "", album = "", bundleID = "", artworkID = ""
        var duration = 0.0, elapsed = 0.0, rate = 0.0
        /// Epoch seconds at which `elapsed` was valid.
        var time = 0.0
        var playing = false

        /// Position now, extrapolated while playing.
        func position(at now: Double) -> Double {
            let r = playing ? (rate > 0 ? rate : 1) : 0
            let p = max(0, elapsed + (now - time) * r)
            return duration > 0 ? min(p, duration) : p
        }
    }

    /// Local guess after a command until the helper confirms it (or the guess expires).
    private struct Override {
        var playing: Bool, position: Double, time: Double, until: Double
    }

    private let cond = NSCondition()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var state: State?
    private var override: Override?
    private var artwork: (id: String, data: Data)?
    private var gotMessage = false
    private var startedAt = Date.distantPast
    private var nextStart = Date.distantPast
    private var failures = 0
    private var appNames: [String: String] = [:]

    private var resourceDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("mediaremote", isDirectory: true)
    }

    // MARK: Public (for NowPlaying)

    /// Current track from the helper, nil if the helper is unavailable or reports nothing.
    func currentInfo() -> NowPlaying.Info? {
        cond.lock()
        ensureRunning()
        // Right after the start, wait briefly for the first report instead of falling
        // back to AppleScript for no reason.
        let deadline = startedAt.addingTimeInterval(1.5)
        while process != nil, !gotMessage, Date() < deadline {
            _ = cond.wait(until: deadline)
        }
        guard var s = state, !s.title.isEmpty else { cond.unlock(); return nil }
        let now = Date().timeIntervalSince1970
        if let o = override {
            if now < o.until {
                s.playing = o.playing; s.elapsed = o.position; s.time = o.time
            } else {
                override = nil
            }
        }
        cond.unlock()

        let pos = s.position(at: now)
        return NowPlaying.Info(app: appName(for: s.bundleID),
                    title: s.title,
                    artist: s.artist,
                    playing: s.playing,
                    fraction: s.duration > 0 ? max(0, min(1, pos / s.duration)) : 0,
                    album: s.album,
                    position: pos,
                    duration: s.duration,
                    bundleID: s.bundleID)
    }

    /// Whether commands for `app` should go through MediaRemote. Spotify / Music only if
    /// they are the app MediaRemote currently reports (otherwise AppleScript targets them).
    func handles(app: String) -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard process != nil else { return false }
        if Self.scriptNames.values.contains(app) {
            guard let s = state, !s.title.isEmpty else { return false }
            return Self.scriptNames[s.bundleID] == app
        }
        return true
    }

    func send(_ line: String) {
        cond.lock()
        if line == "toggle" || line == "play" || line == "pause", let s = state {
            let now = Date().timeIntervalSince1970
            let current = override.map { $0.playing } ?? s.playing
            let playing = line == "toggle" ? !current : line == "play"
            let pos = currentPosition(s, now: now)
            override = Override(playing: playing, position: pos, time: now, until: now + 1.5)
        }
        write(line)
        cond.unlock()
    }

    func seek(to seconds: Double) {
        cond.lock()
        if let s = state {
            let now = Date().timeIntervalSince1970
            let playing = override.map { $0.playing } ?? s.playing
            override = Override(playing: playing, position: seconds, time: now, until: now + 1.5)
        }
        write(String(format: "seek %.3f", seconds).replacingOccurrences(of: ",", with: "."))
        cond.unlock()
    }

    /// Cover for `info` once the helper has it; waits up to `timeout` for a late cover.
    func artwork(for info: NowPlaying.Info, timeout: TimeInterval) -> NSImage? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while true {
            guard let s = state, s.title == info.title, s.artist == info.artist,
                  s.album == info.album else { return nil }
            if let a = artwork, !s.artworkID.isEmpty, a.id == s.artworkID {
                return NSImage(data: a.data)
            }
            if Date() >= deadline || !cond.wait(until: deadline) { return nil }
        }
    }

    // MARK: Process (call with `cond` locked)

    private func ensureRunning() {
        guard process == nil, Date() >= nextStart else { return }
        guard let dir = resourceDir,
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("mediaremote-helper.pl").path),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("libmediaremote-helper.dylib").path)
        else {
            nextStart = .distantFuture   // not bundled (e.g. `swift run`): AppleScript only
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [dir.appendingPathComponent("mediaremote-helper.pl").path,
                       dir.appendingPathComponent("libmediaremote-helper.dylib").path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        // A dead helper must not kill us with SIGPIPE when we write a command.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(data, from: p)
        }
        p.terminationHandler = { [weak self] p in self?.didTerminate(p) }
        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            nextStart = Date().addingTimeInterval(30)
            return
        }
        process = p
        input = inPipe.fileHandleForWriting
        buffer = Data()
        gotMessage = false
        startedAt = Date()
    }

    private func didTerminate(_ p: Process) {
        cond.lock(); defer { cond.unlock() }
        guard process === p else { return }
        process = nil
        input = nil
        state = nil
        override = nil
        artwork = nil
        // Crashed soon after the start: back off (2 s, 4 s, … up to 60 s).
        failures = Date().timeIntervalSince(startedAt) < 10 ? failures + 1 : 0
        nextStart = Date().addingTimeInterval(min(60, 2 * pow(2, Double(max(0, failures - 1)))))
        cond.broadcast()
    }

    private func write(_ line: String) {
        guard let input, let data = (line + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    private func currentPosition(_ s: State, now: Double) -> Double {
        if let o = override, now < o.until {
            var t = s
            t.playing = o.playing; t.elapsed = o.position; t.time = o.time
            return t.position(at: now)
        }
        return s.position(at: now)
    }

    // MARK: Reports

    private func consume(_ data: Data, from p: Process) {
        cond.lock(); defer { cond.unlock() }
        guard process === p else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                apply(obj)
            }
        }
        cond.broadcast()
    }

    private func apply(_ d: [String: Any]) {
        func str(_ k: String) -> String { d[k] as? String ?? "" }
        func num(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        var s = State()
        s.title = str("title"); s.artist = str("artist"); s.album = str("album")
        s.bundleID = str("bundleID"); s.artworkID = str("artworkID")
        s.duration = num("duration"); s.elapsed = num("elapsed"); s.rate = num("rate")
        s.time = d["time"] != nil ? num("time") : Date().timeIntervalSince1970
        s.playing = (d["playing"] as? NSNumber)?.boolValue ?? false
        if let b64 = d["artwork"] as? String, let data = Data(base64Encoded: b64) {
            artwork = (s.artworkID, data)
        } else if s.artworkID.isEmpty {
            artwork = nil
        }
        // Drop the local guess once the player confirms it.
        if let o = override, o.playing == s.playing {
            let now = Date().timeIntervalSince1970
            var guess = s
            guess.elapsed = o.position; guess.time = o.time
            if abs(guess.position(at: now) - s.position(at: now)) < 2 { override = nil }
        }
        state = s
        gotMessage = true
    }

    // MARK: App names

    /// Display name of the playing app. Spotify / Music keep their AppleScript names,
    /// which the rest of the UI (and the AppleScript fallback) relies on.
    private func appName(for bundleID: String) -> String {
        if let n = Self.scriptNames[bundleID] { return n }
        guard !bundleID.isEmpty else { return "Medien" }
        cond.lock()
        if let n = appNames[bundleID] { cond.unlock(); return n }
        cond.unlock()
        var name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName
        if name == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        let n = name ?? bundleID
        cond.lock(); appNames[bundleID] = n; cond.unlock()
        return n
    }
}
