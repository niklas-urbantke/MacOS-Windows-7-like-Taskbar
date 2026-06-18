import AppKit

/// Windows-7-style two-column Start menu: white program list on the left,
/// blue "places & power" panel on the right, with a search box and avatar.
final class StartMenuController: NSObject, NSTextFieldDelegate {
    private let window: NSWindow
    private let root = FlippedView()
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()
    private let searchField = NSTextField()
    private var allApps: [AppEntry] = []
    private var showingAll = false
    private var alleButton: LeftRowButton?
    weak var taskbarController: TaskbarController?

    private let W = Theme.startWidth
    private let H = Theme.startHeight
    private let leftW = Theme.startLeftWidth

    override init() {
        window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.startWidth, height: Theme.startHeight),
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
        root.frame = NSRect(x: 0, y: 0, width: W, height: H)
        root.wantsLayer = true
        root.layer?.cornerRadius = 9
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.68, alpha: 0.9).cgColor

        buildLeftColumn()
        buildRightColumn()

        window.contentView = root
    }

    private func buildLeftColumn() {
        // Scrollable program list.
        let bottomBlock: CGFloat = 88
        scrollView.frame = NSRect(x: 6, y: 8, width: leftW - 12, height: H - bottomBlock - 8)
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 1
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        scrollView.documentView = doc
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalToConstant: leftW - 12 - 16),
        ])
        root.addSubview(scrollView)

        // "Alle Programme" / "Zurück" toggle row.
        let alle = LeftRowButton(title: "Alle Programme", bold: false, arrow: true) { [weak self] in
            self?.toggleAllPrograms()
        }
        alle.frame = NSRect(x: 6, y: H - bottomBlock + 6, width: leftW - 12, height: 30)
        root.addSubview(alle)
        alleButton = alle

        // Search field.
        searchField.frame = NSRect(x: 12, y: H - 42, width: leftW - 24, height: 30)
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

        // Avatar at the very top of the right column.
        let avatarSize: CGFloat = 66
        let avatar = AvatarView(frame: NSRect(x: leftW + (W - leftW - avatarSize) / 2, y: 10,
                                              width: avatarSize, height: avatarSize))
        root.addSubview(avatar)

        // Right-column entries (title, gapBefore, bold, action).
        let user = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
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

        var y: CGFloat = 90
        for (title, gap, bold, action) in entries {
            if gap { y += 12 }
            let row = RightRowButton(title: title, bold: bold, action: action)
            row.frame = NSRect(x: innerX, y: y, width: innerW, height: 40)
            root.addSubview(row)
            y += 40
        }

        // Shut-down split button, bottom-right.
        let shutW: CGFloat = innerW - 30
        let shut = NSButton(title: "Herunterfahren", target: self, action: #selector(shutdownAction))
        shut.bezelStyle = .rounded
        shut.font = NSFont.systemFont(ofSize: 13)
        shut.frame = NSRect(x: innerX, y: H - 50, width: shutW, height: 32)
        root.addSubview(shut)

        let arrow = NSButton(title: "▸", target: self, action: #selector(powerMenuAction(_:)))
        arrow.bezelStyle = .rounded
        arrow.frame = NSRect(x: innerX + shutW + 2, y: H - 50, width: 28, height: 32)
        root.addSubview(arrow)
    }

    // MARK: - Data

    private func toggleAllPrograms() {
        showingAll.toggle()
        alleButton?.setTitle(showingAll ? "Zurück" : "Alle Programme", back: showingAll)
        reloadList(filter: searchField.stringValue)
    }

    private func reloadList(filter: String) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()

        let apps: [AppEntry]
        if !needle.isEmpty {
            apps = allApps.filter { $0.name.lowercased().contains(needle) }
        } else if showingAll {
            apps = allApps
        } else {
            // Pinned first, then recently opened (without duplicates).
            let pinned = StartPins.entries()
            let pinnedIDs = Set(pinned.compactMap { $0.bundleID })
            let recents = RecentsStore.recent().filter { !pinnedIDs.contains($0.bundleID ?? "") }
            apps = pinned + recents
        }

        for app in apps.prefix(300) {
            let row = AppRowButton(entry: app,
                                   pinned: StartPins.isPinned(app.bundleID),
                                   onOpen: { [weak self] e in self?.launch(e) },
                                   onTogglePin: { [weak self] e in
                                       StartPins.toggle(e.bundleID)
                                       self?.reloadList(filter: self?.searchField.stringValue ?? "")
                                   })
            listStack.addArrangedSubview(row)
        }
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
        reloadList(filter: "")

        let x = max(screen.frame.minX, orbScreenRect.minX)
        let y = orbScreenRect.maxY + 1
        window.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    func hide() { window.orderOut(nil) }
    @objc private func resignedKey() { hide() }

    func controlTextDidChange(_ obj: Notification) { reloadList(filter: searchField.stringValue) }

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

    @objc private func powerMenuAction(_ sender: NSButton) {
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

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > Theme.startLeftWidth else { return } // only the root paints columns
        // Left column: white.
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: Theme.startLeftWidth, height: bounds.height).fill()

        // Right column: gradient derived from the macOS accent colour (darkened so white text stays readable).
        let rightRect = NSRect(x: Theme.startLeftWidth, y: 0,
                               width: bounds.width - Theme.startLeftWidth, height: bounds.height)
        let top = Theme.accent(brightness: 0.98, saturation: 0.85)
        let bottom = Theme.accent(brightness: 0.62, saturation: 1.0)
        NSGradient(colors: [top, bottom])?.draw(in: rightRect, angle: 90)

        // Thin divider between the two columns.
        NSColor(calibratedWhite: 1.0, alpha: 0.5).setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: Theme.startLeftWidth, y: 0))
        sep.line(to: NSPoint(x: Theme.startLeftWidth, y: bounds.height))
        sep.lineWidth = 1
        sep.stroke()
    }
}

// MARK: - Avatar

private final class AvatarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Glassy framed square, like the default Windows user picture frame.
        let frame = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        NSGradient(colors: [NSColor(calibratedWhite: 0.97, alpha: 1),
                            NSColor(calibratedWhite: 0.85, alpha: 1)])?.draw(in: path, angle: -90)
        NSColor.white.setStroke(); path.lineWidth = 2; path.stroke()

        let img = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        img?.isTemplate = false
        let inset = frame.insetBy(dx: 7, dy: 7)
        NSColor(calibratedRed: 0.30, green: 0.52, blue: 0.80, alpha: 1).set()
        img?.draw(in: inset)
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
            Theme.rightHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
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
    private var hovering = false

    init(entry: AppEntry, pinned: Bool,
         onOpen: @escaping (AppEntry) -> Void,
         onTogglePin: @escaping (AppEntry) -> Void) {
        self.entry = entry; self.pinned = pinned; self.onOpen = onOpen; self.onTogglePin = onTogglePin
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.startLeftWidth - 28, height: 50))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 50).isActive = true
        widthAnchor.constraint(equalToConstant: Theme.startLeftWidth - 28).isActive = true
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onOpen(entry) }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let title = pinned ? "Vom Startmenü lösen" : "An Startmenü anheften"
        let item = NSMenuItem(title: title, action: #selector(togglePin), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func togglePin() { onTogglePin(entry) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.accent(brightness: 1.55, saturation: 0.35, alpha: 0.30).setFill()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            p.fill(); Theme.accent(brightness: 1.1, alpha: 0.6).setStroke(); p.lineWidth = 1; p.stroke()
        }
        let iconS: CGFloat = 36
        entry.icon.draw(in: NSRect(x: 8, y: (bounds.height - iconS) / 2, width: iconS, height: iconS))
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
