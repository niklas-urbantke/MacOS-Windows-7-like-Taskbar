import AppKit

/// Deinstalliert eine App samt ihrer übrig gebliebenen Daten (Einstellungen, Caches, Container,
/// Application Support …) nach einer kurzen Rückfrage. Alles wandert in den Papierkorb, nichts wird
/// endgültig gelöscht, ein Versehen lässt sich dort rückgängig machen.
enum AppUninstaller {
    /// Posted after an app was uninstalled (object: bundle ID), so taskbars and menus can refresh.
    static let didUninstallNotification = Notification.Name("de.batix.win7taskbar.appUninstalled")

    /// Only real third-party app bundles: no system apps, not this taskbar itself.
    static func canUninstall(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        guard url.pathExtension == "app",
              !path.hasPrefix("/System/"),
              path != Bundle.main.bundleURL.resolvingSymlinksInPath().path else { return false }
        if let id = Bundle(url: url)?.bundleIdentifier, id.hasPrefix("com.apple.") { return false }
        return true
    }

    // MARK: - Leftover search

    /// Vendor folders shared by several apps: never matched by app name alone.
    private static let sharedNames: Set<String> = [
        "google", "microsoft", "adobe", "jetbrains", "apple", "mozilla", "oracle", "java",
        "com.apple", "caches", "preferences", "logs", "crashreporter", "icloud",
    ]

    /// Files and folders belonging to the app, found by bundle ID (and helper IDs `<id>.*`) and,
    /// for the Application Support/Caches/Logs folders, by exact app name.
    static func leftovers(appURL: URL, bundleID: String?) -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundle = Bundle(url: appURL)
        let id = (bundleID ?? bundle?.bundleIdentifier ?? "").lowercased()
        var names = Set<String>()
        for n in [appURL.deletingPathExtension().lastPathComponent,
                  bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                  bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String].compactMap({ $0 }) {
            let l = n.lowercased()
            if l.count >= 4, !sharedNames.contains(l) { names.insert(l) }
        }

        /// Does a directory entry belong to the app?
        func matchesID(_ entry: String) -> Bool {
            guard !id.isEmpty else { return false }
            let e = entry.lowercased()
            // "<id>", "<id>.plist", "<id>.savedState", "<id>.binarycookies", helpers "<id>.helper" …
            return e == id || e.hasPrefix(id + ".") || e.hasPrefix(id + "_")
        }
        func matchesName(_ entry: String) -> Bool { names.contains(entry.lowercased()) }

        var found: [URL] = []
        func scan(_ dir: URL, byName: Bool, contains: Bool = false) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for item in items {
                let hit = matchesID(item) || (byName && matchesName(item))
                    || (contains && !id.isEmpty && item.lowercased().contains(id))
                if hit { found.append(dir.appendingPathComponent(item)) }
            }
        }

        for lib in [home.appendingPathComponent("Library"), URL(fileURLWithPath: "/Library")] {
            scan(lib.appendingPathComponent("Application Support"), byName: true)
            scan(lib.appendingPathComponent("Caches"), byName: true)
            scan(lib.appendingPathComponent("Logs"), byName: true)
            scan(lib.appendingPathComponent("Preferences"), byName: false)
            scan(lib.appendingPathComponent("Preferences/ByHost"), byName: false)
            scan(lib.appendingPathComponent("LaunchAgents"), byName: false)
            scan(lib.appendingPathComponent("WebKit"), byName: false)
            scan(lib.appendingPathComponent("HTTPStorages"), byName: false)
        }
        let userLib = home.appendingPathComponent("Library")
        scan(userLib.appendingPathComponent("Containers"), byName: false)
        // Group containers are named "<TeamID>.<id>" or "group.<id>…": match "contains".
        scan(userLib.appendingPathComponent("Group Containers"), byName: false, contains: true)
        scan(userLib.appendingPathComponent("Saved Application State"), byName: false)
        scan(userLib.appendingPathComponent("Cookies"), byName: false)
        scan(userLib.appendingPathComponent("Application Scripts"), byName: false)
        scan(URL(fileURLWithPath: "/Library/LaunchDaemons"), byName: false)
        scan(URL(fileURLWithPath: "/Library/PrivilegedHelperTools"), byName: false)

        // Unique, and nothing inside the app bundle itself.
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .filter { !$0.path.hasPrefix(appURL.path + "/") }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Uninstall flow

    /// Asks once ("wirklich deinstallieren?"), quits the app if it is running, moves the app and
    /// all its leftovers to the Trash and confirms with "<App> erfolgreich deinstalliert".
    static func uninstall(_ entry: AppEntry) {
        let appURL = entry.url
        guard canUninstall(appURL) else { return }
        let bundleID = entry.bundleID ?? Bundle(url: appURL)?.bundleIdentifier

        NSApp.activate(ignoringOtherApps: true)
        let ask = NSAlert()
        ask.messageText = "„\(entry.name)“ wirklich deinstallieren?"
        ask.informativeText = "Die App und alle ihre Daten werden in den Papierkorb gelegt."
        ask.icon = NSWorkspace.shared.icon(forFile: appURL.path)
        ask.addButton(withTitle: "Deinstallieren")
        ask.addButton(withTitle: "Abbrechen")
        ask.buttons.first?.hasDestructiveAction = true
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        // The leftover scan touches many folders: do it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let items = [appURL] + leftovers(appURL: appURL, bundleID: bundleID)
            DispatchQueue.main.async {
                quitIfRunning(bundleID: bundleID) { ok in
                    guard ok else {
                        report("„\(entry.name)“ lässt sich nicht beenden.",
                               "Bitte beende die App selbst und versuche es dann erneut.")
                        return
                    }
                    moveToTrash(items) { failed in
                        if let id = bundleID { forget(bundleID: id) }
                        // Refresh taskbars and Start menus first, so the app is already gone behind
                        // the message.
                        NotificationCenter.default.post(name: didUninstallNotification, object: bundleID)
                        if failed.contains(appURL) {
                            report("„\(entry.name)“ konnte nicht deinstalliert werden.",
                                   "Die App ließ sich nicht in den Papierkorb legen.")
                        } else if !failed.isEmpty {
                            report("„\(entry.name)“ erfolgreich deinstalliert.",
                                   "Diese Daten konnten nicht in den Papierkorb gelegt werden:\n"
                                   + failed.map { $0.path }.joined(separator: "\n"))
                        } else {
                            report("„\(entry.name)“ erfolgreich deinstalliert.", "")
                        }
                    }
                }
            }
        }
    }

    private static func report(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// Quits all running instances (politely, up to 5 s). `done(true)` when none is left.
    private static func quitIfRunning(bundleID: String?, done: @escaping (Bool) -> Void) {
        guard let bundleID else { done(true); return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { done(true); return }
        running.forEach { $0.terminate() }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            waited += 0.25
            if running.allSatisfy({ $0.isTerminated }) { t.invalidate(); done(true) }
            else if waited >= 5 { t.invalidate(); done(false) }
        }
    }

    /// NSWorkspace.recycle first; items that need admin rights (e.g. in /Library or a root-owned
    /// app) go through the Finder, which asks for the password itself.
    private static func moveToTrash(_ urls: [URL], done: @escaping ([URL]) -> Void) {
        guard !urls.isEmpty else { done([]); return }
        NSWorkspace.shared.recycle(urls) { trashed, _ in
            let rest = urls.filter { trashed[$0] == nil && FileManager.default.fileExists(atPath: $0.path) }
            guard !rest.isEmpty else { done([]); return }
            let list = rest.map { "POSIX file \"\($0.path.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ", ")
            let script = "tell application \"Finder\" to delete {\(list)}"
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.launchPath = "/usr/bin/osascript"
                p.arguments = ["-e", script]
                try? p.run()
                p.waitUntilExit()
                DispatchQueue.main.async {
                    done(rest.filter { FileManager.default.fileExists(atPath: $0.path) })
                }
            }
        }
    }

    /// Removes the app from taskbar pins, Start menu pins and recents.
    private static func forget(bundleID: String) {
        PinStore.save(PinStore.load().filter { $0 != bundleID })
        if StartPins.isPinned(bundleID) { StartPins.toggle(bundleID) }
    }
}
