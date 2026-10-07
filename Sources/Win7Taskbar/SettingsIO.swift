import AppKit

/// Export/import all settings into a single file so nothing is lost on reinstall.
/// The file is a property list (handles every UserDefaults type incl. Data natively) with a custom
/// extension; it bundles the app's UserDefaults domain plus the user's extra files (custom orbs and
/// the custom Finder icon).
enum SettingsIO {
    static let fileExtension = "win7taskbar"

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "de.batix.win7taskbar" }
    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Win7Taskbar", isDirectory: true)
    }

    /// Serialize all settings (+ extra files) to a property-list file.
    static func makeExportData() -> Data? {
        let defaults = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        var files: [String: Data] = [:]
        // Custom orbs.
        let orbs = appSupport.appendingPathComponent("orbs", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(at: orbs, includingPropertiesForKeys: nil) {
            for f in items where f.pathExtension.lowercased() == "png" {
                if let d = try? Data(contentsOf: f) { files["orbs/\(f.lastPathComponent)"] = d }
            }
        }
        // Custom Finder icon.
        if let d = try? Data(contentsOf: appSupport.appendingPathComponent("icons/finderIcon")) {
            files["icons/finderIcon"] = d
        }
        let payload: [String: Any] = [
            "format": "win7taskbar-settings",
            "version": 1,
            "exportedAt": Date(),
            "defaults": defaults,
            "files": files,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }

    /// Restore settings (+ extra files) from a property-list file. Returns false on a bad file.
    @discardableResult
    static func importData(_ data: Data) -> Bool {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any],
              let defaults = dict["defaults"] as? [String: Any] else { return false }

        for (key, value) in defaults { UserDefaults.standard.set(value, forKey: key) }

        if let files = dict["files"] as? [String: Data] {
            for (rel, bytes) in files {
                // Keep paths inside our Application Support folder (no "..").
                let safe = rel.replacingOccurrences(of: "..", with: "")
                let dest = appSupport.appendingPathComponent(safe)
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? bytes.write(to: dest)
            }
        }
        return true
    }

    /// Quit and reopen the app so every imported setting takes effect cleanly.
    static func relaunchApp() {
        let appPath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done
        sleep 0.4
        open \(shQuote(appPath))
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("win7taskbar-relaunch.sh")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "nohup /bin/bash \"$0\" >/dev/null 2>&1 &", url.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
