import AppKit

/// Tracks recently opened applications (most recent first), persisted across launches.
/// macOS has no public "recent apps" API, so we record launches/activations ourselves.
enum RecentsStore {
    private static let key = "recentApps"
    private static let maxCount = 16

    private struct Rec: Codable { let bundleID: String; let path: String; let name: String }

    static func record(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let url = app.bundleURL else { return }
        var list = loadRaw().filter { $0.bundleID != bundleID }
        let name = app.localizedName ?? (url.deletingPathExtension().lastPathComponent)
        list.insert(Rec(bundleID: bundleID, path: url.path, name: name), at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        saveRaw(list)
    }

    /// Recently opened apps (most recent first), topped up with currently running apps so the
    /// list is never near-empty before much history has been recorded.
    static func recent() -> [AppEntry] {
        var seen = Set<String>()
        var entries: [AppEntry] = []

        for rec in loadRaw() where FileManager.default.fileExists(atPath: rec.path) {
            guard !seen.contains(rec.bundleID) else { continue }
            seen.insert(rec.bundleID)
            entries.append(AppEntry(name: rec.name, url: URL(fileURLWithPath: rec.path), bundleID: rec.bundleID))
        }

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.bundleIdentifier != Bundle.main.bundleIdentifier {
            guard let id = app.bundleIdentifier, let url = app.bundleURL, !seen.contains(id) else { continue }
            seen.insert(id)
            entries.append(AppEntry(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                    url: url, bundleID: id))
        }
        return Array(entries.prefix(maxCount))
    }

    private static func loadRaw() -> [Rec] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Rec].self, from: data) else { return [] }
        return list
    }

    private static func saveRaw(_ list: [Rec]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Apps the user pinned to the top of the Start-menu program list (by bundle id).
enum StartPins {
    private static let key = "startMenuPins"

    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func isPinned(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return load().contains(bundleID)
    }
    static func toggle(_ bundleID: String?) {
        guard let bundleID else { return }
        var list = load()
        if list.contains(bundleID) { list.removeAll { $0 == bundleID } }
        else { list.append(bundleID) }
        UserDefaults.standard.set(list, forKey: key)
    }

    /// Pinned apps resolved to AppEntry (skips apps no longer installed).
    static func entries() -> [AppEntry] {
        load().compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return AppEntry(name: url.deletingPathExtension().lastPathComponent, url: url, bundleID: id)
        }
    }
}
