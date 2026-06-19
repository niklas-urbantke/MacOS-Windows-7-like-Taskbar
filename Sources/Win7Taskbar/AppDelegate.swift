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

        // Always the primary display (the one with the menu bar at origin 0,0) — not
        // NSScreen.main, which only tracks the screen of the active window.
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        if let primary {
            controllers.append(TaskbarController(screen: primary))
        }
    }
}
