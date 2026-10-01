import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TaskbarController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockHelper.applyHiddenByDefaultOnce()
        rebuildForAllScreens()

        // Recreate bars when the screen layout changes (resolution, plugging a monitor, …).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // … and when the "show on all screens" setting changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: .taskbarRebuildScreens,
            object: nil
        )
    }

    @objc private func screensChanged() {
        rebuildForAllScreens()
    }

    private func rebuildForAllScreens() {
        controllers.forEach { $0.tearDown() }
        controllers.removeAll()

        // The primary display (the one with the menu bar at origin 0,0) always gets a bar and
        // comes first; not NSScreen.main, which only tracks the screen of the active window.
        let screens = NSScreen.screens
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { return }
        controllers.append(TaskbarController(screen: primary, isPrimary: true))

        // Secondary displays (mirrored ones share the primary frame and are skipped).
        guard Theme.showOnAllScreens else { return }
        for screen in screens where screen.frame != primary.frame {
            controllers.append(TaskbarController(screen: screen, isPrimary: false))
        }
    }
}
