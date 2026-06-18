import Foundation

/// Persists pinned apps (by bundle identifier or path) across launches.
enum PinStore {
    private static let key = "pinnedApps"
    // Sensible Win7-like defaults the first time the app runs.
    private static let defaults = [
        "com.apple.finder",
        "com.apple.Safari",
        "com.apple.mail",
    ]

    static func load() -> [String] {
        let ud = UserDefaults.standard
        if ud.object(forKey: key) == nil {
            ud.set(defaults, forKey: key)
            return defaults
        }
        return ud.stringArray(forKey: key) ?? []
    }

    static func save(_ keys: [String]) {
        UserDefaults.standard.set(keys, forKey: key)
    }
}
