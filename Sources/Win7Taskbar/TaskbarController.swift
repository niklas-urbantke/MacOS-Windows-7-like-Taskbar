import AppKit
import ServiceManagement

/// Owns one taskbar window on a given screen and keeps it in sync with running apps.
/// With "show on all screens" there is one controller per display; the primary one (menu-bar
/// screen) owns everything that must exist only once (hotkeys, distributed notifications,
/// recents tracking, Dock-pin import). Settings setters apply to every registered controller.
final class TaskbarController: NSObject, TaskbarButtonDelegate {
    // MARK: - Registry (all live taskbars)

    private final class WeakRef {
        weak var value: TaskbarController?
        init(_ value: TaskbarController) { self.value = value }
    }
    private static var registry: [WeakRef] = []
    /// All live taskbars, the primary one first.
    static var allControllers: [TaskbarController] { registry.compactMap { $0.value } }
    /// Screens that currently show a taskbar (used by the window-space reserver).
    static var barScreens: [NSScreen] { allControllers.map { $0.screen } }
    private static var primaryController: TaskbarController? { allControllers.first { $0.isPrimary } }

    /// One settings window and one menu editor for all taskbars.
    private static let sharedSettings = SettingsWindowController()
    private static var menuEditor: MenuEditorWindowController?
    /// Dock pins are imported once per app launch (not per screen, not per screen rebuild).
    private static var didImportDockPins = false
    /// The user's custom (drag) order, shared so every taskbar shows the same order.
    private static var orderedKeys: [String] = []

    private let screen: NSScreen
    /// Primary taskbar (menu-bar screen): hotkeys, notifications, recents, media + performance.
    let isPrimary: Bool
    private let window: NSWindow
    private let glass = GlassBackgroundView()
    private let blur = NSVisualEffectView()
    private let orb = StartOrbButton()
    private let clock = ClockView()
    private let battery = BatteryView()
    private let volume = TrayIconButton(symbol: "speaker.wave.2.fill")
    private let showDesktop = ShowDesktopButton()
    private let nowPlayingView = NowPlayingView(frame: .zero)
    private let wifiView = WifiView(frame: .zero)
    private let monitorView = HardwareMonitorView(frame: .zero)
    private let startMenu = StartMenuController()
    private let startMenu11 = StartMenu11Controller()
    // Windows-11-Tray (ersetzt clock/volume/battery/wifi/monitor/nowPlaying im Win11-Profil).
    private let win11Clock = Win11ClockButton()
    private let win11Performance = Win11PerformanceView()
    private let win11Media = Win11MediaView()
    private var reserver: WindowSpaceReserver { WindowSpaceReserver.shared }
    private let preview = WindowPreviewController()

    private var items: [TaskbarItem] = []
    private var buttons: [TaskbarButton] = []
    private var clockTimer: Timer?
    private var trayLeftX: CGFloat = 0
    private let hasBattery = SystemInfo.battery() != nil
    private var hotkeyMonitors: [Any] = []
    private var hotkeyArmed = true
    private var tick = 0

    // Button layout geometry + drag state.
    private var buttonStartX: CGFloat = 0
    private var buttonPitch: CGFloat = 0
    private var buttonW: CGFloat = 0
    private var buttonY: CGFloat = 0
    private weak var draggingButton: TaskbarButton?
    private var dragOffsetX: CGFloat = 0

    private let volumePopover = NSPopover()

    init(screen: NSScreen, isPrimary: Bool) {
        self.screen = screen
        self.isPrimary = isPrimary
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: screen.frame.width, height: Theme.barHeight)
        // Non-activating panel: clicks are delivered immediately without first pulling the
        // bar into focus, so a single click works even when another app is active.
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        window = panel
        super.init()
        Self.registry.removeAll { $0.value == nil }
        Self.registry.append(WeakRef(self))

        configureWindow(frame: frame)
        buildChrome()
        startMenu.taskbarController = self
        startMenu11.taskbarController = self

        orb.target = self
        orb.action = #selector(toggleStart)
        orb.onRightClick = { [weak self] in self?.showOrbMenu() }
        startMenu.onVisibilityChanged = { [weak self] open in
            self?.orb.menuOpen = open
            if open {
                Win11Flyouts.closeAll()   // Startmenü und Medien-Flyout nie gleichzeitig
                self?.closeOtherStartMenus()
            }
        }
        startMenu11.onVisibilityChanged = { [weak self] open in
            self?.orb.menuOpen = open
            if open {
                Win11Flyouts.closeAll()   // Startmenü und Flyouts nie gleichzeitig
                self?.closeOtherStartMenus()
            }
        }
        showDesktop.onClick = { [weak self] in self?.minimizeEverything() }
        // Kalender nur auf dem Hauptbildschirm; auf Nebenleisten ist die Uhr nicht anklickbar.
        if isPrimary { clock.onClick = { [weak self] in self?.showCalendar() } }
        win11Clock.opensCalendar = isPrimary
        volume.onClick = { [weak self] in self?.showVolume() }
        glass.onDropFiles = { [weak self] urls in self?.pinDroppedFiles(urls) }

        registerObservers()
        if isPrimary {
            // Everything that must exist only once (otherwise it would fire once per screen).
            _ = WindowSpaceReserver.shared
            Self.sharedSettings.controller = self
            installHotkey()
            registerPrimaryObservers()
            if !Self.didImportDockPins {
                Self.didImportDockPins = true
                PinStore.importDockPins(includeReleased: false)
            }
            autoCheckUpdatesIfEnabled()
        }
        rebuildItems()
        startClock()

        window.orderFront(nil)
    }

    /// Distributed notifications (external triggers) and recents tracking: primary taskbar only.
    private func registerPrimaryObservers() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(toggleStartFromHotkey),
                        name: NSNotification.Name("de.batix.win7taskbar.toggleStart"), object: nil)
        dnc.addObserver(self, selector: #selector(testPreview),
                        name: NSNotification.Name("de.batix.win7taskbar.testPreview"), object: nil)
        dnc.addObserver(self, selector: #selector(openSettings),
                        name: NSNotification.Name("de.batix.win7taskbar.openSettings"), object: nil)
        dnc.addObserver(self, selector: #selector(openMenuEditorNotif),
                        name: NSNotification.Name("de.batix.win7taskbar.openEditor"), object: nil)
        dnc.addObserver(forName: NSNotification.Name("de.batix.win7taskbar.dumpWindows"),
                        object: nil, queue: .main) { _ in WindowPreview.dumpDiagnostics() }

        // Record recently opened apps for the Start menu.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(self, selector: #selector(recordRecent(_:)), name: name, object: nil)
        }
    }

    /// On start (if enabled), check for a newer version in the background and offer to update.
    private func autoCheckUpdatesIfEnabled() {
        guard UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true else { return }
        guard !UpdateManager.currentInfo().isDev else { return }
        DispatchQueue.global(qos: .utility).async {
            let r = UpdateManager.checkForUpdate(nil)
            guard r.updateAvailable else { return }
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Update verfügbar"
                a.informativeText = "Eine neuere Version der Taskleiste ist verfügbar (\(r.target.ref)). "
                    + "Jetzt aus der Quelle neu bauen und aktualisieren? Erteilte Berechtigungen bleiben erhalten."
                a.addButton(withTitle: "Jetzt aktualisieren")
                a.addButton(withTitle: "Später")
                if a.runModal() == .alertFirstButtonReturn { UpdateManager.runUpdate(r.target) }
            }
        }
    }

    /// Runs `body` on every live taskbar (settings apply to all screens).
    private static func forAll(_ body: (TaskbarController) -> Void) { allControllers.forEach(body) }

    /// Rebuild the button rows of all taskbars (after pin changes).
    private static func rebuildAllItems(except skip: TaskbarController? = nil) {
        forAll { if $0 !== skip { $0.rebuildItems() } }
    }

    /// Only one Start menu at a time across all screens.
    private func closeOtherStartMenus() {
        Self.forAll { c in
            guard c !== self else { return }
            c.startMenu.hide()
            c.startMenu11.hide()
        }
    }

    /// Media and performance views live on the primary taskbar only.
    private var showsMedia: Bool { isPrimary && nowPlayingEnabled }
    private var showsMonitor: Bool { isPrimary && monitorEnabled }

    // MARK: - Window & chrome

    private func configureWindow(frame: NSRect) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = false

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]

        blur.frame = container.bounds
        blur.autoresizingMask = [.width, .height]
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = Theme.nsAppearance
        container.addSubview(blur)

        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        applyAppearance()

        window.contentView = container
    }

    private func buildChrome() {
        let h = Theme.barHeight
        orb.frame = NSRect(x: 0, y: 0, width: Theme.orbWidth, height: h)
        glass.addSubview(orb)

        for v in [showDesktop, clock, volume] { v.autoresizingMask = [.minXMargin]; glass.addSubview(v) }
        if hasBattery { battery.autoresizingMask = [.minXMargin]; glass.addSubview(battery) }
        for v in [nowPlayingView, wifiView, monitorView] { v.autoresizingMask = [.minXMargin] }
        for v: NSView in [win11Clock, win11Performance, win11Media] {
            v.autoresizingMask = [.minXMargin]
        }

        layoutTray()
    }

    /// Positions the tray (right side) and the now-playing widget, then re-lays out the buttons.
    /// Each profile owns its own set of tray views; the other set is detached from the hierarchy.
    private func layoutTray() {
        if Theme.isWin11 {
            for v: NSView in [clock, volume, battery, wifiView, monitorView, nowPlayingView] { v.removeFromSuperview() }
            layoutTrayWin11()
        } else {
            for v: NSView in [win11Clock, win11Performance, win11Media] { v.removeFromSuperview() }
            for v: NSView in [clock, volume] where v.superview == nil { glass.addSubview(v) }
            if hasBattery && battery.superview == nil { glass.addSubview(battery) }
            layoutTrayClassic()
        }
        layoutButtons()
    }

    /// Windows 11 tray, right to left: show-desktop sliver, clock, performance, media.
    /// (No WLAN/volume/battery icons: macOS shows those in its menu bar.)
    private func layoutTrayWin11() {
        typealias W = Theme.Win11
        let h = Theme.barHeight
        let gap = W.s(4)
        var x = glass.bounds.width

        x -= W.showDesktopWidth
        showDesktop.frame = NSRect(x: x, y: 0, width: W.showDesktopWidth, height: h)
        if showDesktop.superview == nil { glass.addSubview(showDesktop) }

        func place(_ v: NSView, width: CGFloat) {
            x -= gap + width
            v.frame = NSRect(x: x, y: 0, width: width, height: h)
            if v.superview == nil { glass.addSubview(v) }
        }

        place(win11Clock, width: win11Clock.preferredWidth)
        win11Clock.refresh()

        if showsMonitor {
            place(win11Performance, width: win11Performance.preferredWidth)
            win11Performance.refresh()
        } else { win11Performance.removeFromSuperview() }

        if showsMedia {
            place(win11Media, width: win11Media.preferredWidth)
            win11Media.refresh()
        } else { win11Media.removeFromSuperview() }

        trayLeftX = x
    }

    /// Vista / Windows 7 tray.
    private func layoutTrayClassic() {
        let h = Theme.barHeight
        let gap: CGFloat = 10          // uniform spacing between tray elements
        var x = glass.bounds.width

        // Show-desktop sliver sits at the very edge; every other element gets a uniform gap.
        x -= Theme.showDesktopWidth
        showDesktop.frame = NSRect(x: x, y: 0, width: Theme.showDesktopWidth, height: h)

        func slot(_ width: CGFloat) -> NSRect {
            x -= gap + width
            return NSRect(x: x, y: 0, width: width, height: h)
        }

        clock.frame = slot(Theme.clockWidth)
        volume.frame = slot(Theme.volumeWidth)
        if hasBattery { battery.frame = slot(Theme.batteryWidth) }

        if wifiEnabled {
            wifiView.frame = slot(Theme.wifiWidth)
            if wifiView.superview == nil { glass.addSubview(wifiView) }
            wifiView.refresh()
        } else { wifiView.removeFromSuperview() }

        if showsMonitor {
            monitorView.frame = slot(Theme.monitorWidth)
            if monitorView.superview == nil { glass.addSubview(monitorView) }
            monitorView.refresh()
        } else { monitorView.removeFromSuperview() }

        if showsMedia {
            nowPlayingView.frame = slot(nowPlayingView.preferredWidth)
            if nowPlayingView.superview == nil { glass.addSubview(nowPlayingView) }
            nowPlayingView.refresh()
        } else {
            nowPlayingView.removeFromSuperview()
        }

        trayLeftX = x
    }

    // MARK: - Items

    private func rebuildItems() {
        let pinnedKeys = PinStore.load()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        var newItems: [TaskbarItem] = []
        var usedRunning = Set<pid_t>()

        // 1) Pinned apps first (in saved order), merged with a running instance if present.
        for key in pinnedKeys {
            let match = running.first { $0.bundleIdentifier == key }
            if let app = match { usedRunning.insert(app.processIdentifier) }
            // After an uninstall LaunchServices still finds the app in the Trash: treat that
            // (or a vanished file) as not installed, so the pin disappears right away.
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key).flatMap {
                !$0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            }
            let name = match?.localizedName ?? url.flatMap {
                ($0.lastPathComponent as NSString).deletingPathExtension
            } ?? key
            guard match != nil || url != nil else { continue }
            let icon = Self.largeArtIcon(match?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage())
            newItems.append(TaskbarItem(key: key, name: name, icon: icon, url: url,
                                        runningApp: match, pinned: true))
        }

        // 2) Remaining running apps that are not pinned.
        for app in running where !usedRunning.contains(app.processIdentifier) {
            let key = app.bundleIdentifier ?? app.bundleURL?.path ?? "\(app.processIdentifier)"
            let name = app.localizedName ?? "App"
            let icon = Self.largeArtIcon(app.icon ?? NSImage())
            newItems.append(TaskbarItem(key: key, name: name, icon: icon,
                                        url: app.bundleURL, runningApp: app, pinned: false))
        }

        // Preserve the user's custom (drag) order; append any new items at the end.
        // The order is shared, so every screen's taskbar shows the same sequence.
        let savedOrder = Self.orderedKeys
        var ordered: [TaskbarItem] = []
        for key in savedOrder {
            if let item = newItems.first(where: { $0.key == key }) { ordered.append(item) }
        }
        for item in newItems where !savedOrder.contains(item.key) { ordered.append(item) }
        // Pinned apps always come first; running apps that are not pinned stay on the right.
        ordered = ordered.filter { $0.pinned } + ordered.filter { !$0.pinned }

        // Custom Finder icon (this taskbar only), if the user set one.
        if let img = customFinderIcon() {
            for item in ordered where item.key == "com.apple.finder" { item.icon = img }
        }

        items = ordered
        Self.orderedKeys = items.map { $0.key }
        layoutButtons()
    }

    /// Some apps (Postman, Slack …) ship different artwork in their small icon sizes (up to 64 px).
    /// A 1x screen picks those for the taskbar size, a Retina screen the large ones, so the same app
    /// looked different per screen. Keep only the large representations (downscaled when drawn).
    private static func largeArtIcon(_ image: NSImage) -> NSImage {
        let large = image.representations.filter { $0.pixelsWide >= 128 }
        guard !large.isEmpty, large.count < image.representations.count else { return image }
        let icon = NSImage(size: image.size)
        icon.addRepresentations(large)
        return icon
    }

    // MARK: - Custom Finder icon (taskbar-only override)

    private var iconsDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Win7Taskbar/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func customFinderIcon() -> NSImage? {
        guard let p = UserDefaults.standard.string(forKey: "finderIconPath") else { return nil }
        return NSImage(contentsOfFile: p)
    }
    var hasCustomFinderIcon: Bool { UserDefaults.standard.string(forKey: "finderIconPath") != nil }
    func setFinderIcon(from src: URL) {
        let dest = iconsDir.appendingPathComponent("finderIcon")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            UserDefaults.standard.set(dest.path, forKey: "finderIconPath")
            Self.rebuildAllItems()
        } catch { NSLog("Finder-Icon setzen fehlgeschlagen: \(error)") }
    }
    func clearFinderIcon() {
        try? FileManager.default.removeItem(at: iconsDir.appendingPathComponent("finderIcon"))
        UserDefaults.standard.removeObject(forKey: "finderIconPath")
        Self.rebuildAllItems()
    }

    private func slotX(_ i: Int) -> CGFloat { buttonStartX + CGFloat(i) * buttonPitch }

    private func layoutButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        if Theme.isWin11 { layoutButtonsWin11(); return }

        // Vista/Win7: the orb sits fixed at the left edge.
        orb.frame = NSRect(x: 0, y: 0, width: Theme.orbWidth, height: Theme.barHeight)

        let startX = Theme.orbWidth + Theme.orbGap   // Abstand zwischen Orb und erstem Icon
        let endX = trayLeftX - 6
        let available = max(0, endX - startX)
        guard !items.isEmpty, available > 0 else { return }

        // Shrink button width when the bar is full, Win7-style.
        let ideal = Theme.buttonWidth + Theme.buttonSpacing
        let count = CGFloat(items.count)
        buttonStartX = startX
        buttonPitch = min(ideal, available / count)
        buttonW = buttonPitch - Theme.buttonSpacing
        // Windows 7 slots span the full bar height; Vista keeps the centred button height.
        let win7 = Theme.taskbarStyle == .win7
        let buttonH = win7 ? Theme.barHeight : Theme.buttonHeight
        buttonY = win7 ? 0 : (Theme.barHeight - Theme.buttonHeight) / 2

        for (i, item) in items.enumerated() {
            let b = TaskbarButton(item: item)
            b.buttonDelegate = self
            b.frame = NSRect(x: slotX(i), y: buttonY, width: buttonW, height: buttonH)
            glass.addSubview(b)
            buttons.append(b)
        }
        updateWindowCounts()
    }

    /// Windows 11: start button + app slots form ONE group, centred on the screen (or left-aligned),
    /// clamped so it never runs into the tray. Slots shrink when the bar gets full.
    private func layoutButtonsWin11() {
        typealias W = Theme.Win11
        let h = Theme.barHeight
        let leftBound: CGFloat = 12
        let rightBound = trayLeftX - 6
        let startW = W.startWidth
        let spacing = W.slotSpacing
        let idealPitch = W.slotWidth + spacing
        let n = CGFloat(items.count)

        // Pitch = slot + spacing; the group is start + n × pitch (spacing before each slot).
        let roomForSlots = max(0, rightBound - leftBound - startW)
        let pitch = n > 0 ? max(spacing + 1, min(idealPitch, roomForSlots / n)) : idealPitch
        let groupW = startW + n * pitch

        var groupX = leftBound
        if Theme.win11Centered {
            // Glass spans the whole screen width, so its midpoint is the screen centre.
            groupX = (glass.bounds.width - groupW) / 2
            groupX = min(groupX, rightBound - groupW)
            groupX = max(groupX, leftBound)
        }
        groupX = groupX.rounded()

        orb.frame = NSRect(x: groupX, y: 0, width: startW, height: h)

        guard !items.isEmpty else { return }
        buttonStartX = groupX + startW + spacing
        buttonPitch = pitch
        buttonW = pitch - spacing
        let slotH = min(h, W.slotHeight)
        buttonY = ((h - slotH) / 2).rounded()

        for (i, item) in items.enumerated() {
            let b = TaskbarButton(item: item)
            b.buttonDelegate = self
            b.frame = NSRect(x: slotX(i), y: buttonY, width: buttonW, height: slotH)
            glass.addSubview(b)
            buttons.append(b)
        }
        updateWindowCounts()
    }

    /// Asynchronously counts each running app's windows (AX) for the grouped "stacked" look.
    /// `allBars`: apply the result to every taskbar (all bars show the same apps, so the
    /// periodic count runs once on the primary bar instead of once per screen).
    private func updateWindowCounts(allBars: Bool = false) {
        let snapshot: [(String, pid_t)] = items.compactMap {
            guard let app = $0.runningApp, !app.isTerminated else { return nil }
            return ($0.key, app.processIdentifier)
        }
        guard !snapshot.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var counts: [String: Int] = [:]
            for (key, pid) in snapshot {
                let s = WindowPreview.windowSummary(pid: pid)
                counts[key] = s.visible + s.minimized
            }
            let badges = DockBadges.current()   // [appName: badge] (Slack/Teams unread …)
            DispatchQueue.main.async {
                guard let self else { return }
                let targets = allBars ? Self.allControllers : [self]
                for c in targets { c.applyWindowCounts(counts, badges: badges) }
            }
        }
    }

    private func applyWindowCounts(_ counts: [String: Int], badges: [String: String]) {
        var changed = false
        for item in items {
            if let c = counts[item.key], item.windowCount != c {
                item.windowCount = c; changed = true
            }
            let newBadge = badges[item.name]
            if item.badge != newBadge { item.badge = newBadge; changed = true }
        }
        if changed { buttons.forEach { $0.needsDisplay = true } }
    }

    // MARK: - TaskbarButtonDelegate

    func taskbarButtonClicked(_ item: TaskbarItem, button: TaskbarButton?) {
        if let app = item.runningApp, !app.isTerminated {
            let pid = app.processIdentifier

            // 1) Finder option has priority: always open a fresh window.
            if app.bundleIdentifier == "com.apple.finder" && Self.finderAlwaysNewWindow {
                openNewFinderWindow()
                return
            }
            // 2) Grouped app (several windows): show the previews so the user picks one.
            //    Only with the built-in preview; with DockDoor (already shown on hover) or no
            //    preview the click activates the app like a single-window one.
            if Theme.previewMode == .builtin, item.windowCount > 1, let button {
                taskbarButtonHover(item, button: button)
                return
            }
            if Theme.previewMode == .dockdoor { DockDoorBridge.hide() }
            // 3) Single window: toggle front/hide, restore, or open a new window.
            let s = WindowPreview.windowSummary(pid: pid)
            if s.visible > 0 {
                if app.isActive { app.hide() }
                else { app.activate(options: [.activateAllWindows]) }
            } else if s.minimized > 0 {
                WindowPreview.unminimizeAndRaise(pid: pid)
            } else {
                // No windows: open a fresh one. Finder needs the AppleScript route to
                // reliably open on the first click (its reopen is flaky).
                if app.bundleIdentifier == "com.apple.finder" {
                    openNewFinderWindow()
                } else if let url = app.bundleURL ?? item.url {
                    NSWorkspace.shared.open(url)
                } else {
                    app.activate(options: [.activateAllWindows])
                }
            }
        } else if let url = item.url {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// Pin apps dropped onto the bar (drag & drop).
    func pinDroppedFiles(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "app" {
            if let id = Bundle(url: url)?.bundleIdentifier { pinToTaskbar(bundleID: id) }
        }
    }

    /// Pin an app (by bundle id) to the taskbar — used from the Start menu.
    func pinToTaskbar(bundleID: String?) {
        guard let id = bundleID else { return }
        var keys = PinStore.load()
        if !keys.contains(id) { keys.append(id); PinStore.save(keys); Self.rebuildAllItems() }
    }

    func taskbarButtonToggledPin(_ item: TaskbarItem) {
        var keys = PinStore.load()
        if item.pinned {
            keys.removeAll { $0 == item.key }
            // Forget its slot, so the (still running) app moves to the far right.
            Self.orderedKeys.removeAll { $0 == item.key }
        } else if !keys.contains(item.key) {
            keys.append(item.key)
        }
        PinStore.save(keys)
        Self.rebuildAllItems()
    }

    /// Import the apps pinned in the macOS Dock again, including ones released here before.
    func importDockPins() {
        PinStore.importDockPins(includeReleased: true)
        Self.rebuildAllItems()
    }

    func taskbarButtonQuit(_ item: TaskbarItem) {
        if item.runningApp?.bundleIdentifier == "com.apple.finder" {
            // Never quit Finder — just close all its windows (keeps the desktop alive).
            let p = Process()
            p.launchPath = "/usr/bin/osascript"
            p.arguments = ["-e", "tell application \"Finder\" to close every window"]
            try? p.run()
        } else {
            item.runningApp?.terminate()
        }
    }

    func taskbarButtonMiddleClicked(_ item: TaskbarItem) {
        // Middle-click opens a new window / instance, like the Win7 taskbar.
        if let url = item.url { NSWorkspace.shared.open(url) }
    }

    func taskbarButtonHover(_ item: TaskbarItem, button: TaskbarButton) {
        guard let app = item.runningApp, !app.isTerminated else { return }
        let f = button.frame   // in glass (== window content) coordinates
        let anchor = NSRect(x: window.frame.minX + f.minX, y: window.frame.minY + f.minY,
                            width: f.width, height: f.height)
        let showBuiltin = { [weak self] in
            guard let self else { return }
            self.preview.show(pid: app.processIdentifier, appName: item.name, icon: item.icon,
                              anchorRect: anchor, screen: self.screen)
        }
        switch Theme.previewMode {
        case .builtin:
            showBuiltin()
        case .dockdoor:
            guard let bundleID = app.bundleIdentifier else { showBuiltin(); return }
            preview.scheduleHide()   // a built-in preview of a media app (see below) closes
            // DockDoor places its preview relative to the top of the frame, like above a Dock
            // icon: pass the full bar height so it sits just above the bar, not over it.
            let column = NSRect(x: anchor.minX, y: window.frame.minY,
                                width: anchor.width, height: window.frame.height)
            // For the playing media app DockDoor would only flash its media widget: the built-in
            // preview shows the app's real windows instead.
            DockDoorBridge.show(bundleID: bundleID, anchor: column, screen: screen,
                                mediaFallback: showBuiltin)
        case .off:
            break
        }
    }

    func taskbarButtonHoverEnded() {
        switch Theme.previewMode {
        case .builtin:
            preview.scheduleHide()
        case .dockdoor:
            // DockDoor hides its preview itself once the mouse is neither over the button nor over
            // the preview (so the mouse can move into it); only a not yet sent show is dropped.
            DockDoorBridge.cancelPending()
            preview.scheduleHide()
        case .off:
            break
        }
    }

    /// Closes the hover preview of this taskbar (built-in and DockDoor).
    private func hidePreviews() {
        preview.scheduleHide()
        if Theme.previewMode == .dockdoor { DockDoorBridge.hide() }
    }

    // MARK: - Drag reordering

    func taskbarButtonDragBegan(_ button: TaskbarButton, atX x: CGFloat) {
        draggingButton = button
        dragOffsetX = x - button.frame.minX
        hidePreviews()
        glass.addSubview(button)   // float above the others
    }

    func taskbarButtonDragged(_ button: TaskbarButton, toX x: CGFloat) {
        guard let from = buttons.firstIndex(of: button), buttonPitch > 0 else { return }

        // The dragged button follows the cursor (clamped to the row).
        let maxX = slotX(buttons.count - 1)
        let newX = max(buttonStartX, min(x - dragOffsetX, maxX))
        button.frame.origin.x = newX

        // Target slot from the dragged centre; shift the others out of the way (animated).
        var to = Int((newX - buttonStartX + buttonPitch / 2) / buttonPitch)
        to = max(0, min(buttons.count - 1, to))
        if to != from {
            let b = buttons.remove(at: from); buttons.insert(b, at: to)
            let it = items.remove(at: from); items.insert(it, at: to)
            Self.orderedKeys = items.map { $0.key }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for (i, bb) in buttons.enumerated() where bb !== button {
                    bb.animator().setFrameOrigin(NSPoint(x: slotX(i), y: buttonY))
                }
            }
        }
    }

    func taskbarButtonDragEnded(_ button: TaskbarButton) {
        defer { draggingButton = nil }
        guard let idx = buttons.firstIndex(of: button) else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            button.animator().setFrameOrigin(NSPoint(x: slotX(idx), y: buttonY))
        }
        // Persist the new order of pinned apps; the other screens' taskbars follow the new order
        // (this bar keeps its buttons so the settle animation is not cut off).
        PinStore.save(items.filter { $0.pinned }.map { $0.key })
        Self.rebuildAllItems(except: self)
    }

    /// Debug hook: show the preview for the first running app's button (used for testing).
    @objc private func testPreview() {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let button = buttons.first { $0.item.runningApp?.processIdentifier == frontPID }
            ?? buttons.first { $0.item.isRunning }
        if let button {
            DebugLog.log("testPreview -> \(button.item.name) pid=\(button.item.runningApp?.processIdentifier ?? -1)")
            taskbarButtonHover(button.item, button: button)
        } else {
            DebugLog.log("testPreview: kein laufender Button (buttons=\(buttons.count))")
        }
    }

    // MARK: - Start orb & show desktop

    /// Opens / closes the Start menu of THIS taskbar, on its own screen.
    @objc private func toggleStart() {
        let orbScreenRect = NSRect(x: window.frame.minX + orb.frame.minX,
                                   y: window.frame.minY + orb.frame.minY,
                                   width: orb.frame.width, height: orb.frame.height)
        if Theme.isWin11 {
            startMenu11.toggle(relativeTo: orbScreenRect, on: screen)
        } else {
            startMenu.toggle(relativeTo: orbScreenRect, on: screen)
        }
    }

    /// Hotkey / external trigger (primary only): an open Start menu closes, otherwise the menu
    /// opens on the taskbar of the screen under the mouse pointer.
    @objc private func toggleStartFromHotkey() {
        let all = Self.allControllers
        if let open = all.first(where: { $0.orb.menuOpen }) { open.toggleStart(); return }
        let mouse = NSEvent.mouseLocation
        let target = all.first { NSMouseInRect(mouse, $0.screen.frame, false) } ?? self
        target.toggleStart()
    }

    private func showOrbMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Einstellungen…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Taskleiste beenden", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: orb.frame.minX, y: orb.frame.maxY), in: glass)
    }

    /// One shared settings window, whichever taskbar opens it (its setters apply to all bars).
    @objc private func openSettings() {
        Self.sharedSettings.controller = self
        Self.sharedSettings.show()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Settings (used by the settings window; every setter applies to all taskbars)

    var dockIsHidden: Bool { DockHelper.isHidden }
    func setDockHidden(_ on: Bool) { if on != DockHelper.isHidden { DockHelper.toggle() } }

    var reserveEnabled: Bool { reserver.enabled }
    @discardableResult func setReserveEnabled(_ on: Bool) -> Bool {
        if on { return reserver.enable() }
        reserver.disable(); return true
    }

    static var finderAlwaysNewWindow: Bool { UserDefaults.standard.bool(forKey: "finderAlwaysNewWindow") }
    var finderNewWindow: Bool { Self.finderAlwaysNewWindow }
    func setFinderNewWindow(_ on: Bool) { UserDefaults.standard.set(on, forKey: "finderAlwaysNewWindow") }

    var nowPlayingEnabled: Bool { UserDefaults.standard.bool(forKey: "showNowPlaying") }
    func setShowNowPlaying(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "showNowPlaying")
        Self.forAll { $0.layoutTray() }
    }

    // WLAN-Symbol (Standard: an).
    var wifiEnabled: Bool {
        UserDefaults.standard.object(forKey: "showWifi") == nil ? true : UserDefaults.standard.bool(forKey: "showWifi")
    }
    func setShowWifi(_ on: Bool) { UserDefaults.standard.set(on, forKey: "showWifi"); Self.forAll { $0.layoutTray() } }

    // Hardware-Monitor (Standard: aus).
    var monitorEnabled: Bool { UserDefaults.standard.bool(forKey: "showMonitor") }
    func setShowMonitor(_ on: Bool) { UserDefaults.standard.set(on, forKey: "showMonitor"); Self.forAll { $0.layoutTray() } }

    // Finder-Desktopfenster ausblenden (Standard: an).
    var hideFinderDesktopEnabled: Bool {
        UserDefaults.standard.object(forKey: "hideFinderDesktop") == nil ? true : UserDefaults.standard.bool(forKey: "hideFinderDesktop")
    }
    func setHideFinderDesktop(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "hideFinderDesktop")
        updateWindowCounts(allBars: true)
    }

    // Uhr mit Sekunden (Standard: an). Die Win11-Uhr liest Theme.clockShowsSeconds selbst.
    var clockSeconds: Bool { Theme.clockShowsSeconds }
    func setClockSeconds(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "clockSeconds")
        Self.forAll { c in
            c.layoutTray()          // clock width depends on the seconds
            c.clock.refresh()
            c.win11Clock.refresh()
        }
    }

    // Fenstervorschau beim Hovern: "builtin" | "dockdoor" | "off" (gilt für alle Leisten).
    var previewMode: String { Theme.previewMode.rawValue }
    func setPreviewMode(_ raw: String) {
        guard let mode = Theme.PreviewMode(rawValue: raw) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "previewMode")
        // Offene Vorschauen beider Arten schließen, egal welche Art jetzt gilt.
        Self.forAll { $0.preview.scheduleHide() }
        DockDoorBridge.hide()
    }

    // Taskleiste auf allen Bildschirmen (Standard: an). Baut alle Leisten neu auf (AppDelegate).
    var showOnAllScreens: Bool { Theme.showOnAllScreens }
    func setShowOnAllScreens(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "allScreens")
        // Async: the rebuild tears down this controller, so let the current call finish first.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .taskbarRebuildScreens, object: nil)
        }
    }

    // Leistenhöhe (px), alles andere skaliert proportional mit.
    var barHeightValue: CGFloat { Theme.barHeight }
    var minBarHeight: CGFloat { Theme.minHeight }
    var maxBarHeight: CGFloat { Theme.maxHeight }
    func setBarHeight(_ h: CGFloat) {
        UserDefaults.standard.set(Double(h), forKey: "barHeight")
        Self.forAll { $0.applyBarHeight() }
    }
    /// Sets the bar height so the icons are exactly as large as the macOS Dock icons.
    func matchDockSize() {
        UserDefaults.standard.set(Double(Theme.Win11.recommendedBarHeight), forKey: "barHeight")
        Self.forAll { $0.applyBarHeight() }
    }
    private func applyBarHeight() {
        let f = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                       width: screen.frame.width, height: Theme.barHeight)
        window.setFrame(f, display: true)
        layoutTray()   // repositions tray, start button + buttons at the new scale
    }

    // Icon-Rahmenbreite (px, Standard 60).
    var iconWidthValue: CGFloat { Theme.iconWidthValue }
    var defaultIconWidth: CGFloat { Theme.defaultIconWidth }
    func setIconWidth(_ v: CGFloat) {
        UserDefaults.standard.set(Double(v), forKey: "iconWidth")
        Self.forAll { $0.applyBarHeight() }
    }

    // Abstand zwischen Orb und erstem Icon (px, Standard 20).
    var orbGapValue: CGFloat { Theme.orbGapValue }
    var defaultOrbGap: CGFloat { Theme.defaultOrbGap }
    func setOrbGap(_ v: CGFloat) {
        UserDefaults.standard.set(Double(v), forKey: "orbGap")
        Self.forAll { $0.applyBarHeight() }
    }

    // Icon-Rahmen über volle Höhe.
    var fullHeightIcons: Bool { UserDefaults.standard.bool(forKey: "fullHeightIcons") }
    func setFullHeightIcons(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "fullHeightIcons")
        Self.forAll { $0.buttons.forEach { $0.needsDisplay = true } }
    }

    // Startmenü-Stil: "accent" (Akzentfarbe) oder "aero" (Taskbar-Glas).
    var menuStyle: String { UserDefaults.standard.string(forKey: "menuStyle") ?? "accent" }
    func setMenuStyle(_ style: String) { UserDefaults.standard.set(style, forKey: "menuStyle") }

    // Editor für die rechte Spalte des Startmenüs (eine Instanz für alle Leisten).
    @objc private func openMenuEditorNotif() { openMenuEditor() }
    func openMenuEditor() {
        if Self.menuEditor == nil {
            let editor = MenuEditorWindowController()
            editor.onChange = { Self.forAll { $0.startMenu.reloadRightColumn() } }
            Self.menuEditor = editor
        }
        Self.menuEditor?.show()
    }

    // Taskleisten-Stil-Profil: "vista" (dunkles Glas), "win7" (helles Aero-Glas) oder "win11".
    var taskbarStyle: String { Theme.taskbarStyle.rawValue }
    func setTaskbarStyle(_ raw: String) {
        let d = UserDefaults.standard
        let old = Theme.taskbarStyle
        let style = Theme.TaskbarStyle(rawValue: raw) ?? .vista
        // Win11 kommt in Dock-Größe (Icons so groß wie im macOS-Dock); die bisherige Höhe wird
        // gemerkt und beim Zurückwechseln wiederhergestellt.
        if style == .win11 && old != .win11 {
            d.set(Double(Theme.barHeight), forKey: "barHeightBeforeWin11")
            d.set(Double(Theme.Win11.recommendedBarHeight), forKey: "barHeight")
        } else if style != .win11 && old == .win11 {
            if let h = d.object(forKey: "barHeightBeforeWin11") as? Double { d.set(h, forKey: "barHeight") }
            d.removeObject(forKey: "barHeightBeforeWin11")
        }
        d.set(style.rawValue, forKey: "taskbarStyle")
        if style != .win11 {
            // Apply the profile's recommended blur/opacity (the user can still fine-tune afterwards).
            d.set(Double(Theme.defaultBlur(for: style)), forKey: "taskbarBlur")
            d.set(Double(Theme.defaultOpacity(for: style)), forKey: "taskbarOpacity")
        }
        Win11Flyouts.closeAll()
        Self.forAll { $0.applyStyleChange() }
    }

    /// Applies a changed style profile to this taskbar (menus of the old profile close).
    private func applyStyleChange() {
        startMenu.hide()
        startMenu11.hide()
        hidePreviews()
        applyAppearance()
        applyBarHeight()
        reloadEverything()
        startMenu11.applyAppearance()
    }

    // Farbmodus aller Profile ("system" | "light" | "dark"), gespeichert unter dem bisherigen
    // Win11-Schlüssel.
    var win11Appearance: String { Theme.appearanceMode.rawValue }
    func setWin11Appearance(_ raw: String) {
        UserDefaults.standard.set(raw, forKey: "win11Appearance")
        Self.forAll { $0.applyColorModeChange() }
    }

    // Windows-11-Profil: Acryl-Transparenz (Standard: an).
    var win11Acrylic: Bool { Theme.win11Acrylic }
    func setWin11Acrylic(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "win11Acrylic")
        Self.forAll { $0.applyWin11Change() }
    }

    // Acryl je Fläche (Leiste, Startmenü, Flyouts): Frost und Tönung, jeweils 0…1.
    // Die Flyouts lesen ihre Werte beim Öffnen, deshalb werden offene geschlossen.
    func win11Frost(_ role: Theme.Win11.Surface) -> CGFloat { Theme.Win11.frost(role) }
    func win11Tint(_ role: Theme.Win11.Surface) -> CGFloat { Theme.Win11.tint(role) }
    func setWin11Frost(_ v: CGFloat, for role: Theme.Win11.Surface) {
        UserDefaults.standard.set(Double(v), forKey: "win11Frost.\(role.rawValue)")
        applyWin11Surface(role)
    }
    func setWin11Tint(_ v: CGFloat, for role: Theme.Win11.Surface) {
        UserDefaults.standard.set(Double(v), forKey: "win11Tint.\(role.rawValue)")
        applyWin11Surface(role)
    }
    private func applyWin11Surface(_ role: Theme.Win11.Surface) {
        switch role {
        case .bar:    Self.forAll { $0.applyAppearance(); $0.glass.needsDisplay = true }
        case .menu:   Self.forAll { $0.startMenu11.applyAppearance() }
        case .flyout: Win11Flyouts.closeAll()
        }
    }

    // Windows-11-Profil: Symbolausrichtung ("center" | "left").
    var win11Alignment: String { Theme.win11Centered ? "center" : "left" }
    func setWin11Alignment(_ raw: String) {
        UserDefaults.standard.set(raw == "left" ? "left" : "center", forKey: "win11Alignment")
        Self.forAll { $0.applyWin11Change() }
    }

    private func applyWin11Change() {
        applyAppearance()
        reloadEverything()
        startMenu11.applyAppearance()
    }

    /// Farbmodus oder Akzentfarbe geändert: Leiste, beide Startmenüs und offene Popover neu anwenden
    /// (in jedem Profil, auch das gerade nicht sichtbare Startmenü bleibt so aktuell).
    private func applyColorModeChange() {
        applyWin11Change()
        startMenu.applyAppearance()
        volumePopover.appearance = Theme.nsAppearance
    }

    /// Full visual reload — rebuild the button row and redraw all chrome (used on theme switch).
    private func reloadEverything() {
        glass.needsDisplay = true
        orb.reloadOrb()
        orb.needsDisplay = true
        showDesktop.needsDisplay = true
        layoutTray()        // relays out tray + buttons (button height depends on the theme)
        rebuildItems()      // recreate the taskbar buttons fresh
        glass.subviews.forEach { $0.needsDisplay = true }
    }

    // Win7-Icon-Glas-Stärke (0…1).
    var win7GlassStrength: CGFloat { Theme.win7GlassStrength }
    func setWin7GlassStrength(_ v: CGFloat) {
        UserDefaults.standard.set(Double(v), forKey: "win7GlassStrength")
        Self.forAll { $0.buttons.forEach { $0.needsDisplay = true } }
    }

    // Transparenz / Unschärfe der Taskleiste (jeweils 0…1).
    var taskbarBlur: CGFloat { Theme.taskbarBlur }
    var taskbarOpacity: CGFloat { Theme.taskbarOpacity }
    func setTaskbarBlur(_ v: CGFloat) {
        UserDefaults.standard.set(Double(v), forKey: "taskbarBlur"); Self.forAll { $0.applyAppearance() }
    }
    func setTaskbarOpacity(_ v: CGFloat) {
        UserDefaults.standard.set(Double(v), forKey: "taskbarOpacity"); Self.forAll { $0.applyAppearance() }
    }
    private func applyAppearance() {
        if Theme.isWin11 {
            // Win11: Acryl-Blur nach Farbmodus (versteckt bei ausgeschaltetem Acryl), Fläche voll deckend
            // gezeichnet (die Deckkraft steckt schon in Theme.Win11.surface).
            Theme.Win11.configureBlur(blur, for: .bar)
            glass.alphaValue = 1
            window.appearance = Theme.win11NSAppearance   // Kontextmenüs folgen dem Farbmodus
        } else {
            // Vista/Win7: Frost-Schicht und Kontextmenüs folgen dem Farbmodus (hell = helles Glas).
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.appearance = Theme.nsAppearance
            blur.isHidden = false
            blur.alphaValue = Theme.taskbarBlur
            glass.alphaValue = Theme.taskbarOpacity
            window.appearance = Theme.nsAppearance
        }
    }

    // Transparenz / Unschärfe des Startmenüs (jeweils 0…1), an das Startmenü weitergereicht.
    var menuBlur: CGFloat { Theme.menuBlur }
    var menuOpacity: CGFloat { Theme.menuOpacity }
    func setMenuBlur(_ v: CGFloat) {
        UserDefaults.standard.set(Double(v), forKey: "menuBlur"); Self.forAll { $0.startMenu.applyAppearance() }
    }
    func setMenuOpacity(_ v: CGFloat) {
        UserDefaults.standard.set(Double(v), forKey: "menuOpacity"); Self.forAll { $0.startMenu.applyAppearance() }
    }

    // Start-Orb-Auswahl.
    var availableOrbs: [(label: String, file: String)] { OrbCatalog.available().map { ($0.label, $0.file) } }
    var selectedOrbFile: String { OrbCatalog.selectedFile }
    func setOrb(_ file: String) { OrbCatalog.select(file); Self.forAll { $0.orb.reloadOrb() } }

    /// Import a PNG as a new orb; returns its filename (and applies it).
    func addOrb(from url: URL) -> String? {
        guard let file = OrbCatalog.importOrb(from: url) else { return nil }
        setOrb(file)
        return file
    }
    func openOrbsFolder() { NSWorkspace.shared.open(OrbCatalog.userDir) }

    // Autostart via SMAppService.
    var autostartEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setAutostart(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Autostart: \(error)") }
    }

    private func openNewFinderWindow() {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", "tell application \"Finder\"",
                       "-e", "activate",
                       "-e", "make new Finder window",
                       "-e", "end tell"]
        try? p.run()
    }

    private func minimizeEverything() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            app.hide()
        }
    }

    // MARK: - Clock

    private func startClock() {
        if Theme.isWin11 {
            win11Clock.refresh()
        } else {
            clock.refresh()
            battery.refresh()
        }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateBarVisibility()
            self.tick += 1
            // Window counts / badges: counted once (primary) and applied to every taskbar.
            if self.isPrimary && self.tick % 2 == 0 { self.updateWindowCounts(allBars: true) }
            if Theme.isWin11 {
                // Only the Win11 tray views are in the hierarchy in this profile.
                self.win11Clock.refresh()
                if self.showsMonitor && self.tick % 2 == 0 { self.win11Performance.refresh() }
                if self.showsMedia && self.tick % 2 == 0 { self.win11Media.refresh() }
            } else {
                self.clock.refresh()
                self.battery.refresh()
                if self.wifiEnabled && self.tick % 5 == 0 { self.wifiView.refresh() }
                if self.showsMonitor && self.tick % 2 == 0 { self.monitorView.refresh() }
                if self.showsMedia && self.tick % 3 == 0 { self.nowPlayingView.refresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    // MARK: - Calendar flyout & volume popover

    /// Kalender-Flyout (wie im Win11-Profil, gezeichnet im Aero-Stil), rechtsbündig über der Uhr.
    private func showCalendar() {
        guard let anchor = Win11TrayDraw.screenRect(of: clock, clock.bounds),
              let screen = Win11TrayDraw.screen(of: clock) else { return }
        Win11Flyouts.showCalendar(anchor: anchor, screen: screen)
    }

    private func showVolume() {
        if volumePopover.isShown { volumePopover.close(); return }
        let vc = VolumePopoverVC()
        volumePopover.contentViewController = vc
        volumePopover.behavior = .transient
        volumePopover.appearance = Theme.nsAppearance
        volumePopover.show(relativeTo: volume.bounds, of: volume, preferredEdge: .maxY)
    }

    // MARK: - Observers

    private func registerObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            nc.addObserver(self, selector: #selector(appsChanged), name: name, object: nil)
        }
        // Hide the bar when an app goes into native full screen (its own Space).
        for name: NSNotification.Name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            nc.addObserver(self, selector: #selector(updateBarVisibility), name: name, object: nil)
        }

        // Hell/Dunkel-Wechsel von macOS (Farbmodus "System" folgt ihm) und Akzentfarben-Wechsel.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(interfaceThemeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(interfaceThemeChanged),
            name: NSNotification.Name("AppleColorPreferencesChangedNotification"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged),
            name: NSColor.systemColorsDidChangeNotification, object: nil)
        // An app was uninstalled from the Start menu: its pin is gone, rebuild the button row.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appUninstalled),
            name: AppUninstaller.didUninstallNotification, object: nil)
    }

    @objc private func appUninstalled() { rebuildItems() }

    @objc private func interfaceThemeChanged() {
        // AppleInterfaceStyle is updated slightly after the notification arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.systemColorsChanged() }
    }

    @objc private func systemColorsChanged() {
        // Every profile follows the colour mode ("System" tracks macOS) and the accent colour.
        applyColorModeChange()
    }

    @objc private func appsChanged() {
        guard draggingButton == nil else { return }   // don't relayout mid-drag
        rebuildItems()
    }

    // MARK: - Global hotkey (fn/Globe + Control toggles the Start menu)

    private func installHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let want = self.modifierHotkeyMask()
            guard !want.isEmpty else { self.hotkeyArmed = true; return }
            let have = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if have == want {
                if self.hotkeyArmed { self.hotkeyArmed = false; self.toggleStartFromHotkey() }
            } else {
                self.hotkeyArmed = true
            }
        }
        // Global (other apps focused) + local (our menu focused).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            hotkeyMonitors.append(g)
        }
        let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event); return event
        }
        if let l { hotkeyMonitors.append(l) }

        // Ctrl + 1…9 activates / launches the n-th pinned app (Win-key style).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] in self?.handleNumberHotkey($0) }) {
            hotkeyMonitors.append(g)
        }

        // User-configurable Start-menu shortcut (key + modifiers), in addition to fn+Control.
        let startKey: (NSEvent) -> Void = { [weak self] in self?.handleStartHotkey($0) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: startKey) {
            hotkeyMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { startKey($0); return $0 }) {
            hotkeyMonitors.append(l)
        }
    }

    /// The modifier-only Start shortcut: the configured one (keyCode == -1) or the fn+Control default.
    private func modifierHotkeyMask() -> NSEvent.ModifierFlags {
        if let kc = UserDefaults.standard.object(forKey: "startHotkeyKeyCode") as? Int, kc == -1 {
            return NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "startHotkeyMods")))
                .intersection([.command, .option, .control, .shift, .function])
        }
        return [.control, .function]   // Standard: fn + Strg
    }

    private func handleStartHotkey(_ event: NSEvent) {
        guard let kc = UserDefaults.standard.object(forKey: "startHotkeyKeyCode") as? Int, kc >= 0 else { return }
        let want = NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "startHotkeyMods")))
            .intersection([.command, .option, .control, .shift])
        let have = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if Int(event.keyCode) == kc && have == want { toggleStartFromHotkey() }
    }

    // Konfigurierbares Startmenü-Tastenkürzel.
    var startHotkeyLabel: String { UserDefaults.standard.string(forKey: "startHotkeyLabel") ?? "fn + ⌃ (Standard)" }
    func setStartHotkey(keyCode: Int, mods: UInt, label: String) {
        let d = UserDefaults.standard
        d.set(keyCode, forKey: "startHotkeyKeyCode")
        d.set(Int(mods), forKey: "startHotkeyMods")
        d.set(label, forKey: "startHotkeyLabel")
    }
    func clearStartHotkey() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "startHotkeyKeyCode")
        d.removeObject(forKey: "startHotkeyMods")
        d.removeObject(forKey: "startHotkeyLabel")
    }

    private func handleNumberHotkey(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods == [.control],
              let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n)
        else { return }
        let pinned = items.filter { $0.pinned }
        guard n - 1 < pinned.count else { return }
        taskbarButtonClicked(pinned[n - 1], button: nil)
    }

    // MARK: - Full-screen handling

    /// True when this taskbar's screen is occupied by a window that covers the whole display
    /// (native full-screen), detected via window geometry, no special permission needed.
    /// Per screen: a full-screen app on one monitor only hides that monitor's taskbar.
    private func isFullscreenActive() -> Bool {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        else { return false }
        // CG window bounds use global top-left coordinates (origin at the primary screen's top-left).
        let f = screen.frame
        let sx = f.minX, sy = primary.frame.height - f.maxY, sw = f.width, sh = f.height

        // On displays with a camera notch macOS places full-screen windows below the notch (top =
        // safe-area inset), so they look like a maximised window. A full-screen Space is then told
        // apart by the Finder desktop window missing on this display (it is there on every normal
        // Space, unless the Finder desktop is switched off).
        let safeTop = screen.safeAreaInsets.top
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        var belowNotch = false
        var desktopVisible = false
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = b["X"] ?? 0, y = b["Y"] ?? 0
            let ww = b["Width"] ?? 0, hh = b["Height"] ?? 0
            let coversScreenBelowTop = x <= sx + 1 && x + ww >= sx + sw - 1 && y + hh >= sy + sh - 1
            if layer < 0 {
                // Finder's desktop window (negative desktop level) spanning this display.
                if (w[kCGWindowOwnerName as String] as? String) == "Finder", coversScreenBelowTop, y <= sy + 1 {
                    desktopVisible = true
                }
                continue
            }
            guard layer == 0, coversScreenBelowTop else { continue }   // ordinary app windows only
            if y <= sy + 1 { return true }                                  // classic full screen
            if safeTop > 0 && y <= sy + safeTop + 1 { belowNotch = true }   // candidate on notch display
        }
        return belowNotch && !desktopVisible
    }

    @objc private func updateBarVisibility() {
        // Toggle visibility via alpha (not orderOut/orderFront) so the window keeps its level,
        // position and all-Spaces membership and reliably reappears after full screen.
        let fullscreen = isFullscreenActive()
        window.ignoresMouseEvents = fullscreen
        let target: CGFloat = fullscreen ? 0 : 1
        if window.alphaValue != target { window.alphaValue = target }
        if !fullscreen && !window.isVisible { window.orderFront(nil) }

        // The Space transition can briefly still report full screen; re-check shortly after.
        if !fullscreen { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isFullscreenActive() else { return }
            self.window.ignoresMouseEvents = false
            self.window.alphaValue = 1
            if !self.window.isVisible { self.window.orderFront(nil) }
        }
    }

    @objc private func recordRecent(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.activationPolicy == .regular {
            RecentsStore.record(app)
        }
    }

    // MARK: - Teardown

    func tearDown() {
        clockTimer?.invalidate()
        clockTimer = nil
        hotkeyMonitors.forEach { NSEvent.removeMonitor($0) }
        hotkeyMonitors.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        startMenu.hide()
        startMenu11.hide()
        Win11Flyouts.closeAll()
        preview.scheduleHide()
        if volumePopover.isShown { volumePopover.close() }
        Self.registry.removeAll { $0.value == nil || $0.value === self }
        window.orderOut(nil)
    }
}

// MARK: - Clock view

private final class ClockView: NSView {
    var onClick: (() -> Void)?
    private var hovering = false
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "HH:mm"
        return f
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()
    private var time = ""
    private var date = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    // Hover-Feld nur, wenn die Uhr anklickbar ist (auf Nebenleisten öffnet sie keinen Kalender).
    override func mouseEntered(with event: NSEvent) { hovering = onClick != nil; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    func refresh() {
        let now = Date()
        let format = Theme.clockShowsSeconds ? "HH:mm:ss" : "HH:mm"
        if timeFormatter.dateFormat != format { timeFormatter.dateFormat = format }
        time = timeFormatter.string(from: now)
        date = dateFormatter.string(from: now)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering { ClassicTray.fillHover(bounds.insetBy(dx: 2, dy: 6)) }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(14, weight: .medium),
            .foregroundColor: ClassicTray.text,
            .paragraphStyle: style,
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(14, weight: .medium),   // same size as the time
            .foregroundColor: ClassicTray.pick(NSColor(calibratedWhite: 0.92, alpha: 1), Theme.Aero.text),
            .paragraphStyle: style,
        ]
        let timeStr = NSAttributedString(string: time, attributes: timeAttrs)
        let dateStr = NSAttributedString(string: date, attributes: dateAttrs)
        let w = bounds.width
        timeStr.draw(in: NSRect(x: 0, y: bounds.midY + Theme.s(2), width: w, height: Theme.s(19)))
        dateStr.draw(in: NSRect(x: 0, y: bounds.midY - Theme.s(19), width: w, height: Theme.s(19)))
    }
}

// MARK: - Show desktop button (far-right sliver)

private final class ShowDesktopButton: NSView {
    var onClick: (() -> Void)?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if Theme.isWin11 {
            // Win11: invisible until hovered, then a faint field with a 1-px line on the left.
            guard hovering else { return }
            Theme.Win11.hoverFill.setFill()
            bounds.fill(using: .sourceOver)
            Theme.Win11.hairline.setFill()
            NSRect(x: bounds.minX, y: 0, width: 1, height: bounds.height).fill(using: .sourceOver)
            return
        }
        if Theme.taskbarStyle == .win7 {
            let name = hovering ? "desktopPointerOver" : "desktopNormal"
            ThemeAssets.image(name)?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        if hovering {
            ClassicTray.pick(NSColor(calibratedWhite: 1, alpha: 0.18), Theme.Aero.hover).setFill()
            bounds.fill()
        }
        ClassicTray.pick(NSColor(calibratedWhite: 1, alpha: 0.35), Theme.Aero.stroke).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: bounds.minX + 0.5, y: 4))
        line.line(to: NSPoint(x: bounds.minX + 0.5, y: bounds.height - 4))
        line.lineWidth = 1
        line.stroke()
    }
}

// MARK: - Battery indicator

private final class BatteryView: NSView {
    private var info: SystemInfo.Battery?

    func refresh() { info = SystemInfo.battery(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let info else { return }
        // Percentage text.
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(12, weight: .medium),
            .foregroundColor: ClassicTray.text, .paragraphStyle: style,
        ]
        let s = NSAttributedString(string: "\(info.percent)%", attributes: attrs)
        s.draw(in: NSRect(x: 0, y: bounds.midY - 16, width: bounds.width, height: 15))

        // Battery glyph.
        let bodyW: CGFloat = 26, bodyH: CGFloat = 12
        let bx = (bounds.width - bodyW) / 2, by = bounds.midY + 3
        let body = NSRect(x: bx, y: by, width: bodyW, height: bodyH)
        let outline = ClassicTray.pick(NSColor(calibratedWhite: 1, alpha: 0.85), Theme.Aero.secondaryText)
        outline.setStroke()
        let bp = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2); bp.lineWidth = 1.2; bp.stroke()
        // Cap.
        outline.setFill()
        NSRect(x: body.maxX, y: by + 3, width: 2, height: bodyH - 6).fill()
        // Fill level.
        let level = max(0, min(1, CGFloat(info.percent) / 100))
        let fillColor = info.charging ? NSColor.systemGreen
            : (info.percent <= 20 ? NSColor.systemRed : ClassicTray.pick(Theme.accent(brightness: 1.2), Theme.Aero.accent))
        fillColor.setFill()
        NSRect(x: bx + 2, y: by + 2, width: (bodyW - 4) * level, height: bodyH - 4).fill()
        if info.charging {
            let bolt = NSAttributedString(string: "⚡︎", attributes: [
                .font: Theme.font(9), .foregroundColor: ClassicTray.text])
            bolt.draw(at: NSPoint(x: bx + bodyW / 2 - 4, y: by + 1))
        }
    }
}

// MARK: - Generic tray icon button (e.g. volume)

private final class TrayIconButton: NSView {
    var onClick: (() -> Void)?
    private let symbol: String
    private var hovering = false

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering { ClassicTray.fillHover(bounds.insetBy(dx: 1, dy: 8)) }
        let cfg = NSImage.SymbolConfiguration(pointSize: 16 * Theme.scale, weight: .regular)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let tinted = ClassicTray.tinted(img, ClassicTray.text)
            let s = tinted.size
            tinted.draw(in: NSRect(x: (bounds.width - s.width) / 2,
                                   y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }
}

// MARK: - Volume popover

private final class VolumePopoverVC: NSViewController {
    private let slider = NSSlider()
    private let muteButton = NSButton()

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 200))

        slider.minValue = 0
        slider.maxValue = 100
        slider.isVertical = true
        slider.intValue = Int32(SystemInfo.outputVolume())
        slider.target = self
        slider.action = #selector(changed)
        slider.frame = NSRect(x: 30, y: 44, width: 20, height: 140)
        v.addSubview(slider)

        muteButton.title = SystemInfo.isMuted() ? "🔇" : "🔊"
        muteButton.bezelStyle = .rounded
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        muteButton.frame = NSRect(x: 20, y: 8, width: 40, height: 28)
        v.addSubview(muteButton)

        self.view = v
    }

    @objc private func changed() {
        SystemInfo.setVolume(Int(slider.intValue))
        if SystemInfo.isMuted() && slider.intValue > 0 { SystemInfo.setMuted(false) }
    }

    @objc private func toggleMute() {
        let newMuted = !SystemInfo.isMuted()
        SystemInfo.setMuted(newMuted)
        muteButton.title = newMuted ? "🔇" : "🔊"
    }
}
