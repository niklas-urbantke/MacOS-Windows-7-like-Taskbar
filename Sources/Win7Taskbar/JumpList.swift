import AppKit

/// App-specific context-menu actions ("jump list"), e.g. Chromium browser profiles.
/// (macOS doesn't expose an app's own Dock menu to third parties, so we build known ones.)
enum JumpList {
    struct Action { let title: String; let perform: () -> Void }

    static func actions(for item: TaskbarItem) -> [Action] {
        switch item.key {
        case "com.apple.finder":
            return finderFolders()
        case "com.apple.Terminal":
            guard let u = item.url else { return [] }
            return [Action(title: "Neues Fenster") { openNew(u) }]
        case "com.apple.mail":
            return [Action(title: "Neue Nachricht") {
                if let u = URL(string: "mailto:") { NSWorkspace.shared.open(u) }
            }]
        case "com.spotify.client":
            return mediaActions("Spotify")
        case "com.apple.Music":
            return mediaActions("Music")
        case "com.microsoft.VSCode":
            guard let u = item.url else { return [] }
            return [Action(title: "Neues Fenster") { openNew(u, args: ["-n"]) }]
        default:
            if let url = item.url, let dir = chromiumSupportDir(item.key) {
                return chromiumProfiles(appURL: url, supportDir: dir, bundleID: item.key)
            }
            return []
        }
    }

    private static func mediaActions(_ app: String) -> [Action] {
        [Action(title: "Wiedergabe / Pause") { NowPlaying.command("playpause", app: app) },
         Action(title: "Weiter")             { NowPlaying.command("next track", app: app) },
         Action(title: "Zurück")             { NowPlaying.command("previous track", app: app) }]
    }

    private static func openNew(_ appURL: URL, args: [String] = []) {
        let p = Process()
        p.launchPath = "/usr/bin/open"
        p.arguments = ["-na", appURL.path] + (args.isEmpty ? [] : ["--args"] + args)
        try? p.run()
    }

    // MARK: - Finder: personal folders

    private static func finderFolders() -> [Action] {
        let fm = FileManager.default
        var actions: [Action] = []

        func add(_ url: URL?) {
            guard let url, fm.fileExists(atPath: url.path) else { return }
            let title = fm.displayName(atPath: url.path)
            actions.append(Action(title: title) { NSWorkspace.shared.open(url) })
        }

        add(URL(fileURLWithPath: NSHomeDirectory()))            // Benutzerordner
        let dirs: [FileManager.SearchPathDirectory] = [
            .desktopDirectory, .documentDirectory, .downloadsDirectory,
            .picturesDirectory, .musicDirectory, .moviesDirectory,
        ]
        for d in dirs { add(fm.urls(for: d, in: .userDomainMask).first) }

        // iCloud Drive (falls vorhanden) und Programme.
        add(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))
        add(fm.urls(for: .applicationDirectory, in: .localDomainMask).first)

        return actions
    }

    // MARK: - Chromium browsers

    private static func chromiumSupportDir(_ bundleID: String) -> String? {
        switch bundleID {
        case "com.brave.Browser":          return "BraveSoftware/Brave-Browser"
        case "com.google.Chrome",
             "com.google.Chrome.beta",
             "com.google.Chrome.canary":   return "Google/Chrome"
        case "com.microsoft.edgemac":      return "Microsoft Edge"
        case "org.chromium.Chromium":      return "Chromium"
        case "com.vivaldi.Vivaldi":        return "Vivaldi"
        default:                           return nil
        }
    }

    private static func chromiumProfiles(appURL: URL, supportDir: String, bundleID: String) -> [Action] {
        let base = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/\(supportDir)")
        let localState = URL(fileURLWithPath: (base as NSString).appendingPathComponent("Local State"))

        // Try to read the browser's profile list. Since macOS 15/26 the profile folder is TCC-
        // protected ("Operation not permitted") unless the app has Full Disk Access, so this can
        // fail even though the file exists → fall back to generic window actions + a grant hint.
        let data: Data?
        do { data = try Data(contentsOf: localState) } catch { data = nil }

        if let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = json["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: Any] {
            // Keep the browser's own profile order; append any missing ones.
            var dirs = (profile["profiles_order"] as? [String]) ?? []
            for key in cache.keys.sorted() where !dirs.contains(key) { dirs.append(key) }

            var actions: [Action] = []
            for dir in dirs {
                guard let info = cache[dir] as? [String: Any] else { continue }
                let name = (info["name"] as? String) ?? dir
                actions.append(Action(title: name) { launchChromium(appURL: appURL, profileDir: dir) })
            }
            if !actions.isEmpty { return actions }
        }

        // No profiles readable (not installed, or access blocked): generic fallback.
        let privateFlag = (bundleID == "com.microsoft.edgemac") ? "--inprivate" : "--incognito"
        var actions: [Action] = [
            Action(title: "Neues Fenster") { openNew(appURL) },
            Action(title: "Neues privates Fenster") { openNew(appURL, args: [privateFlag]) },
        ]
        // Offer to grant access so the profile list works again (macOS 26+ TCC restriction).
        if FileManager.default.fileExists(atPath: base) {
            actions.append(Action(title: "Profile aktivieren: Vollzugriff erlauben…") {
                openFullDiskAccessSettings()
            })
        }
        return actions
    }

    /// Open System Settings → Privacy & Security → Full Disk Access so the user can grant the app
    /// access to the (now TCC-protected) browser profile folders.
    private static func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }

    private static func launchChromium(appURL: URL, profileDir: String) {
        let p = Process()
        p.launchPath = "/usr/bin/open"
        p.arguments = ["-na", appURL.path, "--args", "--profile-directory=\(profileDir)"]
        try? p.run()
    }
}
