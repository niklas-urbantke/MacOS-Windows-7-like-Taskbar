import AppKit

/// One entry on the taskbar: either a pinned app, a running app, or both.
final class TaskbarItem {
    let key: String                  // bundleID if available, otherwise the path
    var name: String
    var icon: NSImage
    var url: URL?                    // launch target for pinned / not-running apps
    var runningApp: NSRunningApplication?
    var pinned: Bool
    var windowCount: Int = 1   // für die Win7-Stapel-Optik bei mehreren Fenstern

    init(key: String, name: String, icon: NSImage, url: URL?,
         runningApp: NSRunningApplication?, pinned: Bool) {
        self.key = key
        self.name = name
        self.icon = icon
        self.url = url
        self.runningApp = runningApp
        self.pinned = pinned
    }

    var isRunning: Bool { runningApp != nil && !(runningApp?.isTerminated ?? true) }
    var isActive: Bool { runningApp?.isActive ?? false }
}
