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

    private var rebuildWork: DispatchWorkItem?

    @objc private func screensChanged() {
        // Plugging/unplugging a display fires this several times in quick succession, and the screen
        // list can be momentarily empty or half-populated mid-reconfiguration. Debounce so we rebuild
        // once, after the layout has settled — overlapping tear-downs/rebuilds were the crash.
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildForAllScreens() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func rebuildForAllScreens() {
        // The primary display (the one with the menu bar at origin 0,0) always gets a bar and
        // comes first; not NSScreen.main, which only tracks the screen of the active window.
        let screens = NSScreen.screens
        // During reconfiguration the list can be transiently empty — keep the current bars rather
        // than tearing everything down into nothing (the next notification rebuilds once settled).
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { return }

        controllers.forEach { $0.tearDown() }
        controllers.removeAll()
        controllers.append(TaskbarController(screen: primary, isPrimary: true))

        // Secondary displays (mirrored ones share the primary frame and are skipped).
        guard Theme.showOnAllScreens else { return }
        for screen in screens where screen.frame != primary.frame {
            controllers.append(TaskbarController(screen: screen, isPrimary: false))
        }
    }
}
