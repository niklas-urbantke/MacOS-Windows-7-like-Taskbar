import AppKit

/// Windows-11-Startmenü (Stil 24H2/25H2). Gleiche Schnittstelle wie `StartMenuController`.
///
/// Aufbau (von oben nach unten): Such-Pill, eine scrollbare Fläche mit „Angeheftet" (Raster)
/// und „Alle" (A-Z-Liste mit Buchstaben-Trennern), Fußleiste mit Einstellungen und Ein/Aus.
/// Beim Tippen ersetzt eine Trefferliste (Apps + Spotlight-Dateien) den Inhalt.
/// Alle Farben werden zur Zeichenzeit aus `Theme.Win11` gelesen; Maße sind fest (nicht mit der
/// Leistenhöhe skaliert).
final class StartMenu11Controller: NSObject, NSTextFieldDelegate {
    var onVisibilityChanged: ((Bool) -> Void)?
    weak var taskbarController: TaskbarController?
    var isVisible: Bool { shown }

    // MARK: Metrics

    fileprivate enum M {
        static let width: CGFloat = 860
        static let maxHeight: CGFloat = 940
        static let gapAboveBar: CGFloat = 12
        static let margin: CGFloat = 32          // horizontal content inset
        static let searchTop: CGFloat = 24
        static let searchHeight: CGFloat = 40
        static let footerHeight: CGFloat = 56
        static let columns = 8
        static let collapsedRows = 2
        static let cellHeight: CGFloat = 110
        static let rowHeight: CGFloat = 48
        static let fileRowHeight: CGFloat = 56
        static let headerHeight: CGFloat = 36
        static let letterHeight: CGFloat = 40
        static let slide: CGFloat = 12
        static let duration: TimeInterval = 0.18
    }

    // MARK: Views

    private let window: KeyableWindow
    private let root = FlippedView()
    private let blur = NSVisualEffectView()
    private let surfaceView = W11SurfaceView()
    private let searchPill = W11SearchPill()
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let homeDoc = FlippedView()          // Angeheftet + Alle
    private let searchDoc = FlippedView()        // Treffer
    private let overlay = W11LetterOverlay()
    private let settingsButton = W11IconButton(symbol: "gearshape", toolTip: "Einstellungen")
    private let powerButton = W11IconButton(symbol: "power", toolTip: "Ein/Aus")
    private let fileSearch = StartMenuFileSearch()

    // MARK: State

    private var shown = false
    private var lastAutoHide: TimeInterval = 0
    private var height: CGFloat = 720
    private var allApps: [AppEntry] = []
    private var pinsExpanded = false
    private var letterOffsets: [String: CGFloat] = [:]   // Buchstabe -> y seines Trenners in homeDoc
    private var searching = false
    private var appMatches: [AppEntry] = []
    private var fileMatches: [AppEntry] = []
    private var results: [W11ListRow] = []               // markierbare Treffer (Reihenfolge = Pfeiltasten)
    private var selectedIndex = 0

    static let letters: [String] = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

    override init() {
        window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: M.width, height: 720),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.onCancel = { [weak self] in self?.handleEscape() }

        buildContent()
        applyAppearance()

        NotificationCenter.default.addObserver(
            self, selector: #selector(resignedKey),
            name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appUninstalled),
            name: AppUninstaller.didUninstallNotification, object: nil)
    }

    /// An app was uninstalled: rescan and rebuild whatever is showing (pins, A-Z list, results).
    @objc private func appUninstalled() {
        allApps = sortedApps(AppScanner.installedApps())
        if searchField.stringValue.isEmpty { rebuildHomeKeepingScroll() } else { updateSearch() }
    }

    // MARK: - Appearance

    /// Farbmodus / Acryl neu anwenden (nach Einstellungsänderung).
    func applyAppearance() {
        window.appearance = Theme.win11NSAppearance
        Theme.Win11.configureBlur(blur)
        root.layer?.borderColor = Theme.Win11.panelStroke.cgColor
        searchField.textColor = Theme.Win11.textPrimary
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Nach Apps und Dateien suchen",
            attributes: [.foregroundColor: Theme.Win11.textSecondary,
                         .font: NSFont.systemFont(ofSize: 13)])
        for v in [root, homeDoc, searchDoc, overlay] as [NSView] { redraw(v) }
        window.invalidateShadow()
    }

    private func redraw(_ v: NSView) {
        v.needsDisplay = true
        v.subviews.forEach(redraw)
    }

    // MARK: - Build

    private func buildContent() {
        root.frame = NSRect(x: 0, y: 0, width: M.width, height: height)
        root.wantsLayer = true
        root.layer?.cornerRadius = Theme.Win11.panelRadius
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1

        // Blur (Acryl) with an explicit rounded mask: behind-window effect views do not always
        // honour the superlayer's corner clipping.
        blur.autoresizingMask = [.width, .height]
        blur.maskImage = W11Draw.roundedMask(radius: Theme.Win11.panelRadius)
        root.addSubview(blur)

        surfaceView.autoresizingMask = [.width, .height]
        root.addSubview(surfaceView)

        // Search pill with a borderless text field inside.
        root.addSubview(searchPill)
        searchField.delegate = self
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchPill.addSubview(searchField)

        // Scroll area (home or search document).
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = homeDoc
        root.addSubview(scrollView)

        overlay.isHidden = true
        overlay.onPick = { [weak self] letter in self?.jump(to: letter) }
        overlay.onDismiss = { [weak self] in self?.hideOverlay() }
        root.addSubview(overlay)

        settingsButton.onClick = { [weak self] in
            StartMenuLaunch.openPath(StartMenuLaunch.systemSettingsPath)
            self?.hide()
        }
        root.addSubview(settingsButton)

        powerButton.onClick = { [weak self] in self?.showPowerMenu() }
        root.addSubview(powerButton)

        window.contentView = root
        layout()
    }

    /// Place everything for the current `height` (depends on the screen, set in `show`).
    private func layout() {
        let W = M.width, H = height
        root.frame = NSRect(x: 0, y: 0, width: W, height: H)
        blur.frame = root.bounds
        surfaceView.frame = root.bounds
        surfaceView.footerHeight = M.footerHeight

        searchPill.frame = NSRect(x: M.margin, y: M.searchTop, width: W - 2 * M.margin, height: M.searchHeight)
        searchField.frame = NSRect(x: 40, y: (M.searchHeight - 18) / 2,
                                   width: searchPill.bounds.width - 54, height: 18)

        let scrollTop = M.searchTop + M.searchHeight + 16
        scrollView.frame = NSRect(x: 0, y: scrollTop, width: W, height: H - M.footerHeight - scrollTop)
        overlay.frame = scrollView.frame

        let by = H - M.footerHeight + (M.footerHeight - 36) / 2
        powerButton.frame = NSRect(x: W - M.margin - 36, y: by, width: 36, height: 36)
        settingsButton.frame = NSRect(x: powerButton.frame.minX - 4 - 36, y: by, width: 36, height: 36)
    }

    private var contentWidth: CGFloat { scrollView.contentSize.width }

    // MARK: - Home view (Angeheftet + Alle)

    /// Group key for the A-Z list: first letter with diacritics folded (Ä → A), digits and
    /// everything else under "#".
    static func groupKey(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "de_DE"))
        guard let c = folded.first else { return "#" }
        let up = String(c).uppercased()
        return (up.count == 1 && letters.dropFirst().contains(up)) ? up : "#"
    }

    private func sortedApps(_ apps: [AppEntry]) -> [AppEntry] {
        let keyed = apps.map { (StartMenu11Controller.groupKey($0.name), $0) }
        return keyed.sorted { a, b in
            if a.0 != b.0 {
                if a.0 == "#" { return true }
                if b.0 == "#" { return false }
                return a.0 < b.0
            }
            return a.1.name.localizedStandardCompare(b.1.name) == .orderedAscending
        }.map { $0.1 }
    }

    private func buildHome() {
        homeDoc.subviews.forEach { $0.removeFromSuperview() }
        letterOffsets = [:]
        let W = contentWidth
        let x0 = M.margin
        let innerW = W - 2 * M.margin
        var y: CGFloat = 0
        var pending: [(StartMenuIconDisplaying, String)] = []

        // 1. Angeheftet
        let pins = StartPins.entries()
        let pinHeader = W11SectionHeader(title: "Angeheftet")
        pinHeader.frame = NSRect(x: x0, y: y, width: innerW, height: M.headerHeight)
        homeDoc.addSubview(pinHeader)
        let perPage = M.columns * M.collapsedRows
        if pins.count > perPage {
            let b = W11PillButton(title: pinsExpanded ? "Weniger anzeigen" : "Alle anzeigen",
                                  chevron: pinsExpanded ? "chevron.up" : "chevron.right")
            let bw = b.preferredWidth
            b.frame = NSRect(x: x0 + innerW - bw - 4, y: y + (M.headerHeight - 24) / 2, width: bw, height: 24)
            b.onClick = { [weak self] in
                guard let self else { return }
                self.pinsExpanded.toggle()
                self.buildHome()
            }
            homeDoc.addSubview(b)
        }
        y += M.headerHeight + 4

        if pins.isEmpty {
            let hint = W11TextLine(text: "Noch keine Apps angeheftet. Rechtsklick auf eine App und „An Startmenü anheften“ wählen.",
                                   size: 12, secondary: true)
            hint.frame = NSRect(x: x0 + 12, y: y, width: innerW - 24, height: 36)
            homeDoc.addSubview(hint)
            y += 40
        } else {
            let visible = pinsExpanded ? pins : Array(pins.prefix(perPage))
            let cellW = floor(innerW / CGFloat(M.columns))
            for (i, app) in visible.enumerated() {
                let col = i % M.columns, row = i / M.columns
                let cell = W11PinCell(entry: app)
                cell.frame = NSRect(x: x0 + CGFloat(col) * cellW, y: y + CGFloat(row) * M.cellHeight,
                                    width: cellW, height: M.cellHeight)
                cell.onOpen = { [weak self] e in self?.open(e, isFile: false) }
                cell.menuProvider = { [weak self] e in self?.contextMenu(for: e, isFile: false) }
                if let img = StartMenuIcons.cached(app.url.path) { cell.iconImage = img }
                else { pending.append((cell, app.url.path)) }
                homeDoc.addSubview(cell)
            }
            let rows = (visible.count + M.columns - 1) / M.columns
            y += CGFloat(rows) * M.cellHeight
        }
        y += 20

        // 2. Alle (A-Z)
        let allHeader = W11SectionHeader(title: "Alle")
        allHeader.frame = NSRect(x: x0, y: y, width: innerW, height: M.headerHeight)
        homeDoc.addSubview(allHeader)
        y += M.headerHeight + 4

        var currentKey: String?
        for app in allApps {
            let key = StartMenu11Controller.groupKey(app.name)
            if key != currentKey {
                if currentKey != nil { y += 4 }
                currentKey = key
                let sep = W11LetterHeader(letter: key)
                sep.frame = NSRect(x: x0, y: y, width: innerW, height: M.letterHeight)
                sep.onClick = { [weak self] in self?.showOverlay() }
                homeDoc.addSubview(sep)
                letterOffsets[key] = y
                y += M.letterHeight
            }
            let row = W11ListRow(entry: app, isFile: false, subtitle: nil)
            row.frame = NSRect(x: x0, y: y, width: innerW, height: M.rowHeight)
            row.onOpen = { [weak self] e in self?.open(e, isFile: false) }
            row.menuProvider = { [weak self] e in self?.contextMenu(for: e, isFile: false) }
            if let img = StartMenuIcons.cached(app.url.path) { row.iconImage = img }
            else { pending.append((row, app.url.path)) }
            homeDoc.addSubview(row)
            y += M.rowHeight
        }
        y += 12

        homeDoc.frame = NSRect(x: 0, y: 0, width: W, height: max(y, scrollView.contentSize.height))
        StartMenuIcons.load(pending)
    }

    /// Rebuild the home view but keep its scroll position (after pin changes).
    private func rebuildHomeKeepingScroll() {
        let wasShowing = scrollView.documentView === homeDoc
        let origin = wasShowing ? scrollView.contentView.bounds.origin : .zero
        buildHome()
        if wasShowing { scrollTo(origin.y, animated: false) }
    }

    private func showHome() {
        searching = false
        results = []
        searchDoc.subviews.forEach { $0.removeFromSuperview() }
        if scrollView.documentView !== homeDoc { scrollView.documentView = homeDoc }
        scrollTo(0, animated: false)
    }

    // MARK: - Search

    private var currentQuery: String {
        searchField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func updateSearch() {
        if !overlay.isHidden { hideOverlay(animated: false) }
        let q = currentQuery
        guard !q.isEmpty else {
            fileSearch.cancel()
            fileMatches = []
            appMatches = []
            showHome()
            return
        }
        searching = true
        appMatches = matchApps(q)
        fileMatches = []
        selectedIndex = 0
        renderSearch(query: q, keepSelection: false)

        if q.count >= 2 {
            fileSearch.search(q, isCurrent: { [weak self] in self?.currentQuery == $0 },
                              completion: { [weak self] found in
                                  guard let self, self.searching else { return }
                                  self.fileMatches = found
                                  self.renderSearch(query: q, keepSelection: true)
                              })
        } else {
            fileSearch.cancel()
        }
    }

    /// Apps whose name contains the query (case/diacritic-insensitive), prefix matches first.
    private func matchApps(_ q: String) -> [AppEntry] {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var prefix: [AppEntry] = [], inner: [AppEntry] = []
        for a in allApps {
            guard let r = a.name.range(of: q, options: opts) else { continue }
            if r.lowerBound == a.name.startIndex { prefix.append(a) } else { inner.append(a) }
        }
        return Array((prefix + inner).prefix(40))
    }

    private func renderSearch(query: String, keepSelection: Bool) {
        let previouslySelected = keepSelection && results.indices.contains(selectedIndex)
            ? results[selectedIndex].entry.url : nil

        searchDoc.subviews.forEach { $0.removeFromSuperview() }
        results = []
        let W = contentWidth
        let x0 = M.margin
        let innerW = W - 2 * M.margin
        var y: CGFloat = 0
        var pending: [(StartMenuIconDisplaying, String)] = []

        func addRows(_ entries: [AppEntry], isFile: Bool) {
            for e in entries {
                let sub = isFile ? W11Draw.displayPath(e.url.deletingLastPathComponent().path) : nil
                let row = W11ListRow(entry: e, isFile: isFile, subtitle: sub)
                let h = isFile ? M.fileRowHeight : M.rowHeight
                row.frame = NSRect(x: x0, y: y, width: innerW, height: h)
                row.onOpen = { [weak self] e in self?.open(e, isFile: isFile) }
                row.menuProvider = { [weak self] e in self?.contextMenu(for: e, isFile: isFile) }
                if let img = StartMenuIcons.cached(e.url.path) { row.iconImage = img }
                else { pending.append((row, e.url.path)) }
                searchDoc.addSubview(row)
                results.append(row)
                y += h
            }
        }

        if !appMatches.isEmpty {
            let h = W11SectionHeader(title: "Apps")
            h.frame = NSRect(x: x0, y: y, width: innerW, height: M.headerHeight)
            searchDoc.addSubview(h)
            y += M.headerHeight + 4
            addRows(appMatches, isFile: false)
        }
        if !fileMatches.isEmpty {
            if !appMatches.isEmpty { y += 12 }
            let h = W11SectionHeader(title: "Dateien und Ordner")
            h.frame = NSRect(x: x0, y: y, width: innerW, height: M.headerHeight)
            searchDoc.addSubview(h)
            y += M.headerHeight + 4
            addRows(fileMatches, isFile: true)
        }
        if results.isEmpty {
            let hint = W11TextLine(text: "Keine Ergebnisse für „\(query)“", size: 13, secondary: true)
            hint.frame = NSRect(x: x0 + 12, y: y + 8, width: innerW - 24, height: 24)
            searchDoc.addSubview(hint)
            y += 40
        }
        y += 12

        searchDoc.frame = NSRect(x: 0, y: 0, width: W, height: max(y, scrollView.contentSize.height))
        if scrollView.documentView !== searchDoc {
            scrollView.documentView = searchDoc
            scrollTo(0, animated: false)
        }
        StartMenuIcons.load(pending)

        if let url = previouslySelected, let i = results.firstIndex(where: { $0.entry.url == url }) {
            selectedIndex = i
        } else {
            selectedIndex = 0
            if !keepSelection { scrollTo(0, animated: false) }
        }
        applySelection(scroll: false)
    }

    private func applySelection(scroll: Bool) {
        for (i, r) in results.enumerated() { r.selected = (i == selectedIndex) }
        if scroll, results.indices.contains(selectedIndex) {
            let r = results[selectedIndex]
            r.scrollToVisible(r.bounds)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
        applySelection(scroll: true)
    }

    // MARK: - Letter overview

    private func showOverlay() {
        overlay.available = Set(letterOffsets.keys)
        overlay.frame = scrollView.frame
        overlay.rebuild()
        overlay.alphaValue = reduceMotion ? 1 : 0
        overlay.isHidden = false
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                overlay.animator().alphaValue = 1
            }
        }
    }

    private func hideOverlay(animated: Bool = true) {
        guard !overlay.isHidden else { return }
        if !animated || reduceMotion {
            overlay.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            overlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.overlay.alphaValue < 0.01 else { return }
            self.overlay.isHidden = true
        })
    }

    /// Lands directly on the letter: no scroll animation, the overview disappears at once.
    private func jump(to letter: String) {
        hideOverlay(animated: false)
        guard let y = letterOffsets[letter] else { return }
        scrollTo(y, animated: false)
    }

    private func scrollTo(_ y: CGFloat, animated: Bool) {
        guard let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let target = NSPoint(x: 0, y: min(max(0, y), maxY))
        if animated && !reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            })
        } else {
            clip.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: - Actions

    private func open(_ entry: AppEntry, isFile: Bool) {
        StartMenuLaunch.open(entry, isFile: isFile)
        hide()
    }

    private func contextMenu(for entry: AppEntry, isFile: Bool) -> NSMenu {
        StartMenuContextMenu.make(
            for: entry,
            pinned: isFile ? false : StartPins.isPinned(entry.bundleID),
            onTogglePin: { [weak self] in
                StartPins.toggle(entry.bundleID)
                self?.rebuildHomeKeepingScroll()
            },
            onPinTaskbar: isFile ? nil : { [weak self] in
                self?.taskbarController?.pinToTaskbar(bundleID: entry.bundleID)
                self?.hide()
            })
    }

    private func showPowerMenu() {
        let menu = StartMenuPower.makeMenu([.sleep, .restart, .shutdown, .logout]) { [weak self] _ in
            self?.hide()
        }
        menu.appearance = Theme.win11NSAppearance
        let b = powerButton
        // Right-aligned with the button, opening upwards (the button view is flipped).
        let size = menu.size
        menu.popUp(positioning: nil, at: NSPoint(x: b.bounds.width - size.width, y: -size.height - 4), in: b)
    }

    private func handleEscape() {
        if !overlay.isHidden { hideOverlay() } else { hide() }
    }

    // MARK: - Show / hide

    func toggle(relativeTo startButtonScreenRect: NSRect, on screen: NSScreen) {
        if shown { hide(); return }
        // A click on the start button can first steal key status (→ auto-hide) and then toggle;
        // treat that as "close" instead of immediately reopening.
        if ProcessInfo.processInfo.systemUptime - lastAutoHide < 0.3 { return }
        show(relativeTo: startButtonScreenRect, on: screen)
    }

    func show(relativeTo startButtonScreenRect: NSRect, on screen: NSScreen) {
        let vis = screen.visibleFrame
        height = min(M.maxHeight, (vis.height * 0.85).rounded())
        shown = true

        applyAppearance()
        layout()
        allApps = sortedApps(AppScanner.installedApps())
        pinsExpanded = false
        searchField.stringValue = ""
        fileSearch.cancel()
        overlay.isHidden = true
        buildHome()
        showHome()

        // Position: bottom edge 12 px above the bar; centred on the screen or left-aligned with
        // the start button (clamped to the screen with a 12 px margin).
        let sf = screen.frame
        let y = sf.minY + Theme.barHeight + M.gapAboveBar
        var x = Theme.win11Centered ? (sf.midX - M.width / 2).rounded() : startButtonScreenRect.minX
        x = min(max(x, sf.minX + 12), sf.maxX - M.width - 12)
        let final = NSRect(x: x, y: y, width: M.width, height: height)

        NSApp.activate(ignoringOtherApps: true)
        if reduceMotion {
            window.setFrame(final, display: true)
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
        } else {
            window.setFrame(final.offsetBy(dx: 0, dy: -M.slide), display: true)
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = M.duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(final, display: true)
                window.animator().alphaValue = 1
            }
        }
        window.invalidateShadow()
        window.makeFirstResponder(searchField)
        onVisibilityChanged?(true)
    }

    func hide() {
        guard shown else { return }
        shown = false
        fileSearch.cancel()
        onVisibilityChanged?(false)
        if reduceMotion {
            window.orderOut(nil)
            return
        }
        let end = window.frame.offsetBy(dx: 0, dy: -M.slide)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = M.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(end, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.shown else { return }   // reopened meanwhile
            self.window.orderOut(nil)
            self.window.alphaValue = 1   // reset for next open
        })
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @objc private func resignedKey() {
        guard shown else { return }
        lastAutoHide = ProcessInfo.processInfo.systemUptime
        hide()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { updateSearch() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if searching, results.indices.contains(selectedIndex) {
                let r = results[selectedIndex]
                open(r.entry, isFile: r.isFile)
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if searching { moveSelection(1); return true }
            return false
        case #selector(NSResponder.moveUp(_:)):
            if searching { moveSelection(-1); return true }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            handleEscape()
            return true
        default:
            return false
        }
    }
}

// MARK: - Drawing helpers

private enum W11Draw {
    /// Stretchable rounded-rect mask image (for NSVisualEffectView.maskImage).
    static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    /// SF Symbol tinted with `color` (evaluated when drawn).
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return nil }
        return NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }

    static func drawImage(_ img: NSImage, in r: NSRect) {
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Path with the home folder abbreviated to "~".
    static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func roundedFill(_ r: NSRect, _ color: NSColor, radius: CGFloat = 4) {
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - Background surface (menu fill + footer)

private final class W11SurfaceView: NSView {
    var footerHeight: CGFloat = 56 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Win11.surface(.menu).setFill()
        bounds.fill()
        // Slightly set-off footer strip with a hairline on top.
        let footer = NSRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
        (Theme.win11Dark ? NSColor(calibratedWhite: 0, alpha: 0.14) : NSColor(calibratedWhite: 0, alpha: 0.03)).setFill()
        footer.fill(using: .sourceOver)
        Theme.Win11.hairline.setFill()
        NSRect(x: 0, y: footer.minY, width: bounds.width, height: 1).fill(using: .sourceOver)
    }
}

// MARK: - Search pill

private final class W11SearchPill: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(18, r.height / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        Theme.Win11.controlFill.setFill(); path.fill()
        Theme.Win11.controlStroke.setStroke(); path.lineWidth = 1; path.stroke()
        if let mag = W11Draw.symbol("magnifyingglass", size: 13, weight: .regular, color: Theme.Win11.textSecondary) {
            let s = mag.size
            W11Draw.drawImage(mag, in: NSRect(x: 16, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }
}

// MARK: - Base class for hoverable controls

private class W11HoverControl: NSControl {
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }
    /// Called on a completed click.
    func activate() {}

    /// Standard hover/press background.
    func drawStateFill(_ r: NSRect, radius: CGFloat = 4) {
        if pressed { W11Draw.roundedFill(r, Theme.Win11.pressedFill, radius: radius) }
        else if hovering { W11Draw.roundedFill(r, Theme.Win11.hoverFill, radius: radius) }
    }
}

// MARK: - Footer icon button (36×36)

private final class W11IconButton: W11HoverControl {
    var onClick: (() -> Void)?
    private let symbol: String

    init(symbol: String, toolTip: String) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        self.toolTip = toolTip
    }
    required init?(coder: NSCoder) { fatalError() }

    override func activate() { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        drawStateFill(bounds)
        if let img = W11Draw.symbol(symbol, size: 15, color: Theme.Win11.textPrimary) {
            let s = img.size
            W11Draw.drawImage(img, in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2,
                                              width: s.width, height: s.height))
        }
    }
}

// MARK: - Small pill button ("Alle anzeigen")

private final class W11PillButton: W11HoverControl {
    var onClick: (() -> Void)?
    private let title: String
    private let chevron: String

    init(title: String, chevron: String) {
        self.title = title; self.chevron = chevron
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var attributed: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                       .foregroundColor: Theme.Win11.textPrimary])
    }
    var preferredWidth: CGFloat { ceil(attributed.size().width) + 12 + 6 + 9 + 10 }

    override func activate() { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        Theme.Win11.controlFill.setFill(); path.fill()
        if pressed { Theme.Win11.pressedFill.setFill(); path.fill() }
        else if hovering { Theme.Win11.hoverFill.setFill(); path.fill() }
        Theme.Win11.controlStroke.setStroke(); path.lineWidth = 1; path.stroke()

        let s = attributed
        let ts = s.size()
        s.draw(at: NSPoint(x: 12, y: (bounds.height - ts.height) / 2))
        if let img = W11Draw.symbol(chevron, size: 8, weight: .semibold, color: Theme.Win11.textPrimary) {
            let isz = img.size
            W11Draw.drawImage(img, in: NSRect(x: 12 + ceil(ts.width) + 6, y: (bounds.height - isz.height) / 2,
                                              width: isz.width, height: isz.height))
        }
    }
}

// MARK: - Section header ("Angeheftet", "Alle", …)

private final class W11SectionHeader: NSView {
    private let title: String
    init(title: String) { self.title = title; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let s = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 16),
                                                               .foregroundColor: Theme.Win11.textPrimary])
        s.draw(at: NSPoint(x: 12, y: (bounds.height - s.size().height) / 2))
    }
}

/// A single line of (secondary) text, drawn with the current palette.
private final class W11TextLine: NSView {
    private let text: String
    private let size: CGFloat
    private let secondary: Bool
    init(text: String, size: CGFloat, secondary: Bool) {
        self.text = text; self.size = size; self.secondary = secondary
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: secondary ? Theme.Win11.textSecondary : Theme.Win11.textPrimary,
            .paragraphStyle: style])
        s.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - Pinned grid cell (icon 32 + name, max. 2 lines)

private final class W11PinCell: W11HoverControl, StartMenuIconDisplaying {
    let entry: AppEntry
    var iconImage: NSImage?
    var onOpen: ((AppEntry) -> Void)?
    var menuProvider: ((AppEntry) -> NSMenu?)?

    init(entry: AppEntry) {
        self.entry = entry
        super.init(frame: .zero)
        toolTip = entry.name
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateIcon(_ img: NSImage?) { iconImage = img; needsDisplay = true }
    override func activate() { onOpen?(entry) }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?(entry) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawStateFill(bounds.insetBy(dx: 2, dy: 2))
        let iconS: CGFloat = 48
        let iconTop: CGFloat = 14
        if let img = iconImage {
            W11Draw.drawImage(img, in: NSRect(x: (bounds.width - iconS) / 2, y: iconTop, width: iconS, height: iconS))
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let s = NSAttributedString(string: entry.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: Theme.Win11.textPrimary,
            .paragraphStyle: style])
        let textTop = iconTop + iconS + 7
        let maxH = ceil(NSFont.systemFont(ofSize: 12).boundingRectForFont.height * 2) + 1
        let rect = NSRect(x: 6, y: textTop, width: bounds.width - 12, height: min(maxH, bounds.height - textTop - 2))
        s.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - List row (icon 24 + name; files with a path subtitle)

private final class W11ListRow: W11HoverControl, StartMenuIconDisplaying {
    let entry: AppEntry
    let isFile: Bool
    private let subtitle: String?
    var iconImage: NSImage?
    var onOpen: ((AppEntry) -> Void)?
    var menuProvider: ((AppEntry) -> NSMenu?)?
    /// Keyboard selection in the search results.
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }

    init(entry: AppEntry, isFile: Bool, subtitle: String?) {
        self.entry = entry; self.isFile = isFile; self.subtitle = subtitle
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateIcon(_ img: NSImage?) { iconImage = img; needsDisplay = true }
    override func activate() { onOpen?(entry) }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?(entry) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 1)
        if selected {
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            Theme.Win11.activeFill.setFill(); p.fill()
            Theme.Win11.activeStroke.setStroke(); p.lineWidth = 1; p.stroke()
            if hovering { Theme.Win11.hoverFill.setFill(); p.fill() }
        } else {
            drawStateFill(r)
        }

        let iconS: CGFloat = 36
        if let img = iconImage {
            W11Draw.drawImage(img, in: NSRect(x: 12, y: (bounds.height - iconS) / 2, width: iconS, height: iconS))
        }
        let textX: CGFloat = 12 + iconS + 12
        let textW = bounds.width - textX - 12
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: entry.name, attributes: [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: Theme.Win11.textPrimary,
            .paragraphStyle: style])
        let nh = name.size().height
        if let subtitle {
            let sub = NSAttributedString(string: subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: Theme.Win11.textSecondary,
                .paragraphStyle: style])
            let sh = sub.size().height
            let top = (bounds.height - nh - sh - 1) / 2
            name.draw(with: NSRect(x: textX, y: top, width: textW, height: nh), options: [.usesLineFragmentOrigin])
            sub.draw(with: NSRect(x: textX, y: top + nh + 1, width: textW, height: sh), options: [.usesLineFragmentOrigin])
        } else {
            name.draw(with: NSRect(x: textX, y: (bounds.height - nh) / 2, width: textW, height: nh),
                      options: [.usesLineFragmentOrigin])
        }
    }
}

// MARK: - Letter separator in the A-Z list (click opens the letter overview)

private final class W11LetterHeader: W11HoverControl {
    private let letter: String
    var onClick: (() -> Void)?

    init(letter: String) {
        self.letter = letter
        super.init(frame: .zero)
        toolTip = "Buchstabenübersicht"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func activate() { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let s = NSAttributedString(string: letter, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: Theme.Win11.textPrimary])
        let ts = s.size()
        // Hover field: a compact rounded box around the letter.
        let box = NSRect(x: 10, y: (bounds.height - 32) / 2, width: max(32, ceil(ts.width) + 18), height: 32)
        drawStateFill(box)
        s.draw(at: NSPoint(x: box.midX - ts.width / 2, y: (bounds.height - ts.height) / 2))
    }
}

// MARK: - Letter overview ("#" + A-Z)

private final class W11LetterOverlay: NSView {
    var available: Set<String> = []
    var onPick: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    private let cols = 7
    private let cell: CGFloat = 60

    override var isFlipped: Bool { true }

    func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let letters = StartMenu11Controller.letters
        let rows = (letters.count + cols - 1) / cols
        let gridW = CGFloat(cols) * cell, gridH = CGFloat(rows) * cell
        let x0 = ((bounds.width - gridW) / 2).rounded()
        let y0 = max(16, ((bounds.height - gridH) / 2 - 20).rounded())
        for (i, l) in letters.enumerated() {
            let c = W11LetterCell(letter: l, enabled: available.contains(l))
            c.frame = NSRect(x: x0 + CGFloat(i % cols) * cell, y: y0 + CGFloat(i / cols) * cell,
                             width: cell, height: cell)
            c.onPick = { [weak self] l in self?.onPick?(l) }
            addSubview(c)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Opaque enough that the list underneath does not show through.
        let base = Theme.Win11.surface(.menu)
        base.withAlphaComponent(max(0.97, base.alphaComponent)).setFill()
        bounds.fill()
    }

    // Swallow clicks/scrolling on the background; a click outside the letters closes the overview.
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func scrollWheel(with event: NSEvent) {}
}

private final class W11LetterCell: W11HoverControl {
    private let letter: String
    private let enabledLetter: Bool
    var onPick: ((String) -> Void)?

    init(letter: String, enabled: Bool) {
        self.letter = letter; self.enabledLetter = enabled
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { if enabledLetter { super.mouseEntered(with: event) } }
    override func mouseDown(with event: NSEvent) { if enabledLetter { super.mouseDown(with: event) } }
    override func activate() { onPick?(letter) }

    override func draw(_ dirtyRect: NSRect) {
        if enabledLetter { drawStateFill(bounds.insetBy(dx: 2, dy: 2)) }
        let s = NSAttributedString(string: letter, attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: enabledLetter ? .semibold : .regular),
            .foregroundColor: enabledLetter ? Theme.Win11.textPrimary : Theme.Win11.textDisabled])
        let ts = s.size()
        s.draw(at: NSPoint(x: (bounds.width - ts.width) / 2, y: (bounds.height - ts.height) / 2))
    }
}
