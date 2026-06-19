import Foundation

/// Now-playing info from Spotify / Apple Music via AppleScript.
/// (macOS no longer exposes system-wide now-playing to third-party apps, so we query the
/// supported player apps directly.)
enum NowPlaying {
    struct Info {
        let app: String; let title: String; let artist: String
        let playing: Bool; var fraction: Double
    }

    private static let sep = "|||"

    static func current() -> Info? {
        let script = """
        set sep to "\(sep)"
        try
            if application "Spotify" is running then
                tell application "Spotify"
                    if player state is not stopped then
                        return "Spotify" & sep & (player state as text) & sep & (name of current track) & sep & (artist of current track) & sep & (player position as text) & sep & ((duration of current track) as text)
                    end if
                end tell
            end if
        end try
        try
            if application "Music" is running then
                tell application "Music"
                    if player state is not stopped then
                        return "Music" & sep & (player state as text) & sep & (name of current track) & sep & (artist of current track) & sep & (player position as text) & sep & ((duration of current track) as text)
                    end if
                end tell
            end if
        end try
        return ""
        """
        let parts = run(script).components(separatedBy: sep)
        guard parts.count == 6 else { return nil }
        let app = parts[0]
        let title = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let pos = Double(parts[4].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) ?? 0
        var dur = Double(parts[5].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) ?? 0
        if app == "Spotify" { dur /= 1000 }   // Spotify reports duration in milliseconds
        let fraction = dur > 0 ? max(0, min(1, pos / dur)) : 0

        return Info(app: app,
                    title: title,
                    artist: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
                    playing: parts[1].lowercased().contains("playing"),
                    fraction: fraction)
    }

    /// cmd is the AppleScript verb: "playpause", "next track", "previous track".
    static func command(_ cmd: String, app: String) {
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
