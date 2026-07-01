import AppKit
import UniformTypeIdentifiers

/// Central settings window collecting all toggles.
final class SettingsWindowController: NSObject {
    weak var controller: TaskbarController?
    private var window: NSWindow?

    private let dockBox = NSButton(checkboxWithTitle: "macOS-Dock ausblenden", target: nil, action: nil)
    private let reserveBox = NSButton(checkboxWithTitle: "Fensterbereich reservieren (Bedienungshilfen)", target: nil, action: nil)
    private let finderBox = NSButton(checkboxWithTitle: "Finder-Klick öffnet immer ein neues Fenster", target: nil, action: nil)
    private let nowPlayingBox = NSButton(checkboxWithTitle: "Now-Playing-Spieler in der Taskleiste anzeigen", target: nil, action: nil)
    private let wifiBox = NSButton(checkboxWithTitle: "WLAN-Symbol anzeigen", target: nil, action: nil)
    private let monitorBox = NSButton(checkboxWithTitle: "Hardware-Monitor (CPU/RAM) anzeigen", target: nil, action: nil)
    private let autostartBox = NSButton(checkboxWithTitle: "Beim Anmelden automatisch starten", target: nil, action: nil)
    private let finderDesktopBox = NSButton(checkboxWithTitle: "Finder-Desktopfenster nicht als Fenster zählen", target: nil, action: nil)
    private let fullHeightBox = NSButton(checkboxWithTitle: "Icon-Rahmen über volle Höhe", target: nil, action: nil)
    private let orbPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var orbs: [(label: String, file: String)] = []
    private let menuStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let menuStyles: [(label: String, value: String)] = [("Akzentfarbe", "accent"), ("Taskbar (Aero)", "aero")]
    private let heightSlider = NSSlider(frame: .zero)
    private let heightLabel = NSTextField(labelWithString: "")

    // Startmenü-Tastenkürzel-Rekorder.
    private let hotkeyButton = HotkeyRecorderButton(title: "—", target: nil, action: nil)

    // Finder-Symbol (nur für diese Taskleiste).
    private let finderIconStatus = NSTextField(labelWithString: "")

    // Taskleisten-Stil-Profil.
    private let taskbarStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let taskbarStyles: [(label: String, value: String)] = [("Windows Vista", "vista"), ("Windows 7", "win7")]

    // Transparenz / Unschärfe (getrennt für Taskleiste und Startmenü).
    private let taskbarOpacitySlider = NSSlider(frame: .zero)
    private let taskbarOpacityLabel = NSTextField(labelWithString: "")
    private let taskbarBlurSlider = NSSlider(frame: .zero)
    private let taskbarBlurLabel = NSTextField(labelWithString: "")
    private let win7GlassSlider = NSSlider(frame: .zero)
    private let win7GlassLabel = NSTextField(labelWithString: "")
    private let menuOpacitySlider = NSSlider(frame: .zero)
    private let menuOpacityLabel = NSTextField(labelWithString: "")
    private let menuBlurSlider = NSSlider(frame: .zero)
    private let menuBlurLabel = NSTextField(labelWithString: "")

    func show() {
        if window == nil { build() }
        reloadOrbPopup()        // pick up orbs added/dropped since last time
        syncFromController()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 330),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Windows 7 Taskleiste – Einstellungen"
        w.isReleasedWhenClosed = false

        // Start-orb selection.
        orbPopup.target = self
        orbPopup.action = #selector(orbChanged)
        reloadOrbPopup()
        let addButton = NSButton(title: "Orb hinzufügen…", target: self, action: #selector(addOrbAction))
        addButton.bezelStyle = .rounded
        let folderButton = NSButton(title: "Ordner…", target: self, action: #selector(openFolderAction))
        folderButton.bezelStyle = .rounded
        let orbRow = NSStackView(views: [NSTextField(labelWithString: "Start-Symbol:"),
                                         orbPopup, addButton, folderButton])
        orbRow.orientation = .horizontal
        orbRow.spacing = 8

        // Start-menu style.
        menuStylePopup.removeAllItems()
        menuStylePopup.addItems(withTitles: menuStyles.map { $0.label })
        menuStylePopup.target = self
        menuStylePopup.action = #selector(menuStyleChanged)
        let menuEditButton = NSButton(title: "Rechte Spalte bearbeiten…", target: self, action: #selector(openMenuEditor))
        menuEditButton.bezelStyle = .rounded
        let styleRow = NSStackView(views: [NSTextField(labelWithString: "Startmenü-Stil:"), menuStylePopup, menuEditButton])
        styleRow.orientation = .horizontal
        styleRow.spacing = 8

        // Bar height.
        heightSlider.isContinuous = false   // apply on release (relayout is heavy)
        heightSlider.target = self
        heightSlider.action = #selector(heightChanged)
        heightSlider.translatesAutoresizingMaskIntoConstraints = false
        heightSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let heightRow = NSStackView(views: [NSTextField(labelWithString: "Leistenhöhe:"), heightSlider, heightLabel])
        heightRow.orientation = .horizontal
        heightRow.spacing = 8

        // Taskleisten-Stil-Profil.
        taskbarStylePopup.removeAllItems()
        taskbarStylePopup.addItems(withTitles: taskbarStyles.map { $0.label })
        taskbarStylePopup.target = self
        taskbarStylePopup.action = #selector(taskbarStyleChanged)
        let tbStyleRow = NSStackView(views: [NSTextField(labelWithString: "Stil-Profil:"), taskbarStylePopup])
        tbStyleRow.orientation = .horizontal
        tbStyleRow.spacing = 8

        // Transparenz / Unschärfe – je ein Regler (0–100 %) für Taskleiste und Startmenü.
        let tbOpacityRow = makeSurfaceRow("Deckkraft:", taskbarOpacitySlider, taskbarOpacityLabel,
                                          #selector(taskbarOpacityChanged))
        let tbBlurRow = makeSurfaceRow("Unschärfe:", taskbarBlurSlider, taskbarBlurLabel,
                                       #selector(taskbarBlurChanged))
        let tbGlassRow = makeSurfaceRow("Icon-Glas:", win7GlassSlider, win7GlassLabel,
                                        #selector(win7GlassChanged))
        let menuOpacityRow = makeSurfaceRow("Deckkraft:", menuOpacitySlider, menuOpacityLabel,
                                            #selector(menuOpacityChanged))
        let menuBlurRow = makeSurfaceRow("Unschärfe:", menuBlurSlider, menuBlurLabel,
                                         #selector(menuBlurChanged))
        let tbHeader = NSTextField(labelWithString: "Taskleiste")
        tbHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let menuHeader = NSTextField(labelWithString: "Startmenü")
        menuHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        for box in [dockBox, reserveBox, finderBox, finderDesktopBox, nowPlayingBox,
                    wifiBox, monitorBox, autostartBox, fullHeightBox] {
            box.target = self
            box.action = #selector(changed(_:))
        }

        // Start-menu shortcut recorder.
        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.target = self
        hotkeyButton.action = #selector(recordHotkey)
        hotkeyButton.onCapture = { [weak self] keyCode, mods, chars in
            guard let self else { return }
            let modOnly = (keyCode == HotkeyRecorderButton.modifierOnly)
            let label = modOnly
                ? SettingsWindowController.modString(mods)
                : SettingsWindowController.shortcutString(mods, keyCode, chars)
            self.controller?.setStartHotkey(keyCode: modOnly ? -1 : Int(keyCode), mods: mods.rawValue, label: label)
            self.hotkeyButton.title = label
        }
        hotkeyButton.onCancel = { [weak self] in
            self?.hotkeyButton.title = self?.controller?.startHotkeyLabel ?? "—"
        }
        let hotkeyClear = NSButton(title: "Zurücksetzen", target: self, action: #selector(clearHotkey))
        hotkeyClear.bezelStyle = .rounded
        let hotkeyRow = NSStackView(views: [NSTextField(labelWithString: "Startmenü-Kürzel:"),
                                            hotkeyButton, hotkeyClear])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8

        // Custom Finder icon (this taskbar only).
        let finderIconButton = NSButton(title: "Bild wählen…", target: self, action: #selector(chooseFinderIcon))
        finderIconButton.bezelStyle = .rounded
        let finderIconReset = NSButton(title: "Zurücksetzen", target: self, action: #selector(resetFinderIcon))
        finderIconReset.bezelStyle = .rounded
        let finderIconRow = NSStackView(views: [NSTextField(labelWithString: "Finder-Symbol:"),
                                                finderIconButton, finderIconReset, finderIconStatus])
        finderIconRow.orientation = .horizontal
        finderIconRow.spacing = 8

        // Categorised tabs.
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeTab("Allgemein", [dockBox, reserveBox, autostartBox, hotkeyRow]))
        tabView.addTabViewItem(makeTab("Darstellung", [orbRow, styleRow, heightRow, fullHeightBox]))
        tabView.addTabViewItem(makeTab("Transparenz",
                                       [tbHeader, tbStyleRow, tbOpacityRow, tbBlurRow, tbGlassRow,
                                        menuHeader, menuOpacityRow, menuBlurRow]))
        tabView.addTabViewItem(makeTab("Tray", [nowPlayingBox, wifiBox, monitorBox]))
        tabView.addTabViewItem(makeTab("Finder", [finderBox, finderDesktopBox, finderIconRow]))

        let quit = NSButton(title: "Taskleiste beenden", target: self, action: #selector(quitAction))
        quit.bezelStyle = .rounded
        quit.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tabView)
        content.addSubview(quit)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            quit.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 14),
            quit.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            quit.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        w.contentView = content
        window = w
    }

    private func makeTab(_ title: String, _ views: [NSView]) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
        ])
        item.view = v
        return item
    }

    private func makeSurfaceRow(_ title: String, _ slider: NSSlider,
                                _ valueLabel: NSTextField, _ action: Selector) -> NSStackView {
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true        // Vorschau in Echtzeit (nur alphaValue, günstig)
        slider.target = self
        slider.action = action
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let row = NSStackView(views: [label, slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }

    @objc private func taskbarOpacityChanged() {
        controller?.setTaskbarOpacity(CGFloat(taskbarOpacitySlider.doubleValue))
        taskbarOpacityLabel.stringValue = percent(taskbarOpacitySlider.doubleValue)
    }
    @objc private func taskbarBlurChanged() {
        controller?.setTaskbarBlur(CGFloat(taskbarBlurSlider.doubleValue))
        taskbarBlurLabel.stringValue = percent(taskbarBlurSlider.doubleValue)
    }
    @objc private func win7GlassChanged() {
        controller?.setWin7GlassStrength(CGFloat(win7GlassSlider.doubleValue))
        win7GlassLabel.stringValue = percent(win7GlassSlider.doubleValue)
    }
    @objc private func menuOpacityChanged() {
        controller?.setMenuOpacity(CGFloat(menuOpacitySlider.doubleValue))
        menuOpacityLabel.stringValue = percent(menuOpacitySlider.doubleValue)
    }
    @objc private func menuBlurChanged() {
        controller?.setMenuBlur(CGFloat(menuBlurSlider.doubleValue))
        menuBlurLabel.stringValue = percent(menuBlurSlider.doubleValue)
    }

    private func syncFromController() {
        guard let c = controller else { return }
        dockBox.state = c.dockIsHidden ? .on : .off
        reserveBox.state = c.reserveEnabled ? .on : .off
        finderBox.state = c.finderNewWindow ? .on : .off
        nowPlayingBox.state = c.nowPlayingEnabled ? .on : .off
        wifiBox.state = c.wifiEnabled ? .on : .off
        monitorBox.state = c.monitorEnabled ? .on : .off
        autostartBox.state = c.autostartEnabled ? .on : .off
        hotkeyButton.title = c.startHotkeyLabel
        updateFinderIconStatus()
        finderDesktopBox.state = c.hideFinderDesktopEnabled ? .on : .off
        fullHeightBox.state = c.fullHeightIcons ? .on : .off
        if let idx = orbs.firstIndex(where: { $0.file == c.selectedOrbFile }) {
            orbPopup.selectItem(at: idx)
        }
        if let idx = menuStyles.firstIndex(where: { $0.value == c.menuStyle }) {
            menuStylePopup.selectItem(at: idx)
        }
        heightSlider.minValue = Double(c.minBarHeight)
        heightSlider.maxValue = Double(c.maxBarHeight)
        heightSlider.doubleValue = Double(c.barHeightValue)
        heightLabel.stringValue = "\(Int(c.barHeightValue)) px"

        if let idx = taskbarStyles.firstIndex(where: { $0.value == c.taskbarStyle }) {
            taskbarStylePopup.selectItem(at: idx)
        }
        taskbarOpacitySlider.doubleValue = Double(c.taskbarOpacity)
        taskbarOpacityLabel.stringValue = percent(Double(c.taskbarOpacity))
        taskbarBlurSlider.doubleValue = Double(c.taskbarBlur)
        taskbarBlurLabel.stringValue = percent(Double(c.taskbarBlur))
        win7GlassSlider.doubleValue = Double(c.win7GlassStrength)
        win7GlassLabel.stringValue = percent(Double(c.win7GlassStrength))
        menuOpacitySlider.doubleValue = Double(c.menuOpacity)
        menuOpacityLabel.stringValue = percent(Double(c.menuOpacity))
        menuBlurSlider.doubleValue = Double(c.menuBlur)
        menuBlurLabel.stringValue = percent(Double(c.menuBlur))
    }

    @objc private func heightChanged() {
        let v = heightSlider.doubleValue.rounded()
        controller?.setBarHeight(CGFloat(v))
        heightLabel.stringValue = "\(Int(v)) px"
    }

    @objc private func orbChanged() {
        guard let c = controller, orbPopup.indexOfSelectedItem >= 0,
              orbPopup.indexOfSelectedItem < orbs.count else { return }
        c.setOrb(orbs[orbPopup.indexOfSelectedItem].file)
    }

    private func reloadOrbPopup() {
        orbs = controller?.availableOrbs ?? []
        orbPopup.removeAllItems()
        orbPopup.addItems(withTitles: orbs.map { $0.label })
        if let file = controller?.selectedOrbFile,
           let idx = orbs.firstIndex(where: { $0.file == file }) {
            orbPopup.selectItem(at: idx)
        }
    }

    @objc private func taskbarStyleChanged() {
        let i = taskbarStylePopup.indexOfSelectedItem
        guard i >= 0, i < taskbarStyles.count else { return }
        controller?.setTaskbarStyle(taskbarStyles[i].value)
        syncFromController()   // das Profil ändert die empfohlenen Blur-/Deckkraftwerte
    }

    @objc private func openMenuEditor() { controller?.openMenuEditor() }

    // MARK: - Custom Finder icon

    @objc private func chooseFinderIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image, .icns]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Bild für das Finder-Symbol dieser Taskleiste wählen"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            self.controller?.setFinderIcon(from: url)
            self.updateFinderIconStatus()
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    @objc private func resetFinderIcon() {
        controller?.clearFinderIcon()
        updateFinderIconStatus()
    }

    private func updateFinderIconStatus() {
        finderIconStatus.stringValue = (controller?.hasCustomFinderIcon ?? false) ? "eigenes Bild aktiv" : "Standard"
    }

    // MARK: - Start-menu shortcut recorder

    @objc private func recordHotkey() {
        hotkeyButton.title = "Tasten drücken… (Esc bricht ab)"
        hotkeyButton.beginRecording()
    }

    @objc private func clearHotkey() {
        controller?.clearStartHotkey()
        hotkeyButton.title = controller?.startHotkeyLabel ?? "—"
    }

    private static func modString(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.function) { s += "fn" }
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }

    private static func shortcutString(_ mods: NSEvent.ModifierFlags, _ keyCode: UInt16, _ chars: String?) -> String {
        modString(mods) + keyName(keyCode, chars)
    }

    private static func keyName(_ keyCode: UInt16, _ chars: String?) -> String {
        switch keyCode {
        case 53: return "⎋"
        case 49: return "Leertaste"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"; case 100: return "F8"
        case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        default:
            if let c = chars, !c.isEmpty, c != " " { return c.uppercased() }
            return "Taste \(keyCode)"
        }
    }

    @objc private func menuStyleChanged() {
        let i = menuStylePopup.indexOfSelectedItem
        guard i >= 0, i < menuStyles.count else { return }
        controller?.setMenuStyle(menuStyles[i].value)
    }

    @objc private func addOrbAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "PNG mit drei gestapelten Zuständen (normal / Hover / gedrückt) wählen"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self, let c = self.controller else { return }
            if let file = c.addOrb(from: url) {
                self.reloadOrbPopup()
                if let idx = self.orbs.firstIndex(where: { $0.file == file }) {
                    self.orbPopup.selectItem(at: idx)
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    @objc private func openFolderAction() { controller?.openOrbsFolder() }

    @objc private func changed(_ sender: NSButton) {
        guard let c = controller else { return }
        let on = sender.state == .on
        switch sender {
        case dockBox:
            c.setDockHidden(on)
        case reserveBox:
            if on {
                if !c.setReserveEnabled(true) {
                    sender.state = .off
                    let alert = NSAlert()
                    alert.messageText = "Berechtigung Bedienungshilfen nötig"
                    alert.informativeText = "Bitte aktiviere Win7Taskbar unter Systemeinstellungen → "
                        + "Datenschutz & Sicherheit → Bedienungshilfen und setze den Haken erneut."
                    alert.runModal()
                }
            } else {
                _ = c.setReserveEnabled(false)
            }
        case finderBox:
            c.setFinderNewWindow(on)
        case nowPlayingBox:
            c.setShowNowPlaying(on)
        case wifiBox:
            c.setShowWifi(on)
        case monitorBox:
            c.setShowMonitor(on)
        case autostartBox:
            c.setAutostart(on)
        case finderDesktopBox:
            c.setHideFinderDesktop(on)
        case fullHeightBox:
            c.setFullHeightIcons(on)
        default:
            break
        }
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}

/// A button that records a key combination: while recording it becomes first responder and captures
/// the next key (with modifiers) directly — including ⌘-combos via performKeyEquivalent. Esc cancels.
final class HotkeyRecorderButton: NSButton {
    /// Sentinel keyCode meaning "modifiers only" (e.g. ⌃⌘ with no regular key).
    static let modifierOnly: UInt16 = 0xFFFF
    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    var onCapture: ((UInt16, NSEvent.ModifierFlags, String?) -> Void)?
    var onCancel: (() -> Void)?
    private var recording = false
    private var pendingMods: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }

    func beginRecording() {
        recording = true
        pendingMods = []
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { handleKey(event); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if recording { handleKey(event) } else { super.keyDown(with: event) }
    }

    // Modifier-only combos (⌃⌘ etc.) only produce flagsChanged: accumulate while held, commit on release.
    override func flagsChanged(with event: NSEvent) {
        guard recording else { super.flagsChanged(with: event); return }
        let mods = event.modifierFlags.intersection(Self.mask)
        if mods.isEmpty {
            if modCount(pendingMods) >= 2 {
                recording = false
                onCapture?(Self.modifierOnly, pendingMods, nil)
            }
            pendingMods = []
        } else {
            pendingMods.formUnion(mods)
        }
    }

    private func handleKey(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(Self.mask)
        if e.keyCode == 53 && mods.isEmpty { recording = false; onCancel?(); return }  // Esc cancels
        guard !mods.isEmpty else { return }                                            // need a modifier
        recording = false
        onCapture?(e.keyCode, mods, e.charactersIgnoringModifiers)
    }

    private func modCount(_ m: NSEvent.ModifierFlags) -> Int {
        [.command, .option, .control, .shift, .function].reduce(0) { $0 + (m.contains($1) ? 1 : 0) }
    }
}
