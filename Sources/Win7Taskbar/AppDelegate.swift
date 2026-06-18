import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TaskbarController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildForAllScreens()

        // Recreate bars when the screen layout changes (resolution, plugging a monitor, …).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        rebuildForAllScreens()
    }

    private func rebuildForAllScreens() {
        controllers.forEach { $0.tearDown() }
        controllers.removeAll()

        // One taskbar on the main screen. (Multi-monitor: change to NSScreen.screens.)
        if let screen = NSScreen.main {
            controllers.append(TaskbarController(screen: screen))
        }
    }
}
