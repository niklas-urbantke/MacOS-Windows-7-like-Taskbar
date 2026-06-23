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

        // Categorised tabs.
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeTab("Allgemein", [dockBox, reserveBox, autostartBox]))
        tabView.addTabViewItem(makeTab("Darstellung", [orbRow, styleRow, heightRow, fullHeightBox]))
        tabView.addTabViewItem(makeTab("Transparenz",
                                       [tbHeader, tbStyleRow, tbOpacityRow, tbBlurRow, tbGlassRow,
                                        menuHeader, menuOpacityRow, menuBlurRow]))
        tabView.addTabViewItem(makeTab("Tray", [nowPlayingBox, wifiBox, monitorBox]))
        tabView.addTabViewItem(makeTab("Finder", [finderBox, finderDesktopBox]))

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
