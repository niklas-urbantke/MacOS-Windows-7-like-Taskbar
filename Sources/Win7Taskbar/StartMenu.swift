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
    private let avatar = AvatarView(frame: .zero)
    private let listDoc = FlippedView()        // manual-layout document view (fast for long lists)
    private var listY: CGFloat = 0
    private static var iconCache: [String: NSImage] = [:]
    private var allApps: [AppEntry] = []
    private var showingAll = false
    private var alleButton: LeftRowButton?
    private var fileSearchToken = 0
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
        root.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.30).cgColor

        // Frosted glass background (like the taskbar): blur + semi-transparent column tint.
        let blur = NSVisualEffectView(frame: root.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.alphaValue = 0.45   // weniger Blur
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
        outer.addSubview(avatar)

        window.contentView = outer
    }

    private func buildLeftColumn() {
        // Scrollable program list.
        let bottomBlock: CGFloat = 88
        scrollView.frame = NSRect(x: 12, y: 12, width: leftW - 24, height: H - bottomBlock - 18)
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

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

        // Search field.
        searchField.frame = NSRect(x: 14, y: H - 42, width: leftW - 28, height: 30)
        searchField.placeholderString = "Programme/Dateien durchsuchen"
        searchField.delegate = self
        searchField.bezelStyle = .roundedBezel
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.focusRingType = .none
        root.addSubview(searchField)
    }

    private func buildRightColumn() {
        let innerX = leftW + 20
        let innerW = (W - leftW) - 38

        // (Avatar is added in buildContent so it can overhang the top edge.)

        // Right-column entries (title, gapBefore, bold, action).
        let user: String = UserDefaults.standard.bool(forKey: "demoMode")
            ? "Max Mustermann"
            : (NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
        let entries: [(String, Bool, Bool, () -> Void)] = [
            (user,                 false, true,  { [weak self] in self?.openPath(NSHomeDirectory()) }),
            ("Dokumente",          true,  false, { [weak self] in self?.openHome("Documents") }),
            ("Bilder",             false, false, { [weak self] in self?.openHome("Pictures") }),
            ("Musik",              false, false, { [weak self] in self?.openHome("Music") }),
            ("Spiele",             true,  false, { [weak self] in self?.openPath("/Applications") }),
            ("Computer",           false, false, { [weak self] in self?.openURL("file:///") }),
            ("Systemsteuerung",    true,  false, { [weak self] in self?.openSettings() }),
            ("Geräte und Drucker", false, false, { [weak self] in self?.openSettings() }),
            ("Standardprogramme",  false, false, { [weak self] in self?.openSettings() }),
            ("Hilfe und Support",  false, false, { [weak self] in self?.openURL("https://support.apple.com/de-de") }),
        ]

        var y: CGFloat = 64
        for (title, gap, bold, action) in entries {
            if gap {
                y += 12
                // Visual separators between Musik|Spiele and Computer|Systemsteuerung.
                if title == "Spiele" || title == "Systemsteuerung" {
                    addSeparator(at: y - 7, x: innerX, width: innerW)
                }
            }
            let row = RightRowButton(title: title, bold: bold, action: action)
            row.frame = NSRect(x: innerX, y: y, width: innerW, height: 40)
            root.addSubview(row)
            y += 40
        }

        // Shut-down split button (Windows-7 silver style), bottom-right.
        let shutW: CGFloat = innerW - 30
        let shut = Win7Button(title: "Herunterfahren")
        shut.onClick = { [weak self] in self?.shutdownAction() }
        shut.frame = NSRect(x: innerX, y: H - 46, width: shutW, height: 28)
        root.addSubview(shut)

        let arrow = Win7Button(title: "▶")
        arrow.frame = NSRect(x: innerX + shutW + 2, y: H - 46, width: 26, height: 28)
        arrow.onClick = { [weak self, weak arrow] in if let a = arrow { self?.showPowerMenu(from: a) } }
        root.addSubview(arrow)
    }

    /// A subtle engraved separator line (dark + light) in the right column.
    private func addSeparator(at y: CGFloat, x: CGFloat, width: CGFloat) {
        let dark = NSView(frame: NSRect(x: x, y: y, width: width, height: 1))
        dark.wantsLayer = true
        dark.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.18).cgColor
        root.addSubview(dark)

        let light = NSView(frame: NSRect(x: x, y: y + 1, width: width, height: 1))
        light.wantsLayer = true
        light.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.40).cgColor
        root.addSubview(light)
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
                                   if file { NSWorkspace.shared.open(e.url); self?.hide() }
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
        if let cached = StartMenuController.iconCache[app.url.path] { row.iconImage = cached }
        return row
    }

    /// Load missing icons off the main thread, then apply + cache.
    private func loadIcons(_ pending: [(AppRowButton, String)]) {
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for (row, path) in pending {
                let img = NSWorkspace.shared.icon(forFile: path)
                img.size = NSSize(width: 36, height: 36)
                DispatchQueue.main.async {
                    StartMenuController.iconCache[path] = img
                    row.updateIcon(img)
                }
            }
        }
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
        fileSearchToken += 1
        let token = fileSearchToken
        DispatchQueue.global(qos: .userInitiated).async {
            let results = StartMenuController.runMdfind(query)
            DispatchQueue.main.async {
                guard token == self.fileSearchToken,
                      self.searchField.stringValue.trimmingCharacters(in: .whitespaces) == query
                else { return }
                self.appendFileResults(results)
            }
        }
    }

    private static func runMdfind(_ query: String) -> [AppEntry] {
        let p = Process()
        p.launchPath = "/usr/bin/mdfind"
        p.arguments = ["-name", query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let str = String(data: data, encoding: .utf8) else { return [] }

        var seen = Set<String>()
        var out: [AppEntry] = []
        for line in str.split(separator: "\n") {
            let path = String(line)
            if path.contains(".app/") || path.hasSuffix(".app") { continue }  // apps handled separately
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
            seen.insert(path)
            out.append(AppEntry(name: (path as NSString).lastPathComponent,
                                url: URL(fileURLWithPath: path), bundleID: nil))
            if out.count >= 12 { break }
        }
        return out
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
        alleButton?.setTitle("Alle Programme", back: false)
        searchField.stringValue = ""
        root.subviews.forEach { $0.needsDisplay = true }   // reflect a possible style change
        avatar.needsDisplay = true
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
        NSWorkspace.shared.openApplication(at: entry.url, configuration: .init())
        hide()
    }

    private func openPath(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path)); hide()
    }
    private func openHome(_ sub: String) {
        openPath((NSHomeDirectory() as NSString).appendingPathComponent(sub))
    }
    private func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }; hide()
    }
    private func openSettings() {
        openPath("/System/Applications/System Settings.app")
    }

    private func runOSA(_ command: String) {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", command]
        try? p.run()
        hide()
    }

    @objc private func shutdownAction() { runOSA("tell application \"System Events\" to shut down") }

    private func showPowerMenu(from sender: NSView) {
        let menu = NSMenu()
        let items: [(String, String)] = [
            ("Energie sparen", "tell application \"System Events\" to sleep"),
            ("Neu starten", "tell application \"System Events\" to restart"),
            ("Abmelden", "tell application \"System Events\" to log out"),
            ("Herunterfahren", "tell application \"System Events\" to shut down"),
        ]
        for (title, cmd) in items {
            let it = NSMenuItem(title: title, action: #selector(powerItem(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = cmd
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func powerItem(_ sender: NSMenuItem) {
        if let cmd = sender.representedObject as? String { runOSA(cmd) }
    }
}

// MARK: - Borderless window that can still receive keyboard focus (for the search field)

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Flipped helper view (top-down coordinates) with column background

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Background: a translucent accent-coloured frosted layer over the whole menu, with a SOLID
/// white program panel on the left. The 5px gap around the white panel forms an accent-coloured
/// border that blends seamlessly into the (right) accent area.
private final class ColumnTintView: NSView {
    private let border: CGFloat = 10

    override func draw(_ dirtyRect: NSRect) {
        if UserDefaults.standard.string(forKey: "menuStyle") == "aero" {
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
        NSColor.white.setFill()
        NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - Avatar

private final class AvatarView: NSView {
    /// The macOS account picture of the current user, if available.
    private static let accountImage: NSImage? = {
        let authority = CBIdentityAuthority.default()
        guard let identity = CBIdentity(name: NSUserName(), authority: authority) else { return nil }
        return identity.image
    }()

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 1, dy: 1)
        let outerPath = NSBezierPath(roundedRect: outer, xRadius: 9, yRadius: 9)

        // Glassy frame body — accent-tinted, or silver in Aero mode (matching the menu style).
        let frameColors: [NSColor]
        if UserDefaults.standard.string(forKey: "menuStyle") == "aero" {
            frameColors = [NSColor(calibratedWhite: 0.96, alpha: 1),
                           NSColor(calibratedWhite: 0.78, alpha: 1),
                           NSColor(calibratedWhite: 0.55, alpha: 1)]
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
        NSColor(calibratedWhite: 0, alpha: 0.40).setStroke(); outerPath.lineWidth = 1; outerPath.stroke()
        let hi = NSBezierPath(roundedRect: outer.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 1, alpha: 0.5).setStroke(); hi.lineWidth = 1; hi.stroke()
    }
}

// MARK: - Windows-7 style silver button

private final class Win7Button: NSControl {
    var onClick: (() -> Void)?
    private let title: String
    private var hovering = false
    private var pressed = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

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
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)

        let aero = UserDefaults.standard.string(forKey: "menuStyle") == "aero"
        let colors: [NSColor]
        let border: NSColor
        let textColor: NSColor
        let fillAlpha: CGFloat

        if aero {
            // Silver Win7 glass to match the dark Aero menu.
            func g(_ v: CGFloat) -> NSColor { NSColor(calibratedWhite: v, alpha: 1) }
            if pressed {
                colors = [g(0.78), g(0.84), g(0.88), g(0.90)]; border = g(0.45)
            } else if hovering {
                colors = [g(1.00), g(0.96), g(0.90), g(0.96)]; border = g(0.50)
            } else {
                colors = [g(0.99), g(0.93), g(0.85), g(0.92)]; border = g(0.55)
            }
            textColor = .white
            fillAlpha = 0.3
        } else {
            // Accent-coloured glass.
            if pressed {
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
            textColor = .white
            fillAlpha = 0.5
        }

        let faded = colors.map { $0.withAlphaComponent(fillAlpha) }
        NSGradient(colors: faded, atLocations: [0.0, 0.49, 0.5, 1.0], colorSpace: .sRGB)?
            .draw(in: path, angle: -90)

        // Glass gloss over the top half.
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        let gloss = NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.45),
                            NSColor(calibratedWhite: 1, alpha: 0.0)])?.draw(in: gloss, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Top inner highlight + outer border.
        NSColor(calibratedWhite: 1, alpha: 0.45).setStroke()
        let hi = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 2.5, yRadius: 2.5)
        hi.lineWidth = 1; hi.stroke()
        border.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1; path.stroke()

        // Label — white (accent) with a soft shadow, or dark (silver/aero).
        let style = NSMutableParagraphStyle(); style.alignment = .center
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ]
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.4)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        attrs[.shadow] = shadow
        let s = NSAttributedString(string: title, attributes: attrs)
        s.draw(in: NSRect(x: 0, y: (bounds.height - s.size().height) / 2 + (pressed ? -0.5 : 0),
                          width: bounds.width, height: s.size().height))
    }
}

// MARK: - Right-column link row (white text on blue)

private final class RightRowButton: NSControl {
    private let title: String
    private let bold: Bool
    private let onClick: () -> Void
    private var hovering = false

    init(title: String, bold: Bool, action: @escaping () -> Void) {
        self.title = title; self.bold = bold; self.onClick = action
        super.init(frame: .zero)
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            // Glassy Aero hover frame.
            let r = bounds.insetBy(dx: 1, dy: 2)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.30),
                                NSColor(calibratedWhite: 1, alpha: 0.10)])?.draw(in: path, angle: -90)
            // Top gloss highlight.
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            let gloss = NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
            NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.38),
                                NSColor(calibratedWhite: 1, alpha: 0.0)])?.draw(in: gloss, angle: -90)
            NSGraphicsContext.current?.restoreGraphicsState()
            // Subtle border.
            NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let font = bold ? NSFont.boldSystemFont(ofSize: 16.5) : NSFont.systemFont(ofSize: 15)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
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
        // Divider line on top.
        NSColor(calibratedWhite: 0.80, alpha: 1).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 4, y: 0.5)); line.line(to: NSPoint(x: bounds.width - 4, y: 0.5))
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

private final class AppRowButton: NSControl {
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
        let menu = NSMenu()
        let isApp = entry.bundleID != nil

        if isApp {
            let pinItem = NSMenuItem(title: pinned ? "Vom Startmenü lösen" : "An Startmenü anheften",
                                     action: #selector(togglePin), keyEquivalent: "")
            pinItem.target = self
            menu.addItem(pinItem)

            if onPinTaskbar != nil {
                let tb = NSMenuItem(title: "An Taskleiste anheften", action: #selector(pinTaskbarAction), keyEquivalent: "")
                tb.target = self
                menu.addItem(tb)
            }
        }

        let shortcut = NSMenuItem(title: "Desktopverknüpfung erstellen", action: #selector(shortcutAction), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func togglePin() { onTogglePin(entry) }
    @objc private func pinTaskbarAction() { onPinTaskbar?(entry) }
    @objc private func shortcutAction() { AppRowButton.createDesktopShortcut(for: entry) }

    /// Create a Finder alias for the app/file on the Desktop.
    private static func createDesktopShortcut(for entry: AppEntry) {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        else { return }
        var dest = desktop.appendingPathComponent(entry.name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = desktop.appendingPathComponent("\(entry.name) \(n)"); n += 1
        }
        do {
            let data = try entry.url.bookmarkData(options: .suitableForBookmarkFile,
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: dest)
        } catch {
            NSLog("Desktopverknüpfung fehlgeschlagen: \(error)")
        }
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
