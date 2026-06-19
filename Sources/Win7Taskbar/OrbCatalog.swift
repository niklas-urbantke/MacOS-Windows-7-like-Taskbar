import AppKit

/// Discovers the available Start-orb images (bundled under Resources/orbs) and tracks the choice.
enum OrbCatalog {
    struct Orb { let label: String; let file: String; let url: URL }

    static func available() -> [Orb] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("orbs"),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Orb(label: label(for: $0), file: $0.lastPathComponent, url: $0) }
    }

    private static func label(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if base == "orb" { return "Windows 7" }
        return base.replacingOccurrences(of: "-orb", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    static var selectedFile: String {
        UserDefaults.standard.string(forKey: "orbFile") ?? "orb.png"
    }

    static var selectedURL: URL? {
        let all = available()
        return all.first(where: { $0.file == selectedFile })?.url
            ?? all.first(where: { $0.file == "orb.png" })?.url
            ?? all.first?.url
    }

    static func select(_ file: String) {
        UserDefaults.standard.set(file, forKey: "orbFile")
    }
}
