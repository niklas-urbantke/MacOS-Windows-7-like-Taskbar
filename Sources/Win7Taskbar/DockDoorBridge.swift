import AppKit

/// Zeigt die Fenstervorschau von DockDoor (github.com/ejbills/DockDoor) für Taskleisten-Buttons,
/// über DockDoors AppleScript-Schnittstelle (`show preview` / `hide preview`, Suite `DKDR`).
///
/// Was DockDoor erwartet (ScriptCommands.swift, SharedPreviewWindowCoordinator.swift):
/// - `dock frame "x,y,w,h"` ist ein Rechteck in globalen AppKit-Koordinaten (Ursprung unten links
///   auf dem Hauptbildschirm, y wächst nach oben). Die Vorschau steht mittig darüber, ihr Fenster
///   beginnt bei `maxY + bufferFromDock` (Standard −20); der sichtbare Teil liegt wegen des
///   transparenten Rands (24 pt) dann knapp über `maxY`. Geklemmt wird in den Bildschirm.
/// - Den Bildschirm sucht DockDoor dagegen über `at "x,y"`, gelesen als Quartz-Punkt (Ursprung oben
///   links). Fehlt `at`, nimmt es die AppKit-Mausposition und behandelt sie als Quartz-Punkt; auf
///   Nebenbildschirmen landet das leicht beim falschen Bildschirm. Deshalb schicken wir `at` immer mit.
/// - `dock position` wird von DockDoor derzeit nicht ausgewertet (intern immer „cli“ = wie unten).
/// - Ohne `with delay` erscheint die Vorschau, sobald DockDoor die Fenster geholt hat (etwa 0,3 bis
///   0,6 s); unsere Buttons warten vorher ohnehin schon.
/// - Sichtbar bleibt sie nur, solange die Maus im Rahmen (±15 pt) oder über der Vorschau steht:
///   DockDoor fragt die Mausposition alle `inactivityTimeout` (0,2 s) ab und blendet sonst aus
///   (0,4 s). Das regelt das Hover-Ende vollständig, auch den Weg vom Button in die Vorschau.
///   `hide preview` dagegen verlässt sich auf DockDoors Tracking-Area; schicken wir es beim Verlassen
///   des Buttons, verschwindet die Vorschau oft genau dann, wenn die Maus hineinwandert. Wir
///   schicken es deshalb nur bei echten Aktionen (Klick, Ziehen, Umschalten).
/// - Für die gerade spielende Medien-App (und bei Spotify/Musik) zeigt DockDoor statt der Fenster
///   sein Medien-Widget, als eigene Ansicht ohne unseren Rahmen: Es verschwindet nach einem kurzen
///   Aufblitzen wieder. Für solche Apps ruft die Brücke stattdessen `mediaFallback` auf (eigene
///   Vorschau mit den echten Fenstern), solange DockDoors Medien-Widget eingeschaltet ist.
///
/// Alle Aufrufe laufen auf einer seriellen Hintergrund-Queue. Es gibt nur einen Platz für den
/// nächsten Befehl: Beim schnellen Überfahren mehrerer Buttons geht nur der letzte hinaus.
enum DockDoorBridge {
    private enum Command {
        case show(bundleID: String, frame: NSRect, at: NSPoint, generation: Int, mediaFallback: (() -> Void)?)
        case hide
    }

    private static let queue = DispatchQueue(label: "de.batix.win7taskbar.dockdoor", qos: .userInitiated)
    private static let lock = NSLock()
    private static var pending: Command?
    private static var draining = false
    private static var loggedDenied = false
    /// Zählt jeden Show/Hide/Abbruch (unter `lock`); ein Fallback läuft nur, wenn er noch aktuell ist.
    private static var generation = 0

    // MARK: - Öffentlich (Main-Thread)

    /// `anchor`: Rahmen des Buttons in Bildschirmkoordinaten (AppKit, unten links); die Vorschau
    /// erscheint mittig über seiner Oberkante. `screen`: Bildschirm der Leiste.
    /// `mediaFallback` läuft (auf dem Main-Thread) statt der DockDoor-Vorschau, wenn DockDoor für
    /// diese App nur sein Medien-Widget zeigen würde.
    static func show(bundleID: String, anchor: NSRect, screen: NSScreen,
                     mediaFallback: (() -> Void)? = nil) {
        guard isRunning else { mediaFallback?(); return }
        // Quartz-Punkt für DockDoors Bildschirmsuche: Buttonmitte, sicher innerhalb des Bildschirms.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let sf = screen.frame
        let cx = min(max(anchor.midX, sf.minX + 1), sf.maxX - 1)
        let cy = min(max(anchor.midY, sf.minY + 1), sf.maxY - 1)
        lock.lock(); generation += 1; let g = generation; lock.unlock()
        enqueue(.show(bundleID: bundleID, frame: anchor, at: NSPoint(x: cx, y: primaryMaxY - cy),
                      generation: g, mediaFallback: mediaFallback))
    }

    /// Verbirgt die DockDoor-Vorschau sofort (Klick, Ziehen, Umschalten der Vorschau-Art).
    static func hide() {
        guard isRunning else { return }
        lock.lock(); generation += 1; lock.unlock()
        enqueue(.hide)
    }

    /// Hover-Ende: ein noch nicht abgeschicktes `show` verwerfen. Eine sichtbare Vorschau blendet
    /// DockDoor selbst aus, sobald die Maus weder über dem Button noch über der Vorschau steht.
    static func cancelPending() {
        lock.lock()
        generation += 1
        if case .show = pending { pending = nil }
        lock.unlock()
    }

    private static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Theme.dockDoorBundleID).isEmpty
    }

    // MARK: - Queue

    private static func enqueue(_ command: Command) {
        lock.lock()
        pending = command
        let startDrain = !draining
        draining = true
        lock.unlock()
        guard startDrain else { return }
        queue.async { drain() }
    }

    private static func drain() {
        while true {
            lock.lock()
            guard let command = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            if case let .show(bundleID, _, _, g, fallback?) = command, showsMediaWidget(for: bundleID) {
                // DockDoor würde nur sein Medien-Widget zeigen: eine offene DockDoor-Vorschau
                // schließen und die eigene Vorschau nehmen, falls der Hover noch aktuell ist.
                send(.hide)
                DispatchQueue.main.async {
                    lock.lock(); let current = generation == g; lock.unlock()
                    if current { fallback() }
                }
                continue
            }
            send(command)
        }
    }

    // MARK: - Medien-Apps

    private static let dockDoorDomain = Theme.dockDoorBundleID as CFString

    private static func dockDoorPref(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, dockDoorDomain)
    }

    /// Ob DockDoor für `bundleID` sein Medien-Widget statt der Fenster zeigen würde (nachgebaut aus
    /// `isMediaApp` / `MediaRemoteService.matchesMediaSource` und den Widget-Einstellungen).
    /// Läuft auf der Hintergrund-Queue (NowPlaying kann kurz warten).
    private static func showsMediaWidget(for bundleID: String) -> Bool {
        let special = dockDoorPref("showSpecialAppControls") as? Bool ?? true
        let widget = dockDoorPref("enableMediaWidget") as? Bool ?? true
        guard special, widget else { return false }
        let scriptPlayers: Set<String> = ["com.spotify.client", "com.apple.Music"]
        let mode = dockDoorPref("mediaDetectionMode").map { "\($0)" } ?? ""
        if mode.contains("appleScriptOnly") { return scriptPlayers.contains(bundleID) }
        guard let info = NowPlaying.current() else { return false }
        if !info.bundleID.isEmpty {
            let a = info.bundleID.lowercased(), b = bundleID.lowercased()
            return a == b || a.contains(b) || b.contains(a)
        }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
        return name.map { $0.caseInsensitiveCompare(info.app) == .orderedSame } ?? false
    }

    // MARK: - Apple Events

    private static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    private static func send(_ command: Command) {
        let target = NSAppleEventDescriptor(bundleIdentifier: Theme.dockDoorBundleID)
        let event: NSAppleEventDescriptor
        switch command {
        case let .show(bundleID, frame, at, _, _):
            event = NSAppleEventDescriptor.appleEvent(
                withEventClass: fourCC("DKDR"), eventID: fourCC("shpr"), targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            let f = frame.integral
            event.setParam(NSAppleEventDescriptor(string: bundleID), forKeyword: keyDirectObject)
            event.setParam(NSAppleEventDescriptor(string: "bundle"), forKeyword: fourCC("bytp"))
            event.setParam(NSAppleEventDescriptor(string: "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"),
                           forKeyword: fourCC("dkfr"))
            event.setParam(NSAppleEventDescriptor(string: "bottom"), forKeyword: fourCC("dkpo"))
            event.setParam(NSAppleEventDescriptor(string: "\(Int(at.x.rounded())),\(Int(at.y.rounded()))"),
                           forKeyword: fourCC("atps"))
        case .hide:
            event = NSAppleEventDescriptor.appleEvent(
                withEventClass: fourCC("DKDR"), eventID: fourCC("hdpr"), targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        }
        do {
            // Beim allerersten Event fragt macOS nach der Automations-Berechtigung; die Antwort
            // blockiert nur diese Queue, großzügiges Timeout.
            _ = try event.sendEvent(options: [.waitForReply], timeout: 3)
        } catch {
            // Fehler still ignorieren; nur eine verweigerte Berechtigung einmal melden.
            let code = (error as NSError).code
            if code == Int(errAEEventNotPermitted) || code == -1744 {
                lock.lock()
                let first = !loggedDenied
                loggedDenied = true
                lock.unlock()
                if first {
                    DebugLog.log("DockDoor: Automations-Berechtigung fehlt (\(code)). Systemeinstellungen > Datenschutz & Sicherheit > Automation > Windows 7 Taskleiste > DockDoor aktivieren.")
                }
            }
        }
    }
}
