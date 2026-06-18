import AppKit

struct AppEntry {
    let name: String
    let url: URL
    let bundleID: String?

    var icon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 32, height: 32)
        return img
    }
}

/// Finds installed applications for the Start-menu launcher.
enum AppScanner {
    private static let searchPaths = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
    ]

    static func installedApps() -> [AppEntry] {
        var seen = Set<String>()
        var result: [AppEntry] = []
        let fm = FileManager.default

        for path in searchPaths {
            guard let items = try? fm.contentsOfDirectory(atPath: path) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: path).appendingPathComponent(item)
                let name = (item as NSString).deletingPathExtension
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                let bundle = Bundle(url: url)
                result.append(AppEntry(name: name, url: url, bundleID: bundle?.bundleIdentifier))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
