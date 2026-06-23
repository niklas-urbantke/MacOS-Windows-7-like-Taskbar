import AppKit

/// Discovers Start-orb images and tracks the choice.
/// Orbs come from two places: the bundled `Resources/orbs` and a user-writable folder
/// (`~/Library/Application Support/Win7Taskbar/orbs`) — drop PNGs there and they appear.
///
/// An orb PNG should hold the three states stacked vertically (normal / hover / pressed).
enum OrbCatalog {
    struct Orb { let label: String; let file: String; let url: URL }

    /// Sentinel for the original three-state Windows 7 orb (orbNormal/Hover/Pressed in the theme).
    /// It isn't a single PNG, so it's rendered specially by StartOrbButton.
    static let win7Token = "__win7orb__"

    /// User-writable orbs folder (created on demand).
    static var userDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Win7Taskbar/orbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func available() -> [Orb] {
        var seen = Set<String>()
        var result: [Orb] = []
        // Synthetic entry for the original Windows 7 orb (three separate state PNGs in the theme).
        if let url = Bundle.main.url(forResource: "orbNormal", withExtension: "png", subdirectory: "theme") {
            result.append(Orb(label: "Windows 7 (Original)", file: win7Token, url: url))
        }
        func scan(_ dir: URL?) {
            guard let dir,
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil) else { return }
            for f in files where f.pathExtension.lowercased() == "png" {
                let name = f.lastPathComponent
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                result.append(Orb(label: label(for: f), file: name, url: f))
            }
        }
        scan(Bundle.main.resourceURL?.appendingPathComponent("orbs"))
        scan(userDir)
        return result.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private static func label(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if base == "orb" { return "Windows 7" }
        return base.replacingOccurrences(of: "-orb", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    static var selectedFile: String {
        if let f = UserDefaults.standard.string(forKey: "orbFile") { return f }
        // No explicit choice yet: default to the original orb in the Win7 theme, else orb.png.
        return Theme.taskbarStyle == .win7 ? win7Token : "orb.png"
    }

    static var selectedURL: URL? {
        if selectedFile == win7Token { return nil }   // rendered specially, not as a flat image
        let all = available()
        return all.first(where: { $0.file == selectedFile })?.url
            ?? all.first(where: { $0.file == "orb.png" })?.url
            ?? all.first?.url
    }

    static func select(_ file: String) { UserDefaults.standard.set(file, forKey: "orbFile") }

    /// Copy a chosen PNG into the user folder; returns its filename.
    static func importOrb(from src: URL) -> String? {
        let dest = userDir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: src, to: dest); return dest.lastPathComponent }
        catch { return nil }
    }
}
