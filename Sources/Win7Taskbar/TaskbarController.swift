import AppKit

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
    private let startMenu = StartMenuController()
    private let reserver = WindowSpaceReserver()
    private let preview = WindowPreviewController()

    private var items: [TaskbarItem] = []
    private var buttons: [TaskbarButton] = []
    private var clockTimer: Timer?
    private var trayLeftX: CGFloat = 0
    private let hasBattery = SystemInfo.battery() != nil

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
        showDesktop.onClick = { [weak self] in self?.minimizeEverything() }
        clock.onClick = { [weak self] in self?.showCalendar() }
        volume.onClick = { [weak self] in self?.showVolume() }

        registerObservers()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(toggleStart),
            name: NSNotification.Name("de.batix.win7taskbar.toggleStart"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(testPreview),
            name: NSNotification.Name("de.batix.win7taskbar.testPreview"), object: nil)
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
        container.addSubview(blur)

        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        window.contentView = container
    }

    private func buildChrome() {
        let h = Theme.barHeight
        let w = glass.bounds.width

        orb.frame = NSRect(x: 0, y: 0, width: Theme.orbWidth, height: h)
        glass.addSubview(orb)

        // Right side, laid out from the edge inward: show-desktop | clock | volume | battery.
        var x = w
        x -= Theme.showDesktopWidth
        showDesktop.frame = NSRect(x: x, y: 0, width: Theme.showDesktopWidth, height: h)
        showDesktop.autoresizingMask = [.minXMargin]
        glass.addSubview(showDesktop)

        x -= Theme.clockWidth
        clock.frame = NSRect(x: x, y: 0, width: Theme.clockWidth, height: h)
        clock.autoresizingMask = [.minXMargin]
        glass.addSubview(clock)

        x -= Theme.volumeWidth
        volume.frame = NSRect(x: x, y: 0, width: Theme.volumeWidth, height: h)
        volume.autoresizingMask = [.minXMargin]
        glass.addSubview(volume)

        if hasBattery {
            x -= Theme.batteryWidth
            battery.frame = NSRect(x: x, y: 0, width: Theme.batteryWidth, height: h)
            battery.autoresizingMask = [.minXMargin]
            glass.addSubview(battery)
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

        items = newItems
        layoutButtons()
    }

    private func layoutButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        let startX = Theme.orbWidth + 4
        let endX = trayLeftX - 6
        let available = max(0, endX - startX)
        guard !items.isEmpty, available > 0 else { return }

        // Shrink button width when the bar is full, Win7-style.
        let ideal = Theme.buttonWidth + Theme.buttonSpacing
        let count = CGFloat(items.count)
        let perButton = min(ideal, available / count)
        let width = perButton - Theme.buttonSpacing
        let y = (Theme.barHeight - Theme.buttonHeight) / 2

        for (i, item) in items.enumerated() {
            let b = TaskbarButton(item: item)
            b.buttonDelegate = self
            b.frame = NSRect(x: startX + CGFloat(i) * perButton, y: y,
                             width: width, height: Theme.buttonHeight)
            glass.addSubview(b)
            buttons.append(b)
        }
    }

    // MARK: - TaskbarButtonDelegate

    func taskbarButtonClicked(_ item: TaskbarItem) {
        if let app = item.runningApp, !app.isTerminated {
            let pid = app.processIdentifier
            let s = WindowPreview.windowSummary(pid: pid)
            if s.visible > 0 {
                // Has open windows: toggle front/hide.
                if app.isActive { app.hide() }
                else { app.activate(options: [.activateAllWindows]) }
            } else if s.minimized > 0 {
                // Only minimised windows: restore them.
                WindowPreview.unminimizeAndRaise(pid: pid)
            } else {
                // Running but no windows: re-open to create a fresh window (like a Dock click).
                if let url = app.bundleURL ?? item.url {
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

        let dockTitle = DockHelper.isHidden ? "macOS-Dock wieder einblenden" : "macOS-Dock ausblenden"
        let dock = NSMenuItem(title: dockTitle, action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self
        menu.addItem(dock)

        let resTitle = reserver.enabled
            ? "Fensterbereich-Reservierung aus"
            : "Fensterbereich reservieren (Bedienungshilfen)"
        let res = NSMenuItem(title: resTitle, action: #selector(toggleReserve), keyEquivalent: "")
        res.target = self
        res.state = reserver.enabled ? .on : .off
        menu.addItem(res)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Taskleiste beenden", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        let p = NSPoint(x: orb.frame.minX, y: orb.frame.maxY)
        menu.popUp(positioning: nil, at: p, in: glass)
    }

    @objc private func toggleDock() { DockHelper.toggle() }

    @objc private func toggleReserve() {
        if reserver.enabled {
            reserver.disable()
        } else {
            let granted = reserver.enable()
            if !granted {
                let alert = NSAlert()
                alert.messageText = "Berechtigung Bedienungshilfen nötig"
                alert.informativeText = "Bitte aktiviere Win7Taskbar unter Systemeinstellungen → "
                    + "Datenschutz & Sicherheit → Bedienungshilfen und wähle den Menüpunkt danach erneut."
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

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
            self?.clock.refresh()
            self?.battery.refresh()
            self?.updateBarVisibility()
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

    @objc private func appsChanged() { rebuildItems() }

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
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
            .paragraphStyle: style,
        ]
        let timeStr = NSAttributedString(string: time, attributes: timeAttrs)
        let dateStr = NSAttributedString(string: date, attributes: dateAttrs)
        let w = bounds.width
        timeStr.draw(in: NSRect(x: 0, y: bounds.midY + 2, width: w, height: 19))
        dateStr.draw(in: NSRect(x: 0, y: bounds.midY - 17, width: w, height: 15))
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
