import AppKit

/// Toggles the real macOS Dock between visible and "effectively hidden"
/// (auto-hide with a very long reveal delay), so our taskbar can own the bottom edge.
enum DockHelper {
    private static func run(_ launchPath: String, _ args: [String]) {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    static var isHidden: Bool {
        let p = Process()
        p.launchPath = "/usr/bin/defaults"
        p.arguments = ["read", "com.apple.dock", "autohide-delay"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let s = String(data: data, encoding: .utf8),
           let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return v > 100
        }
        return false
    }

    static func hideDock() {
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-time-modifier", "-float", "0"])
        run("/usr/bin/killall", ["Dock"])
    }

    static func showDock() {
        run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
        run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-time-modifier"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"])
        run("/usr/bin/killall", ["Dock"])
    }

    static func toggle() {
        if isHidden { showDock() } else { hideDock() }
    }
}
