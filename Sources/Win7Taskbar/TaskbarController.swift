import AppKit
import ServiceManagement

/// Owns one taskbar window on a given screen and keeps it in sync with running apps.
final class TaskbarController: NSObject, TaskbarButtonDelegate {
    private let screen: NSScreen
    private let window: NSWindow
    private let glass = GlassBackgroundView()
    private let orb = StartOrbButton()
    private let clock = ClockView()
    private let battery = BatteryView()
    private let volume = TrayIconButton(symbol: "speaker.wave.2.fill")
    private let showDesktop = ShowDesktopButton()
    private let nowPlayingView = NowPlayingView(frame: .zero)
    private let wifiView = WifiView(frame: .zero)
    private let monitorView = HardwareMonitorView(frame: .zero)
    private let startMenu = StartMenuController()
    private let reserver = WindowSpaceReserver()
    private let preview = WindowPreviewController()
    private let settings = SettingsWindowController()

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
    private var orderedKeys: [String] = []

    private let calendarPopover = NSPopover()
    private let volumePopover = NSPopover()

    init(screen: NSScreen) {
        self.screen = screen
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: screen.frame.width, height: Theme.barHeight)
        window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()

        configureWindow(frame: frame)
        buildChrome()
        startMenu.taskbarController = self

        orb.target = self
        orb.action = #selector(toggleStart)
        orb.onRightClick = { [weak self] in self?.showOrbMenu() }
        startMenu.onVisibilityChanged = { [weak self] open in self?.orb.menuOpen = open }
        showDesktop.onClick = { [weak self] in self?.minimizeEverything() }
        clock.onClick = { [weak self] in self?.showCalendar() }
        volume.onClick = { [weak self] in self?.showVolume() }

        registerObservers()
        installHotkey()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(toggleStart),
            name: NSNotification.Name("de.batix.win7taskbar.toggleStart"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(testPreview),
            name: NSNotification.Name("de.batix.win7taskbar.testPreview"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openSettings),
            name: NSNotification.Name("de.batix.win7taskbar.openSettings"), object: nil)
        rebuildItems()
        startClock()

        window.orderFront(nil)
    }

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

        let blur = NSVisualEffectView(frame: container.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.alphaValue = 0.55   // weniger Blur: Frost-Schicht halbdurchlässig
        container.addSubview(blur)

        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        window.contentView = container
    }

    private func buildChrome() {
        let h = Theme.barHeight
        orb.frame = NSRect(x: 0, y: 0, width: Theme.orbWidth, height: h)
        glass.addSubview(orb)

        for v in [showDesktop, clock, volume] { v.autoresizingMask = [.minXMargin]; glass.addSubview(v) }
        if hasBattery { battery.autoresizingMask = [.minXMargin]; glass.addSubview(battery) }
        for v in [nowPlayingView, wifiView, monitorView] { v.autoresizingMask = [.minXMargin] }

        layoutTray()
    }

    /// Positions the tray (right side) and the now-playing widget, then re-lays out the buttons.
    private func layoutTray() {
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

        if monitorEnabled {
            monitorView.frame = slot(Theme.monitorWidth)
            if monitorView.superview == nil { glass.addSubview(monitorView) }
            monitorView.refresh()
        } else { monitorView.removeFromSuperview() }

        if nowPlayingEnabled {
            nowPlayingView.frame = slot(Theme.nowPlayingWidth)
            if nowPlayingView.superview == nil { glass.addSubview(nowPlayingView) }
            nowPlayingView.refresh()
        } else {
            nowPlayingView.removeFromSuperview()
        }

        trayLeftX = x
        layoutButtons()
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
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)
            let name = match?.localizedName ?? url.flatMap {
                ($0.lastPathComponent as NSString).deletingPathExtension
            } ?? key
            guard match != nil || url != nil else { continue }
            let icon = match?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage()
            newItems.append(TaskbarItem(key: key, name: name, icon: icon, url: url,
                                        runningApp: match, pinned: true))
        }

        // 2) Remaining running apps that are not pinned.
        for app in running where !usedRunning.contains(app.processIdentifier) {
            let key = app.bundleIdentifier ?? app.bundleURL?.path ?? "\(app.processIdentifier)"
            let name = app.localizedName ?? "App"
            let icon = app.icon ?? NSImage()
            newItems.append(TaskbarItem(key: key, name: name, icon: icon,
                                        url: app.bundleURL, runningApp: app, pinned: false))
        }

        // Preserve the user's custom (drag) order; append any new items at the end.
        var ordered: [TaskbarItem] = []
        for key in orderedKeys {
            if let item = newItems.first(where: { $0.key == key }) { ordered.append(item) }
        }
        for item in newItems where !orderedKeys.contains(item.key) { ordered.append(item) }

        items = ordered
        orderedKeys = items.map { $0.key }
        layoutButtons()
    }

    private func slotX(_ i: Int) -> CGFloat { buttonStartX + CGFloat(i) * buttonPitch }

    private func layoutButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        let startX = Theme.orbWidth + 14   // Abstand zwischen Orb und erstem Icon
        let endX = trayLeftX - 6
        let available = max(0, endX - startX)
        guard !items.isEmpty, available > 0 else { return }

        // Shrink button width when the bar is full, Win7-style.
        let ideal = Theme.buttonWidth + Theme.buttonSpacing
        let count = CGFloat(items.count)
        buttonStartX = startX
        buttonPitch = min(ideal, available / count)
        buttonW = buttonPitch - Theme.buttonSpacing
        buttonY = (Theme.barHeight - Theme.buttonHeight) / 2

        for (i, item) in items.enumerated() {
            let b = TaskbarButton(item: item)
            b.buttonDelegate = self
            b.frame = NSRect(x: slotX(i), y: buttonY, width: buttonW, height: Theme.buttonHeight)
            glass.addSubview(b)
            buttons.append(b)
        }
        updateWindowCounts()
    }

    /// Asynchronously counts each running app's windows (AX) for the grouped "stacked" look.
    private func updateWindowCounts() {
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
            DispatchQueue.main.async {
                guard let self else { return }
                var changed = false
                for item in self.items where counts[item.key] != nil {
                    if item.windowCount != counts[item.key] {
                        item.windowCount = counts[item.key]!
                        changed = true
                    }
                }
                if changed { self.buttons.forEach { $0.needsDisplay = true } }
            }
        }
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
            if item.windowCount > 1, let button {
                taskbarButtonHover(item, button: button)
                return
            }
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

    func taskbarButtonToggledPin(_ item: TaskbarItem) {
        var keys = PinStore.load()
        if item.pinned {
            keys.removeAll { $0 == item.key }
        } else if !keys.contains(item.key) {
            keys.append(item.key)
        }
        PinStore.save(keys)
        rebuildItems()
    }

    func taskbarButtonQuit(_ item: TaskbarItem) {
        item.runningApp?.terminate()
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
        preview.show(pid: app.processIdentifier, appName: item.name, icon: item.icon,
                     anchorRect: anchor, screen: screen)
    }

    func taskbarButtonHoverEnded() {
        preview.scheduleHide()
    }

    // MARK: - Drag reordering

    func taskbarButtonDragBegan(_ button: TaskbarButton, atX x: CGFloat) {
        draggingButton = button
        dragOffsetX = x - button.frame.minX
        preview.scheduleHide()
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
            orderedKeys = items.map { $0.key }
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
        // Persist the new order of pinned apps.
        PinStore.save(items.filter { $0.pinned }.map { $0.key })
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

    @objc private func toggleStart() {
        let orbScreenRect = NSRect(x: window.frame.minX + orb.frame.minX,
                                   y: window.frame.minY + orb.frame.minY,
                                   width: orb.frame.width, height: orb.frame.height)
        startMenu.toggle(relativeTo: orbScreenRect, on: screen)
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

    @objc private func openSettings() {
        settings.controller = self
        settings.show()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Settings (used by the settings window)

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
        layoutTray()
    }

    // WLAN-Symbol (Standard: an).
    var wifiEnabled: Bool {
        UserDefaults.standard.object(forKey: "showWifi") == nil ? true : UserDefaults.standard.bool(forKey: "showWifi")
    }
    func setShowWifi(_ on: Bool) { UserDefaults.standard.set(on, forKey: "showWifi"); layoutTray() }

    // Hardware-Monitor (Standard: aus).
    var monitorEnabled: Bool { UserDefaults.standard.bool(forKey: "showMonitor") }
    func setShowMonitor(_ on: Bool) { UserDefaults.standard.set(on, forKey: "showMonitor"); layoutTray() }

    // Finder-Desktopfenster ausblenden (Standard: an).
    var hideFinderDesktopEnabled: Bool {
        UserDefaults.standard.object(forKey: "hideFinderDesktop") == nil ? true : UserDefaults.standard.bool(forKey: "hideFinderDesktop")
    }
    func setHideFinderDesktop(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "hideFinderDesktop")
        updateWindowCounts()
    }

    // Icon-Rahmen über volle Höhe.
    var fullHeightIcons: Bool { UserDefaults.standard.bool(forKey: "fullHeightIcons") }
    func setFullHeightIcons(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "fullHeightIcons")
        buttons.forEach { $0.needsDisplay = true }
    }

    // Startmenü-Stil: "accent" (Akzentfarbe) oder "aero" (Taskbar-Glas).
    var menuStyle: String { UserDefaults.standard.string(forKey: "menuStyle") ?? "accent" }
    func setMenuStyle(_ style: String) { UserDefaults.standard.set(style, forKey: "menuStyle") }

    // Start-Orb-Auswahl.
    var availableOrbs: [(label: String, file: String)] { OrbCatalog.available().map { ($0.label, $0.file) } }
    var selectedOrbFile: String { OrbCatalog.selectedFile }
    func setOrb(_ file: String) { OrbCatalog.select(file); orb.reloadOrb() }

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
        clock.refresh()
        battery.refresh()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.clock.refresh()
            self.battery.refresh()
            self.updateBarVisibility()
            self.tick += 1
            if self.tick % 2 == 0 { self.updateWindowCounts() }
            if self.wifiEnabled && self.tick % 5 == 0 { self.wifiView.refresh() }
            if self.monitorEnabled && self.tick % 2 == 0 { self.monitorView.refresh() }
            if self.nowPlayingEnabled && self.tick % 3 == 0 { self.nowPlayingView.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    // MARK: - Popovers (calendar & volume)

    private func showCalendar() {
        if calendarPopover.isShown { calendarPopover.close(); return }
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.dateValue = Date()
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.sizeToFit()

        let vc = NSViewController()
        let pad: CGFloat = 12
        let container = NSView(frame: picker.frame.insetBy(dx: -pad, dy: -pad))
        picker.setFrameOrigin(NSPoint(x: pad, y: pad))
        container.addSubview(picker)
        vc.view = container

        calendarPopover.contentViewController = vc
        calendarPopover.behavior = .transient
        calendarPopover.show(relativeTo: clock.bounds, of: clock, preferredEdge: .maxY)
    }

    private func showVolume() {
        if volumePopover.isShown { volumePopover.close(); return }
        let vc = VolumePopoverVC()
        volumePopover.contentViewController = vc
        volumePopover.behavior = .transient
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
        // Record recently opened apps for the Start menu.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(self, selector: #selector(recordRecent(_:)), name: name, object: nil)
        }
        // Hide the bar when an app goes into native full screen (its own Space).
        for name: NSNotification.Name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            nc.addObserver(self, selector: #selector(updateBarVisibility), name: name, object: nil)
        }
    }

    @objc private func appsChanged() {
        guard draggingButton == nil else { return }   // don't relayout mid-drag
        rebuildItems()
    }

    // MARK: - Global hotkey (fn/Globe + Control toggles the Start menu)

    private func installHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let f = event.modifierFlags
            let bothDown = f.contains(.control) && f.contains(.function)
            if bothDown && self.hotkeyArmed {
                self.hotkeyArmed = false
                self.toggleStart()
            } else if !bothDown {
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

    /// True when the frontmost Space is occupied by a window that covers the whole display
    /// (native full-screen) — detected via window geometry, no special permission needed.
    private func isFullscreenActive() -> Bool {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        else { return false }
        let sw = primary.frame.width, sh = primary.frame.height

        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }                       // ordinary app windows only
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = b["X"] ?? 0, y = b["Y"] ?? 0
            let ww = b["Width"] ?? 0, hh = b["Height"] ?? 0
            if x <= 0 && y <= 0 && ww >= sw - 1 && hh >= sh - 1 { return true }
        }
        return false
    }

    @objc private func updateBarVisibility() {
        let fullscreen = isFullscreenActive()
        if fullscreen && window.isVisible {
            window.orderOut(nil)
        } else if !fullscreen && !window.isVisible {
            window.orderFront(nil)
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
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        startMenu.hide()
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
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    func refresh() {
        let now = Date()
        time = timeFormatter.string(from: now)
        date = dateFormatter.string(from: now)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.accent(brightness: 1.2, alpha: 0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 6), xRadius: 4, yRadius: 4).fill()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),   // same size as the time
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
            .paragraphStyle: style,
        ]
        let timeStr = NSAttributedString(string: time, attributes: timeAttrs)
        let dateStr = NSAttributedString(string: date, attributes: dateAttrs)
        let w = bounds.width
        timeStr.draw(in: NSRect(x: 0, y: bounds.midY + 2, width: w, height: 19))
        dateStr.draw(in: NSRect(x: 0, y: bounds.midY - 19, width: w, height: 19))
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
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
            bounds.fill()
        }
        NSColor(calibratedWhite: 1, alpha: 0.35).setStroke()
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
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white, .paragraphStyle: style,
        ]
        let s = NSAttributedString(string: "\(info.percent)%", attributes: attrs)
        s.draw(in: NSRect(x: 0, y: bounds.midY - 16, width: bounds.width, height: 15))

        // Battery glyph.
        let bodyW: CGFloat = 26, bodyH: CGFloat = 12
        let bx = (bounds.width - bodyW) / 2, by = bounds.midY + 3
        let body = NSRect(x: bx, y: by, width: bodyW, height: bodyH)
        NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
        let bp = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2); bp.lineWidth = 1.2; bp.stroke()
        // Cap.
        NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
        NSRect(x: body.maxX, y: by + 3, width: 2, height: bodyH - 6).fill()
        // Fill level.
        let level = max(0, min(1, CGFloat(info.percent) / 100))
        let fillColor = info.charging ? NSColor.systemGreen
            : (info.percent <= 20 ? NSColor.systemRed : Theme.accent(brightness: 1.2))
        fillColor.setFill()
        NSRect(x: bx + 2, y: by + 2, width: (bodyW - 4) * level, height: bodyH - 4).fill()
        if info.charging {
            let bolt = NSAttributedString(string: "⚡︎", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.white])
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
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.accent(brightness: 1.2, alpha: 0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 8), xRadius: 4, yRadius: 4).fill()
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
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
