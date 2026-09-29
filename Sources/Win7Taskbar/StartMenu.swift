import AppKit
import Collaboration

/// Windows-7-style two-column Start menu: white program list on the left,
/// blue "places & power" panel on the right, with a search box and avatar.
final class StartMenuController: NSObject, NSTextFieldDelegate {
    private let window: NSWindow
    private let root = FlippedView()
    private let scrollView = NSScrollView()
    private let searchField = NSTextField()
    private let tint = ColumnTintView(frame: .zero)
    private let blur = NSVisualEffectView()
    private let avatar = AvatarView(frame: .zero)
    private let hoverIcon = NSImageView(frame: .zero)   // action icon shown at the avatar spot on hover
    private let listDoc = FlippedView()        // manual-layout document view (fast for long lists)
    private var listY: CGFloat = 0
    private var allApps: [AppEntry] = []
    private var showingAll = false
    private var alleButton: LeftRowButton?
    private let fileSearch = StartMenuFileSearch()
    private var firstResult: AppEntry?
    var onVisibilityChanged: ((Bool) -> Void)?
    weak var taskbarController: TaskbarController?

    private let W = Theme.startWidth
    private let H = Theme.startHeight
    private let leftW = Theme.startLeftWidth
    private let overhang: CGFloat = 50   // wie weit der Avatar oben rausragt

    override init() {
        window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.startWidth, height: Theme.startHeight + 50),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .transient]

        buildContent()

        NotificationCenter.default.addObserver(
            self, selector: #selector(resignedKey),
            name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appUninstalled),
            name: AppUninstaller.didUninstallNotification, object: nil)
    }

    /// An app was uninstalled: rescan so it disappears from the list right away.
    @objc private func appUninstalled() {
        allApps = AppScanner.installedApps()
        reloadList(filter: searchField.stringValue)
    }

    /// Farbmodus (Hell/Dunkel), Transparenz (Tönung) und Unschärfe (Frost-Schicht) aus den
    /// Einstellungen anwenden und alles neu zeichnen. Wird beim Öffnen und bei jeder Änderung aufgerufen.
    func applyAppearance() {
        window.appearance = Theme.nsAppearance   // Kontextmenüs und Symbole folgen dem Farbmodus
        blur.appearance = Theme.nsAppearance
        blur.alphaValue = Theme.menuBlur
        tint.alphaValue = Theme.menuOpacity
        root.layer?.borderColor = MenuPalette.outerBorder.cgColor
        if let content = window.contentView { Self.markDirty(content) }
    }

    private static func markDirty(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(markDirty)
    }

    // MARK: - Layout

    private func buildContent() {
        // Outer holder is taller than the menu; the menu sits at the bottom, leaving a
        // transparent strip on top into which the avatar pokes out.
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H + overhang))

        root.frame = NSRect(x: 0, y: 0, width: W, height: H)   // bottom-aligned in outer
        root.wantsLayer = true
        root.layer?.cornerRadius = 9
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1

        // Frosted glass background (like the taskbar): blur + semi-transparent column tint.
        blur.frame = root.bounds
        blur.autoresizingMask = [.width, .height]
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        root.addSubview(blur)

        tint.frame = root.bounds
        tint.autoresizingMask = [.width, .height]
        root.addSubview(tint)

        buildLeftColumn()
        buildRightColumn()

        outer.addSubview(root)

        // Avatar straddling the top edge of the menu — half above (in the transparent strip).
        let avatarSize: CGFloat = 99
        avatar.frame = NSRect(x: leftW + (W - leftW - avatarSize) / 2,
                              y: H - avatarSize / 2, width: avatarSize, height: avatarSize)
        avatar.onClick = { [weak self] in self?.perform(MenuEntryStore.avatarAction()) }
        outer.addSubview(avatar)

        // Action icon overlay: shown at the avatar's spot (same size, no frame) while hovering a
        // right-column action.
        hoverIcon.frame = avatar.frame
        hoverIcon.imageScaling = .scaleProportionallyUpOrDown
        hoverIcon.isHidden = true
        outer.addSubview(hoverIcon)

        window.contentView = outer
        applyAppearance()
    }

    private func buildLeftColumn() {
        // Scrollable program list.
        let bottomBlock: CGFloat = 108
        scrollView.frame = NSRect(x: 12, y: 12, width: leftW - 24, height: H - bottomBlock - 18)
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        // The program list is always white, so its scroller keeps the light look in both modes.
        scrollView.verticalScroller?.appearance = NSAppearance(named: .aqua)

        listDoc.frame = NSRect(x: 0, y: 0, width: leftW - 24, height: 10)
        scrollView.documentView = listDoc
        root.addSubview(scrollView)

        // "Alle Programme" / "Zurück" toggle row.
        let alle = LeftRowButton(title: "Alle Programme", bold: false, arrow: true) { [weak self] in
            self?.toggleAllPrograms()
        }
        alle.frame = NSRect(x: 12, y: H - bottomBlock + 6, width: leftW - 24, height: 30)
        root.addSubview(alle)
        alleButton = alle

        // Light-blue search band at the bottom of the white panel, with a soft shadow + line at its
        // top edge (the transition from the white list area).
        let band = SearchPanelBandView(frame: NSRect(x: 10, y: H - 66, width: leftW - 20, height: 56))
        root.addSubview(band)

        // Search field with a custom Win7 frame: white background, subtle recessed top shading
        // and a light blue-grey border. The borderless text field sits on top (centred in the band).
        let fieldRect = NSRect(x: 14, y: H - 53, width: leftW - 28, height: 30)
        let searchBG = SearchBackgroundView(frame: fieldRect)
        root.addSubview(searchBG)

        searchField.frame = NSRect(x: fieldRect.minX + 7, y: fieldRect.midY - 9, width: fieldRect.width - 34, height: 18)
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Programme/Dateien durchsuchen",
            attributes: [.foregroundColor: NSColor(srgbRed: 0x70/255, green: 0x70/255, blue: 0x70/255, alpha: 1),
                         .font: NSFont.systemFont(ofSize: 13)])
        searchField.delegate = self
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.textColor = .black
        searchField.focusRingType = .none
        searchField.appearance = NSAppearance(named: .aqua)   // sits on the white field in both modes
        root.addSubview(searchField)

        let mag = NSImageView(frame: NSRect(x: fieldRect.maxX - 24, y: fieldRect.midY - 8.5, width: 17, height: 17))
        mag.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Suche")
        mag.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        mag.contentTintColor = NSColor(srgbRed: 0.20, green: 0.47, blue: 0.78, alpha: 1)
        root.addSubview(mag)
    }

    private func buildRightColumn() {
        let innerX = leftW + 20
        let innerW = (W - leftW) - 38

        // (Avatar is added in buildContent so it can overhang the top edge.)
        buildRightEntries()

        // Shut-down split button (Windows-7 silver style), bottom-right.
        // Two flush halves that share one continuous top/bottom edge: the
        // "Herunterfahren" part is rounded on the left only, the arrow on the
        // right only, so together they read as a single split button.
        let arrowW: CGFloat = 26
        let shutW: CGFloat = innerW - 4 - arrowW
        let shut = Win7Button(title: "Herunterfahren")
        shut.roundRight = false
        shut.onClick = { [weak self] in self?.shutdownAction() }
        shut.frame = NSRect(x: innerX, y: H - 52, width: shutW, height: 28)
        root.addSubview(shut)

        let arrow = Win7Button(title: "▶")
        arrow.roundLeft = false
        arrow.frame = NSRect(x: innerX + shutW, y: H - 52, width: arrowW, height: 28)
        arrow.onClick = { [weak self, weak arrow] in if let a = arrow { self?.showPowerMenu(from: a) } }
        root.addSubview(arrow)
    }

    /// Rebuild the configurable right-column entries (called on edit). The locked username row
    /// is always first; the rest come from `MenuEntryStore`.
    func reloadRightColumn() { buildRightEntries() }

    private var rightEntryViews: [NSView] = []

    private func buildRightEntries() {
        rightEntryViews.forEach { $0.removeFromSuperview() }
        rightEntryViews = []

        let innerX = leftW + 20
        let innerW = (W - leftW) - 38

        // (title, gapBefore, separatorBefore, bold, action)
        var rows: [(String, Bool, Bool, Bool, MenuAction)] = []
        rows.append((displayUserName(), false, false, true, MenuAction(.home)))   // gesperrt
        for e in MenuEntryStore.entries() {
            rows.append((e.title, e.gapBefore, e.separatorBefore, false, e.action))
        }

        var y: CGFloat = 64
        for (title, gap, sep, bold, action) in rows {
            if gap {
                y += 12
                if sep { rightEntryViews.append(contentsOf: addSeparator(at: y - 7, x: innerX, width: innerW)) }
            }
            let row = RightRowButton(title: title, bold: bold,
                                     action: { [weak self] in self?.perform(action) })
            row.onHover = { [weak self] entered in
                guard let self else { return }
                if entered { self.showActionIcon(action) } else { self.hideActionIcon() }
            }
            row.frame = NSRect(x: innerX, y: y, width: innerW, height: 40)
            root.addSubview(row)
            rightEntryViews.append(row)
            y += 40
        }
    }

    private func displayUserName() -> String {
        UserDefaults.standard.bool(forKey: "demoMode")
            ? "Max Mustermann"
            : (NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
    }

    /// A subtle engraved separator line (dark + light) in the right column.
    @discardableResult
    private func addSeparator(at y: CGFloat, x: CGFloat, width: CGFloat) -> [NSView] {
        let line = SeparatorView(frame: NSRect(x: x, y: y, width: width, height: 2))
        root.addSubview(line)
        return [line]
    }

    // MARK: - Data

    private func toggleAllPrograms() {
        showingAll.toggle()
        alleButton?.setTitle(showingAll ? "Zurück" : "Alle Programme", back: showingAll)
        reloadList(filter: searchField.stringValue)
    }

    // MARK: - List layout (manual, for speed)

    private func resetList() {
        listDoc.subviews.forEach { $0.removeFromSuperview() }
        listY = 0
    }

    private func appendRow(_ view: NSView, height: CGFloat) {
        let w = scrollView.contentSize.width
        view.frame = NSRect(x: 0, y: listY, width: w, height: height)
        view.autoresizingMask = [.width]
        listDoc.addSubview(view)
        listY += height
        listDoc.frame = NSRect(x: 0, y: 0, width: w, height: max(listY, scrollView.contentSize.height))
    }

    private func makeAppRow(_ app: AppEntry, file: Bool) -> AppRowButton {
        let row = AppRowButton(entry: app,
                               pinned: file ? false : StartPins.isPinned(app.bundleID),
                               onOpen: { [weak self] e in
                                   if file { StartMenuLaunch.open(e, isFile: true); self?.hide() }
                                   else { self?.launch(e) }
                               },
                               onTogglePin: { [weak self] e in
                                   StartPins.toggle(e.bundleID)
                                   self?.reloadList(filter: self?.searchField.stringValue ?? "")
                               },
                               onPinTaskbar: file ? nil : { [weak self] e in
                                   self?.taskbarController?.pinToTaskbar(bundleID: e.bundleID)
                                   self?.hide()
                               })
        if let cached = StartMenuIcons.cached(app.url.path) { row.iconImage = cached }
        return row
    }

    /// Load missing icons off the main thread, then apply + cache (shared cache).
    private func loadIcons(_ pending: [(AppRowButton, String)]) {
        StartMenuIcons.load(pending.map { ($0.0 as StartMenuIconDisplaying, $0.1) })
    }

    private func reloadList(filter: String) {
        resetList()
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()

        let apps: [AppEntry]
        if !needle.isEmpty {
            apps = allApps.filter { $0.name.lowercased().contains(needle) }
        } else if showingAll {
            apps = allApps
        } else {
            let pinned = StartPins.entries()
            let pinnedIDs = Set(pinned.compactMap { $0.bundleID })
            let recents = RecentsStore.recent().filter { !pinnedIDs.contains($0.bundleID ?? "") }
            apps = pinned + recents
        }

        firstResult = apps.first
        var pending: [(AppRowButton, String)] = []
        for app in apps.prefix(300) {
            let row = makeAppRow(app, file: false)
            if row.iconImage == nil { pending.append((row, app.url.path)) }
            appendRow(row, height: 50)
        }
        loadIcons(pending)

        // When searching, also look for files & folders via Spotlight (async).
        if needle.count >= 2 {
            searchFiles(filter.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - File & folder search (Spotlight)

    private func searchFiles(_ query: String) {
        fileSearch.search(query, isCurrent: { [weak self] q in
            self?.searchField.stringValue.trimmingCharacters(in: .whitespaces) == q
        }, completion: { [weak self] results in
            self?.appendFileResults(results)
        })
    }

    private func appendFileResults(_ entries: [AppEntry]) {
        guard !entries.isEmpty else { return }
        let header = NSTextField(labelWithString: "  Dateien & Ordner")
        header.font = NSFont.boldSystemFont(ofSize: 11)
        header.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        appendRow(header, height: 22)
        var pending: [(AppRowButton, String)] = []
        for e in entries {
            let row = makeAppRow(e, file: true)
            if row.iconImage == nil { pending.append((row, e.url.path)) }
            appendRow(row, height: 50)
        }
        loadIcons(pending)
    }

    // MARK: - Show / hide

    func toggle(relativeTo orbScreenRect: NSRect, on screen: NSScreen) {
        if window.isVisible { hide() } else { show(relativeTo: orbScreenRect, on: screen) }
    }

    func show(relativeTo orbScreenRect: NSRect, on screen: NSScreen) {
        allApps = AppScanner.installedApps()
        showingAll = false
        hideActionIcon()
        alleButton?.setTitle("Alle Programme", back: false)
        searchField.stringValue = ""
        applyAppearance()   // reflect a possible style or colour-mode change
        reloadList(filter: "")

        let x = max(screen.frame.minX, orbScreenRect.minX)
        let y = orbScreenRect.maxY + 1
        let finalOrigin = NSPoint(x: x, y: y)

        NSApp.activate(ignoringOtherApps: true)

        // Always sits above the taskbar (no positional slide → never overlaps the bar).
        window.setFrameOrigin(finalOrigin)
        if reduceMotion {
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
        } else {
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 1
            }
        }
        window.makeFirstResponder(searchField)
        onVisibilityChanged?(true)
    }

    func hide() {
        guard window.isVisible else { return }
        onVisibilityChanged?(false)
        if reduceMotion {
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window.orderOut(nil)
            self?.window.alphaValue = 1   // reset for next open
        })
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    @objc private func resignedKey() { hide() }

    func controlTextDidChange(_ obj: Notification) { reloadList(filter: searchField.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), let entry = firstResult {
            launch(entry)
            return true
        }
        return false
    }

    // MARK: - Actions

    private func launch(_ entry: AppEntry) {
        StartMenuLaunch.launch(entry)
        hide()
    }

    private func openPath(_ path: String) {
        StartMenuLaunch.openPath(path); hide()
    }
    private func openHome(_ sub: String) {
        openPath((NSHomeDirectory() as NSString).appendingPathComponent(sub))
    }
    private func openURL(_ s: String) {
        StartMenuLaunch.openURL(s); hide()
    }
    private func openSettings() {
        openPath(StartMenuLaunch.systemSettingsPath)
    }
    private func openAppByID(_ id: String, fallback path: String) {
        StartMenuLaunch.openApp(bundleID: id, fallback: path)
        hide()
    }

    // MARK: - Hover action icon (shown at the avatar spot)

    private func showActionIcon(_ action: MenuAction) {
        hoverIcon.image = actionIcon(action)
        hoverIcon.isHidden = false
        avatar.isHidden = true
    }
    private func hideActionIcon() {
        hoverIcon.isHidden = true
        avatar.isHidden = false
    }

    /// A representative icon for an action (folder/app icon from the system, or an SF Symbol).
    private func actionIcon(_ a: MenuAction) -> NSImage {
        let ws = NSWorkspace.shared
        let home = NSHomeDirectory()
        func file(_ p: String) -> NSImage { ws.icon(forFile: p) }
        func sym(_ n: String) -> NSImage {
            NSImage(systemSymbolName: n, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 48, weight: .regular)) ?? NSImage()
        }
        switch a.kind {
        case .home:            return file(home)
        case .documents:       return file(home + "/Documents")
        case .downloads:       return file(home + "/Downloads")
        case .desktop:         return file(home + "/Desktop")
        case .pictures:        return file(home + "/Pictures")
        case .music:           return file(home + "/Music")
        case .movies:          return file(home + "/Movies")
        case .publicFolder:    return file(home + "/Public")
        case .icloud:          return file(home + "/Library/Mobile Documents/com~apple~CloudDocs")
        case .applications:    return file("/Applications")
        case .utilities:       return file("/Applications/Utilities")
        case .computer:        return file("/")
        case .trash:           return file(home + "/.Trash")
        case .openFolder:      return file(a.param ?? home)
        case .openApp:         return a.param.map(file) ?? sym("app.fill")
        case .openURL:         return NSWorkspace.shared.icon(forFileType: "public.url")
        case .systemSettings:  return file("/System/Applications/System Settings.app")
        case .activityMonitor: return file("/System/Applications/Utilities/Activity Monitor.app")
        case .terminal:        return file("/System/Applications/Utilities/Terminal.app")
        case .launchpad:       return file("/System/Applications/Launchpad.app")
        case .missionControl:  return file("/System/Applications/Mission Control.app")
        case .screenshot:      return file("/System/Applications/Utilities/Screenshot.app")
        case .helpApple:       return sym("questionmark.circle.fill")
        case .sleep:           return sym("moon.fill")
        case .lock:            return sym("lock.fill")
        case .logout:          return sym("rectangle.portrait.and.arrow.right.fill")
        case .restart:         return sym("arrow.clockwise.circle.fill")
        case .shutdown:        return sym("power.circle.fill")
        }
    }

    /// Execute a configurable Start-menu action (right column entries + avatar).
    func perform(_ action: MenuAction) {
        let home = NSHomeDirectory()
        switch action.kind {
        case .home:            openPath(home)
        case .documents:       openHome("Documents")
        case .downloads:       openHome("Downloads")
        case .desktop:         openHome("Desktop")
        case .pictures:        openHome("Pictures")
        case .music:           openHome("Music")
        case .movies:          openHome("Movies")
        case .publicFolder:    openHome("Public")
        case .icloud:          openPath(home + "/Library/Mobile Documents/com~apple~CloudDocs")
        case .applications:    openPath("/Applications")
        case .utilities:       openPath("/Applications/Utilities")
        case .computer:        openURL("file:///")
        case .trash:           openPath(home + "/.Trash")
        case .openFolder:      openPath(action.param ?? home)
        case .openURL:         openURL(action.param ?? "")
        case .openApp:
            if let p = action.param {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: .init())
            }
            hide()
        case .systemSettings:  openSettings()
        case .activityMonitor: openAppByID("com.apple.ActivityMonitor", fallback: "/System/Applications/Utilities/Activity Monitor.app")
        case .terminal:        openAppByID("com.apple.Terminal", fallback: "/System/Applications/Utilities/Terminal.app")
        case .launchpad:       openPath("/System/Applications/Launchpad.app")
        case .missionControl:  openPath("/System/Applications/Mission Control.app")
        case .screenshot:      openPath("/System/Applications/Utilities/Screenshot.app")
        case .helpApple:       openURL("https://support.apple.com/de-de")
        case .sleep:           runOSA("tell application \"System Events\" to sleep")
        case .lock:            runOSA("tell application \"System Events\" to keystroke \"q\" using {command down, control down}")
        case .logout:          runOSA(StartMenuPower.Action.logout.script)
        case .restart:         runOSA(StartMenuPower.Action.restart.script)
        case .shutdown:        runOSA(StartMenuPower.Action.shutdown.script)
        }
    }

    private func runOSA(_ command: String) {
        StartMenuPower.runOSA(command)
        hide()
    }

    @objc private func shutdownAction() { StartMenuPower.run(.shutdown); hide() }

    private func showPowerMenu(from sender: NSView) {
        let menu = StartMenuPower.makeMenu([.sleep, .restart, .logout, .shutdown]) { [weak self] _ in
            self?.hide()
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
}

// (KeyableWindow and FlippedView live in StartMenuShared.swift.)

// MARK: - Palette (menu style × colour mode)

/// Colours of the classic start menu that depend on the menu style (`accent` / `aero`) and the
/// colour mode. Always read at draw time, both can change while the menu exists. Dark mode keeps
/// the familiar dark look; light mode mirrors Win7 with a light glass colour: milky frosted
/// glass with dark text.
private enum MenuPalette {
    static var aero: Bool { UserDefaults.standard.string(forKey: "menuStyle") == "aero" }
    static var light: Bool { !Theme.isDark }
    static func mono(_ w: CGFloat, _ a: CGFloat) -> NSColor { NSColor(calibratedWhite: w, alpha: a) }

    /// Outer border of the whole menu.
    static var outerBorder: NSColor {
        guard light else { return mono(1, 0.30) }
        return aero ? mono(0, 0.30) : Theme.accent(brightness: 0.70, alpha: 0.60)
    }
    /// Text on the glass (right column, power button).
    static var glassText: NSColor { light ? Theme.Aero.text : .white }
    /// Light mode: soft white halo behind the dark text (like the Win7 glass glow).
    static var glassTextGlow: NSShadow? {
        guard light else { return nil }
        let s = NSShadow()
        s.shadowColor = mono(1, 0.85)
        s.shadowOffset = .zero
        s.shadowBlurRadius = 3
        return s
    }
    /// Border of the white program panel (only needed on light glass, where white meets white).
    static var panelBorder: NSColor? {
        guard light else { return nil }
        return aero ? mono(0, 0.16) : Theme.accent(brightness: 0.65, alpha: 0.35)
    }
    /// Engraved separator in the right column: dark line on top, bright line below.
    static var separatorDark: NSColor { light ? mono(0, 0.13) : mono(0, 0.18) }
    static var separatorLight: NSColor { light ? mono(1, 0.80) : mono(1, 0.40) }
}

/// Engraved separator line of the right column (two 1 px lines, colours read at draw time).
private final class SeparatorView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        MenuPalette.separatorDark.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        MenuPalette.separatorLight.setFill()
        NSRect(x: 0, y: 1, width: bounds.width, height: 1).fill()
    }
}

/// The light-blue search band at the bottom of the left panel (#f2f5fb) with a soft shadow and a
/// thin line along its top edge — the transition from the white program list above.
/// In the light Aero style the band turns a neutral frosted silver instead of light blue.
private final class SearchPanelBandView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let frost = MenuPalette.light && MenuPalette.aero
        (frost ? NSColor(srgbRed: 243/255, green: 244/255, blue: 246/255, alpha: 1)
               : NSColor(srgbRed: 242/255, green: 245/255, blue: 251/255, alpha: 1)).setFill()
        bounds.fill()
        // Soft shadow just under the top edge (this view is not flipped → top = maxY).
        let shadow = NSRect(x: bounds.minX, y: bounds.maxY - 6, width: bounds.width, height: 6)
        NSGradient(colors: [NSColor(calibratedWhite: 0, alpha: 0.10),
                            NSColor(calibratedWhite: 0, alpha: 0.0)])?.draw(in: shadow, angle: -90)
        // Thin separator line at the very top.
        (frost ? NSColor(srgbRed: 0xd6/255, green: 0xd9/255, blue: 0xde/255, alpha: 1)
               : NSColor(srgbRed: 0xcd/255, green: 0xdb/255, blue: 0xea/255, alpha: 1)).setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// Windows-7 search box background: white, a subtle recessed shadow along the top inner edge,
/// and a light blue-grey border.
private final class SearchBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        NSColor.white.setFill(); path.fill()

        // Recessed inner shadow along the top edge (this view is not flipped → top = maxY).
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        let top = NSRect(x: r.minX, y: r.maxY - 5, width: r.width, height: 5)
        NSGradient(colors: [NSColor(calibratedWhite: 0, alpha: 0.16),
                            NSColor(calibratedWhite: 0, alpha: 0.0)])?.draw(in: top, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Light blue-grey border.
        NSColor(srgbRed: 0x7f/255, green: 0x9d/255, blue: 0xb9/255, alpha: 1).setStroke()
        path.lineWidth = 1; path.stroke()
    }
}

/// Background: a translucent accent-coloured frosted layer over the whole menu, with a SOLID
/// white program panel on the left. The 5px gap around the white panel forms an accent-coloured
/// border that blends seamlessly into the (right) accent area.
private final class ColumnTintView: NSView {
    private let border: CGFloat = 10

    override func draw(_ dirtyRect: NSRect) {
        let light = MenuPalette.light
        if MenuPalette.aero && light {
            // Light frosted Aero glass (Win7 with a light glass colour): milky white, a little
            // denser towards the bottom, with a bright gloss over the top.
            NSGradient(colors: [
                MenuPalette.mono(1.00, 0.62),
                MenuPalette.mono(0.94, 0.64),
                MenuPalette.mono(0.86, 0.72),
            ], atLocations: [0.0, 0.5, 1.0], colorSpace: .deviceRGB)?.draw(in: bounds, angle: -90)
            NSGradient(colors: [MenuPalette.mono(1, 0.45), MenuPalette.mono(1, 0.0)])?
                .draw(in: NSRect(x: 0, y: bounds.midY, width: bounds.width, height: bounds.height / 2), angle: -90)
        } else if MenuPalette.aero {
            // Dark Aero glass, like the taskbar.
            let glass = NSGradient(colors: [
                NSColor(calibratedWhite: 0.34, alpha: 0.55),
                NSColor(calibratedWhite: 0.16, alpha: 0.60),
                NSColor(calibratedWhite: 0.05, alpha: 0.72),
            ], atLocations: [0.0, 0.5, 1.0], colorSpace: .deviceRGB)
            glass?.draw(in: bounds, angle: -90)
            // Glossy highlight over the top.
            NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.22),
                                NSColor(calibratedWhite: 1, alpha: 0.0)])?
                .draw(in: NSRect(x: 0, y: bounds.midY, width: bounds.width, height: bounds.height / 2), angle: -90)
        } else if light {
            // Light accent glass: the accent colour, but pale and airy so dark text reads well.
            let a: CGFloat = 0.55
            NSGradient(colors: [
                Theme.accent(brightness: 1.35, saturation: 0.40).withAlphaComponent(a),
                Theme.accent(brightness: 1.45, saturation: 0.28).withAlphaComponent(a),
                Theme.accent(brightness: 1.25, saturation: 0.48).withAlphaComponent(a),
                Theme.accent(brightness: 1.05, saturation: 0.66).withAlphaComponent(a),
            ], atLocations: [0.0, 0.18, 0.55, 1.0], colorSpace: .sRGB)?.draw(in: bounds, angle: -90)
        } else {
            // Rich accent gradient: medium-blue at top with a soft highlight, deepening downward.
            let a: CGFloat = 0.6
            NSGradient(colors: [
                Theme.accent(brightness: 0.90, saturation: 0.90).withAlphaComponent(a),
                Theme.accent(brightness: 0.99, saturation: 0.78).withAlphaComponent(a),
                Theme.accent(brightness: 0.76, saturation: 1.00).withAlphaComponent(a),
                Theme.accent(brightness: 0.50, saturation: 1.00).withAlphaComponent(a),
            ], atLocations: [0.0, 0.18, 0.55, 1.0], colorSpace: .sRGB)?.draw(in: bounds, angle: -90)
        }

        // Solid (opaque) white program panel, inset by the border on left/top/bottom; its right
        // edge sits `border` px short of the column boundary → frame all around.
        let panel = NSRect(x: border, y: border,
                           width: Theme.startLeftWidth - 2 * border,
                           height: bounds.height - 2 * border)
        let panelPath = NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        panelPath.fill()

        if light {
            // Light glass: a hairline around the white panel and the bright inner rim of the glass.
            if let c = MenuPalette.panelBorder {
                let edge = NSBezierPath(roundedRect: panel.insetBy(dx: -0.5, dy: -0.5), xRadius: 6.5, yRadius: 6.5)
                c.setStroke(); edge.lineWidth = 1; edge.stroke()
            }
            let rim = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
            MenuPalette.mono(1, 0.75).setStroke(); rim.lineWidth = 1; rim.stroke()
        }
    }
}

// MARK: - Avatar

private final class AvatarView: NSView {
    /// Freely assignable click action (configured in the Start-menu editor).
    var onClick: (() -> Void)?

    /// The macOS account picture of the current user, if available.
    private static let accountImage: NSImage? = {
        let authority = CBIdentityAuthority.default()
        guard let identity = CBIdentity(name: NSUserName(), authority: authority) else { return nil }
        return identity.image
    }()

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 1, dy: 1)
        let outerPath = NSBezierPath(roundedRect: outer, xRadius: 9, yRadius: 9)

        // Glassy frame body — accent-tinted, or silver in Aero mode (matching the menu style).
        // Light mode: a brighter, frostier frame.
        let frameColors: [NSColor]
        let light = MenuPalette.light
        if MenuPalette.aero && light {
            frameColors = [NSColor(calibratedWhite: 1.00, alpha: 1),
                           NSColor(calibratedWhite: 0.92, alpha: 1),
                           NSColor(calibratedWhite: 0.76, alpha: 1)]
        } else if MenuPalette.aero {
            frameColors = [NSColor(calibratedWhite: 0.96, alpha: 1),
                           NSColor(calibratedWhite: 0.78, alpha: 1),
                           NSColor(calibratedWhite: 0.55, alpha: 1)]
        } else if light {
            frameColors = [Theme.accent(brightness: 1.6, saturation: 0.14),
                           Theme.accent(brightness: 1.35, saturation: 0.36),
                           Theme.accent(brightness: 1.00, saturation: 0.72)]
        } else {
            frameColors = [Theme.accent(brightness: 1.5, saturation: 0.22),
                           Theme.accent(brightness: 1.15, saturation: 0.55),
                           Theme.accent(brightness: 0.80, saturation: 0.95)]
        }
        NSGradient(colors: frameColors, atLocations: [0, 0.5, 1], colorSpace: .sRGB)?
            .draw(in: outerPath, angle: -90)

        // Gloss highlight over the upper half of the frame.
        NSGraphicsContext.current?.saveGraphicsState()
        outerPath.addClip()
        let gloss = NSRect(x: outer.minX, y: outer.midY, width: outer.width, height: outer.height / 2)
        NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.55),
                            NSColor(calibratedWhite: 1, alpha: 0.0)])?.draw(in: gloss, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Inner recess + picture.
        let thickness: CGFloat = 7
        let inner = outer.insetBy(dx: thickness, dy: thickness)
        let innerPath = NSBezierPath(roundedRect: inner, xRadius: 4, yRadius: 4)
        NSGraphicsContext.current?.saveGraphicsState()
        innerPath.addClip()
        if !UserDefaults.standard.bool(forKey: "demoMode"), let img = AvatarView.accountImage {
            let side = max(inner.width, inner.height)
            img.draw(in: NSRect(x: inner.midX - side / 2, y: inner.midY - side / 2, width: side, height: side))
        } else {
            NSColor(calibratedWhite: 0.95, alpha: 1).setFill(); innerPath.fill()
            let glyph = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
            NSColor(calibratedRed: 0.30, green: 0.52, blue: 0.80, alpha: 1).set()
            glyph?.draw(in: inner.insetBy(dx: 4, dy: 4))
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        // Bevel: dark recess line around the photo, dark hairline + white highlight on the frame.
        NSColor(calibratedWhite: 0, alpha: 0.35).setStroke(); innerPath.lineWidth = 1.5; innerPath.stroke()
        NSColor(calibratedWhite: 0, alpha: light ? 0.30 : 0.40).setStroke(); outerPath.lineWidth = 1; outerPath.stroke()
        let hi = NSBezierPath(roundedRect: outer.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 1, alpha: 0.5).setStroke(); hi.lineWidth = 1; hi.stroke()
    }
}

// MARK: - Windows-7 style silver button

private final class Win7Button: NSControl {
    var onClick: (() -> Void)?
    /// Which corners are rounded. Set both false-on-one-side to fuse two
    /// buttons into a single split control with a continuous top/bottom line.
    var roundLeft = true { didSet { needsDisplay = true } }
    var roundRight = true { didSet { needsDisplay = true } }
    private let title: String
    private var hovering = false
    private var pressed = false

    /// Rounded-rect path with per-side corner control (rounds the left and/or
    /// right corners; the other side stays square so edges meet flush).
    private func framePath(_ r: NSRect, radius: CGFloat) -> NSBezierPath {
        let rl = roundLeft ? radius : 0
        let rr = roundRight ? radius : 0
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + rl, y: r.maxY))
        p.line(to: NSPoint(x: r.maxX - rr, y: r.maxY))
        if rr > 0 { p.appendArc(withCenter: NSPoint(x: r.maxX - rr, y: r.maxY - rr), radius: rr, startAngle: 90, endAngle: 0, clockwise: true) }
        else { p.line(to: NSPoint(x: r.maxX, y: r.maxY)) }
        p.line(to: NSPoint(x: r.maxX, y: r.minY + rr))
        if rr > 0 { p.appendArc(withCenter: NSPoint(x: r.maxX - rr, y: r.minY + rr), radius: rr, startAngle: 0, endAngle: -90, clockwise: true) }
        else { p.line(to: NSPoint(x: r.maxX, y: r.minY)) }
        p.line(to: NSPoint(x: r.minX + rl, y: r.minY))
        if rl > 0 { p.appendArc(withCenter: NSPoint(x: r.minX + rl, y: r.minY + rl), radius: rl, startAngle: 270, endAngle: 180, clockwise: true) }
        else { p.line(to: NSPoint(x: r.minX, y: r.minY)) }
        p.line(to: NSPoint(x: r.minX, y: r.maxY - rl))
        if rl > 0 { p.appendArc(withCenter: NSPoint(x: r.minX + rl, y: r.maxY - rl), radius: rl, startAngle: 180, endAngle: 90, clockwise: true) }
        else { p.line(to: NSPoint(x: r.minX, y: r.maxY)) }
        p.close()
        return p
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Build a top→bottom gradient from (hex, opacity) stops at locations 0 / 0.5 / 0.5 / 1
    /// (the doubled middle stop yields the crisp Windows-7 glass crease).
    static func glassGradient(_ stops: [(String, CGFloat)]) -> NSGradient? {
        NSGradient(colors: stops.map { hexColor($0.0, alpha: $0.1) },
                   atLocations: [0.0, 0.5, 0.5, 1.0], colorSpace: .sRGB)
    }
    static func hexColor(_ hex: String, alpha: CGFloat) -> NSColor {
        let v = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: alpha)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false; needsDisplay = true
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = framePath(r, radius: 3)

        let aero = MenuPalette.aero
        let light = MenuPalette.light
        let textColor = MenuPalette.glassText
        var border = NSColor(calibratedWhite: 0, alpha: 0.6)

        if aero && light {
            // Light silver glass (same build as the dark variant: a faint base + bright glass on top).
            let baseStops: [(String, CGFloat)]
            let highStops: [(String, CGFloat)]
            if pressed {
                baseStops = [("000000", 0.14), ("000000", 0.18), ("000000", 0.24), ("000000", 0.16)]
                highStops = [("d6d6d6", 0.90), ("cdcdcd", 0.85), ("bfbfbf", 0.85), ("d0d0d0", 0.90)]
            } else if hovering {
                baseStops = [("000000", 0.04), ("000000", 0.06), ("000000", 0.10), ("000000", 0.06)]
                highStops = [("ffffff", 0.97), ("fbfcfe", 0.90), ("e6edf6", 0.88), ("f1f5fb", 0.92)]
            } else {
                baseStops = [("000000", 0.05), ("000000", 0.08), ("000000", 0.14), ("000000", 0.08)]
                highStops = [("ffffff", 0.88), ("f5f5f5", 0.72), ("e3e3e3", 0.64), ("eeeeee", 0.74)]
            }
            Win7Button.glassGradient(baseStops)?.draw(in: path, angle: -90)
            Win7Button.glassGradient(highStops)?.draw(in: path, angle: -90)
            border = NSColor(calibratedWhite: 0, alpha: 0.42)
        } else if aero {
            // Exact Windows-7 button glass: a dark base gradient + a light "high" glass gradient on
            // top (stops taken 1:1 from the reference startmenu-buttons.svg), per state. The doubled
            // 0.5 stop makes the crisp glass crease across the middle.
            let blackStops: [(String, CGFloat)]
            let highStops: [(String, CGFloat)]
            if pressed {
                blackStops = [("000000", 0.55), ("000000", 0.72), ("000000", 0.88), ("000000", 0.51)]
                highStops  = [("c8c8c8", 0.32), ("272727", 0.35), ("000000", 0.36), ("181818", 0.329)]
            } else if hovering {
                blackStops = [("000000", 0.55), ("000000", 0.72), ("000000", 0.88), ("000000", 0.51)]
                highStops  = [("fefefe", 0.859), ("fcfcfc", 0.69), ("fbfbfb", 0.612), ("fcfcfc", 0.66)]
            } else {
                blackStops = [("000000", 0.35), ("000203", 0.55), ("000305", 0.67), ("000407", 0.34)]
                highStops  = [("f7f7f7", 0.51), ("eeeeee", 0.23), ("e6e6e6", 0.129), ("f2f2f2", 0.23)]
            }
            Win7Button.glassGradient(blackStops)?.draw(in: path, angle: -90)
            Win7Button.glassGradient(highStops)?.draw(in: path, angle: -90)
        } else {
            // Accent-coloured glass (pale in light mode, so the dark label stays legible).
            let colors: [NSColor]
            var fillAlpha: CGFloat = 0.5
            if light {
                fillAlpha = 0.78
                if pressed {
                    colors = [Theme.accent(brightness: 1.00, saturation: 0.70), Theme.accent(brightness: 1.10, saturation: 0.60),
                              Theme.accent(brightness: 1.15, saturation: 0.55), Theme.accent(brightness: 1.20, saturation: 0.50)]
                    border = Theme.accent(brightness: 0.55)
                } else if hovering {
                    colors = [Theme.accent(brightness: 1.60, saturation: 0.16), Theme.accent(brightness: 1.45, saturation: 0.26),
                              Theme.accent(brightness: 1.25, saturation: 0.44), Theme.accent(brightness: 1.40, saturation: 0.34)]
                    border = Theme.accent(brightness: 0.75)
                } else {
                    colors = [Theme.accent(brightness: 1.50, saturation: 0.22), Theme.accent(brightness: 1.35, saturation: 0.34),
                              Theme.accent(brightness: 1.15, saturation: 0.54), Theme.accent(brightness: 1.30, saturation: 0.44)]
                    border = Theme.accent(brightness: 0.65)
                }
            } else if pressed {
                colors = [Theme.accent(brightness: 0.62, saturation: 1.0), Theme.accent(brightness: 0.72, saturation: 0.95),
                          Theme.accent(brightness: 0.8, saturation: 0.9), Theme.accent(brightness: 0.88, saturation: 0.85)]
                border = Theme.accent(brightness: 0.5)
            } else if hovering {
                colors = [Theme.accent(brightness: 1.45, saturation: 0.45), Theme.accent(brightness: 1.2, saturation: 0.65),
                          Theme.accent(brightness: 0.95, saturation: 0.9), Theme.accent(brightness: 1.1, saturation: 0.8)]
                border = Theme.accent(brightness: 1.2)
            } else {
                colors = [Theme.accent(brightness: 1.35, saturation: 0.5), Theme.accent(brightness: 1.08, saturation: 0.7),
                          Theme.accent(brightness: 0.8, saturation: 0.95), Theme.accent(brightness: 0.96, saturation: 0.85)]
                border = Theme.accent(brightness: 0.6)
            }
            NSGradient(colors: colors.map { $0.withAlphaComponent(fillAlpha) },
                       atLocations: [0.0, 0.49, 0.5, 1.0], colorSpace: .sRGB)?.draw(in: path, angle: -90)
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            let gloss = NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
            NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.45),
                                NSColor(calibratedWhite: 1, alpha: 0.0)])?.draw(in: gloss, angle: -90)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Thin black outer frame (Aero style), else the accent border. (No white perimeter ring.)
        (aero ? border : border.withAlphaComponent(0.7)).setStroke()
        path.lineWidth = 1; path.stroke()

        // Label: white with a soft dark shadow on dark glass, dark with a white halo on light glass.
        let style = NSMutableParagraphStyle(); style.alignment = .center
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ]
        let shadow = NSShadow()   // white text → soft dark shadow for legibility on glass
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 1.5
        attrs[.shadow] = light ? MenuPalette.glassTextGlow : shadow
        let s = NSAttributedString(string: title, attributes: attrs)
        s.draw(in: NSRect(x: 0, y: (bounds.height - s.size().height) / 2 + (pressed ? -0.5 : 0),
                          width: bounds.width, height: s.size().height))
    }
}

// MARK: - Right-column link row (white text on dark glass, dark text on light glass)

private final class RightRowButton: NSControl {
    private let title: String
    private let bold: Bool
    private let onClick: () -> Void
    var onHover: ((Bool) -> Void)?
    private var hovering = false

    init(title: String, bold: Bool, action: @escaping () -> Void) {
        self.title = title; self.bold = bold; self.onClick = action
        super.init(frame: .zero)
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        let light = MenuPalette.light
        if hovering {
            // Glassy Aero hover frame (denser and with a darker rim on light glass).
            let r = bounds.insetBy(dx: 1, dy: 2)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: light ? 0.72 : 0.30),
                                NSColor(calibratedWhite: 1, alpha: light ? 0.38 : 0.10)])?.draw(in: path, angle: -90)
            // Top gloss highlight.
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            let gloss = NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
            NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.38),
                                NSColor(calibratedWhite: 1, alpha: 0.0)])?.draw(in: gloss, angle: -90)
            NSGraphicsContext.current?.restoreGraphicsState()
            // Subtle border.
            let rim: NSColor
            if !light { rim = NSColor(calibratedWhite: 1, alpha: 0.55) }
            else if MenuPalette.aero { rim = NSColor(calibratedWhite: 0, alpha: 0.24) }
            else { rim = Theme.accent(brightness: 0.70, alpha: 0.55) }
            rim.setStroke()
            path.lineWidth = 1
            path.stroke()
            if light {
                let inner = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
                NSColor(calibratedWhite: 1, alpha: 0.75).setStroke(); inner.lineWidth = 1; inner.stroke()
            }
        }
        let font = bold ? NSFont.boldSystemFont(ofSize: 16.5) : NSFont.systemFont(ofSize: 15)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: MenuPalette.glassText]
        if let glow = MenuPalette.glassTextGlow { attrs[.shadow] = glow }
        let s = NSAttributedString(string: title, attributes: attrs)
        s.draw(at: NSPoint(x: 8, y: (bounds.height - s.size().height) / 2))
    }
}

// MARK: - Left "Alle Programme" row

private final class LeftRowButton: NSControl {
    private var title: String
    private var back: Bool = false
    private let bold: Bool
    private let arrow: Bool
    private let onClick: () -> Void
    private var hovering = false

    init(title: String, bold: Bool, arrow: Bool, action: @escaping () -> Void) {
        self.title = title; self.bold = bold; self.arrow = arrow; self.onClick = action
        super.init(frame: .zero)
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ t: String, back: Bool) { title = t; self.back = back; needsDisplay = true }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        // Divider line at the very top of the row (Win7 light-blue). This view isn't flipped,
        // so the top edge is at maxY.
        NSColor(srgbRed: 0xd6/255, green: 0xe5/255, blue: 0xf5/255, alpha: 1).setStroke()
        let line = NSBezierPath()
        let ly = bounds.height - 0.5
        line.move(to: NSPoint(x: 4, y: ly)); line.line(to: NSPoint(x: bounds.width - 4, y: ly))
        line.lineWidth = 1; line.stroke()

        if hovering {
            Theme.accent(brightness: 1.55, saturation: 0.35, alpha: 0.30).setFill()
            let r = NSRect(x: 2, y: 3, width: bounds.width - 4, height: bounds.height - 4)
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            p.fill(); Theme.accent(brightness: 1.1, alpha: 0.6).setStroke(); p.lineWidth = 1; p.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13.5),
            .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
        ]
        let glyph = arrow ? (back ? "◂  " : "▸  ") : ""
        let s = NSAttributedString(string: glyph + title, attributes: attrs)
        s.draw(at: NSPoint(x: 8, y: (bounds.height - s.size().height) / 2 + 1))
    }
}

// MARK: - Left program row (icon + name on white)

private final class AppRowButton: NSControl, StartMenuIconDisplaying {
    private let entry: AppEntry
    private let pinned: Bool
    private let onOpen: (AppEntry) -> Void
    private let onTogglePin: (AppEntry) -> Void
    private let onPinTaskbar: ((AppEntry) -> Void)?
    private var hovering = false
    var iconImage: NSImage?

    init(entry: AppEntry, pinned: Bool,
         onOpen: @escaping (AppEntry) -> Void,
         onTogglePin: @escaping (AppEntry) -> Void,
         onPinTaskbar: ((AppEntry) -> Void)? = nil) {
        self.entry = entry; self.pinned = pinned; self.onOpen = onOpen
        self.onTogglePin = onTogglePin; self.onPinTaskbar = onPinTaskbar
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.startLeftWidth - 28, height: 50))
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateIcon(_ img: NSImage?) { iconImage = img; needsDisplay = true }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onOpen(entry) }

    override func rightMouseDown(with event: NSEvent) {
        let e = entry
        let menu = StartMenuContextMenu.make(
            for: e, pinned: pinned,
            onTogglePin: { [weak self] in self?.onTogglePin(e) },
            onPinTaskbar: onPinTaskbar.map { cb in { cb(e) } })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.accent(brightness: 1.55, saturation: 0.35, alpha: 0.30).setFill()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            p.fill(); Theme.accent(brightness: 1.1, alpha: 0.6).setStroke(); p.lineWidth = 1; p.stroke()
        }
        let iconS: CGFloat = 36
        iconImage?.draw(in: NSRect(x: 8, y: (bounds.height - iconS) / 2, width: iconS, height: iconS))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15.5),
            .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
        ]
        let s = NSAttributedString(string: entry.name, attributes: attrs)
        s.draw(at: NSPoint(x: 52, y: (bounds.height - s.size().height) / 2))

        if pinned {
            let pin = NSAttributedString(string: "📌", attributes: [.font: NSFont.systemFont(ofSize: 13)])
            pin.draw(at: NSPoint(x: bounds.width - 22, y: (bounds.height - pin.size().height) / 2))
        }
    }
}
