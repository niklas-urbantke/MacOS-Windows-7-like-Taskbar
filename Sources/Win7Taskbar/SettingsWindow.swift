import AppKit

/// Central settings window collecting all toggles.
final class SettingsWindowController: NSObject {
    weak var controller: TaskbarController?
    private var window: NSWindow?

    private let dockBox = NSButton(checkboxWithTitle: "macOS-Dock ausblenden", target: nil, action: nil)
    private let reserveBox = NSButton(checkboxWithTitle: "Fensterbereich reservieren (Bedienungshilfen)", target: nil, action: nil)
    private let finderBox = NSButton(checkboxWithTitle: "Finder-Klick öffnet immer ein neues Fenster", target: nil, action: nil)
    private let nowPlayingBox = NSButton(checkboxWithTitle: "Now-Playing-Spieler in der Taskleiste anzeigen", target: nil, action: nil)

    func show() {
        if window == nil { build() }
        syncFromController()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Windows 7 Taskleiste – Einstellungen"
        w.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "Einstellungen")
        title.font = NSFont.boldSystemFont(ofSize: 15)

        for box in [dockBox, reserveBox, finderBox, nowPlayingBox] {
            box.target = self
            box.action = #selector(changed(_:))
        }

        let quit = NSButton(title: "Taskleiste beenden", target: self, action: #selector(quitAction))
        quit.bezelStyle = .rounded

        let stack = NSStackView(views: [title, dockBox, reserveBox, finderBox, nowPlayingBox, quit])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        w.contentView = content
        window = w
    }

    private func syncFromController() {
        guard let c = controller else { return }
        dockBox.state = c.dockIsHidden ? .on : .off
        reserveBox.state = c.reserveEnabled ? .on : .off
        finderBox.state = c.finderNewWindow ? .on : .off
        nowPlayingBox.state = c.nowPlayingEnabled ? .on : .off
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
        default:
            break
        }
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}
