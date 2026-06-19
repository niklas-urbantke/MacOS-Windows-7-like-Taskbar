import AppKit

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

    func show() {
        if window == nil { build() }
        syncFromController()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 280),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Windows 7 Taskleiste – Einstellungen"
        w.isReleasedWhenClosed = false

        // Start-orb selection.
        orbs = controller?.availableOrbs ?? []
        orbPopup.removeAllItems()
        orbPopup.addItems(withTitles: orbs.map { $0.label })
        orbPopup.target = self
        orbPopup.action = #selector(orbChanged)
        let orbRow = NSStackView(views: [NSTextField(labelWithString: "Start-Symbol:"), orbPopup])
        orbRow.orientation = .horizontal
        orbRow.spacing = 8

        for box in [dockBox, reserveBox, finderBox, finderDesktopBox, nowPlayingBox,
                    wifiBox, monitorBox, autostartBox, fullHeightBox] {
            box.target = self
            box.action = #selector(changed(_:))
        }

        // Categorised tabs.
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeTab("Allgemein", [dockBox, reserveBox, autostartBox]))
        tabView.addTabViewItem(makeTab("Darstellung", [orbRow, fullHeightBox]))
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
    }

    @objc private func orbChanged() {
        guard let c = controller, orbPopup.indexOfSelectedItem >= 0,
              orbPopup.indexOfSelectedItem < orbs.count else { return }
        c.setOrb(orbs[orbPopup.indexOfSelectedItem].file)
    }

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
