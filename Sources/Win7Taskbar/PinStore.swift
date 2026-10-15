import AppKit
import UniformTypeIdentifiers

/// Persists pinned apps (by bundle identifier or path) across launches.
enum PinStore {
    private static let key = "pinnedApps"
    /// Bundle ids already taken over from the Dock (so a pin released here does not come back).
    private static let importedKey = "dockPinsImported"
    /// Windows-7-like defaults the first time the app runs (Explorer, Internet Explorer, Media
    /// Player): Finder, the default browser and the default media player.
    private static var defaults: [String] {
        let ws = NSWorkspace.shared
        func bundleID(_ url: URL?) -> String? { url.flatMap { Bundle(url: $0)?.bundleIdentifier } }
        let browser = bundleID(ws.urlForApplication(toOpen: URL(string: "https://example.com")!)) ?? "com.apple.Safari"
        let player = bundleID(ws.urlForApplication(toOpen: .mp3)) ?? "com.apple.Music"
        var ids: [String] = []
        for id in ["com.apple.finder", browser, player] where !ids.contains(id) { ids.append(id) }
        return ids
    }

    static func load() -> [String] {
        let ud = UserDefaults.standard
        if ud.object(forKey: key) == nil {
            let pins = defaults
            ud.set(pins, forKey: key)
            // Only these defaults: the Dock's current pins count as already offered, so the automatic
            // import at launch only adds apps pinned to the Dock later ("Dock-Apps übernehmen" still
            // takes over all of them).
            if ud.object(forKey: importedKey) == nil { ud.set(dockPinnedBundleIDs(), forKey: importedKey) }
            return pins
        }
        return ud.stringArray(forKey: key) ?? []
    }

    static func save(_ keys: [String]) {
        UserDefaults.standard.set(keys, forKey: key)
    }

    // MARK: - Dock pins

    /// Bundle ids of the apps pinned in the macOS Dock (`com.apple.dock persistent-apps`), in Dock
    /// order, limited to apps that are installed (resolvable via Launch Services).
    static func dockPinnedBundleIDs() -> [String] {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)   // pick up changes the Dock made since launch
        guard let tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]]
        else { return [] }
        var ids: [String] = []
        for tile in tiles {
            guard let data = tile["tile-data"] as? [String: Any],
                  let id = data["bundle-identifier"] as? String, !id.isEmpty,
                  !ids.contains(id),
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            else { continue }
            ids.append(id)
        }
        return ids
    }

    /// Appends the Dock's pinned apps that are missing from the taskbar pins, in Dock order.
    /// `includeReleased == false` (automatic at launch): only apps not imported before, so an app
    /// the user released from the taskbar stays gone while newly Dock-pinned apps are added.
    /// `includeReleased == true` (settings button): re-import every Dock pin.
    /// Returns true when the pins changed.
    @discardableResult
    static func importDockPins(includeReleased: Bool) -> Bool {
        let ud = UserDefaults.standard
        var keys = load()   // first: on the first run this also marks the Dock's current pins as offered
        let dockIDs = dockPinnedBundleIDs()
        guard !dockIDs.isEmpty else { return false }

        let imported = Set(ud.stringArray(forKey: importedKey) ?? [])
        var changed = false
        for id in dockIDs where !keys.contains(id) && (includeReleased || !imported.contains(id)) {
            keys.append(id)
            changed = true
        }
        if changed { save(keys) }

        // Remember everything the Dock offers now (keeps the earlier entries too).
        let all = (ud.stringArray(forKey: importedKey) ?? []) + dockIDs.filter { !imported.contains($0) }
        ud.set(all, forKey: importedKey)
        return changed
    }
}
