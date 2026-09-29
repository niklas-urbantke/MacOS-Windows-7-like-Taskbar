import AppKit

// Gemeinsame Bausteine der beiden Startmenüs (Windows 7 `StartMenuController` und
// Windows 11 `StartMenu11Controller`): Fenster/Hilfsviews, Icon-Cache, Spotlight-Suche,
// Starten/Öffnen, Power-Aktionen und das Rechtsklick-Menü der App-Einträge.

// MARK: - Borderless window that can still receive keyboard focus (for the search field)

class KeyableWindow: NSWindow {
    /// Optional Esc handler. When nil, Esc behaves as before (default NSWindow handling).
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
}

// MARK: - Flipped helper view (top-down coordinates)

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - NSMenuItem with a closure action

/// Menu item that runs a closure (keeps the menu code free of @objc selector plumbing).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

// MARK: - Icons (cache + asynchronous loading)

/// Something that shows an app/file icon which may arrive later (loaded off the main thread).
protocol StartMenuIconDisplaying: AnyObject {
    func updateIcon(_ img: NSImage?)
}

/// Icon cache shared by both Start menus (keyed by file path).
enum StartMenuIcons {
    private static var cache: [String: NSImage] = [:]

    static func cached(_ path: String) -> NSImage? { cache[path] }

    /// Load missing icons off the main thread, then apply + cache.
    static func load(_ pending: [(StartMenuIconDisplaying, String)]) {
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for (view, path) in pending {
                let img = NSWorkspace.shared.icon(forFile: path)
                img.size = NSSize(width: 36, height: 36)
                DispatchQueue.main.async {
                    cache[path] = img
                    view.updateIcon(img)
                }
            }
        }
    }
}

// MARK: - File & folder search (Spotlight)

/// Asynchronous Spotlight name search. Every new search bumps a token, so results of an older,
/// slower query are dropped instead of overwriting newer ones.
final class StartMenuFileSearch {
    private var token = 0

    /// Invalidate any running search (its results will be ignored).
    func cancel() { token += 1 }

    /// Runs `mdfind -name query` in the background. `completion` is called on the main thread,
    /// but only if no newer search was started and `isCurrent(query)` still holds.
    func search(_ query: String, isCurrent: @escaping (String) -> Bool,
                completion: @escaping ([AppEntry]) -> Void) {
        token += 1
        let myToken = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = StartMenuFileSearch.runMdfind(query)
            DispatchQueue.main.async {
                guard let self, myToken == self.token, isCurrent(query) else { return }
                completion(results)
            }
        }
    }

    static func runMdfind(_ query: String, limit: Int = 12) -> [AppEntry] {
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
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - Launching apps and opening paths

/// Starten und Öffnen. (Zuletzt benutzte Apps erfasst der TaskbarController selbst über die
/// Aktivierungs-Benachrichtigungen, deshalb hier kein eigenes Mitschreiben.)
enum StartMenuLaunch {
    static func launch(_ entry: AppEntry) {
        NSWorkspace.shared.openApplication(at: entry.url, configuration: .init())
    }
    /// Apps are launched, files/folders opened with their default app.
    static func open(_ entry: AppEntry, isFile: Bool) {
        if isFile { NSWorkspace.shared.open(entry.url) } else { launch(entry) }
    }
    static func openPath(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    static func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
    static func openApp(bundleID id: String, fallback path: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
    static let systemSettingsPath = "/System/Applications/System Settings.app"
}

// MARK: - Power actions

enum StartMenuPower {
    enum Action {
        case sleep, restart, shutdown, logout

        var title: String {
            switch self {
            case .sleep:    return "Energie sparen"
            case .restart:  return "Neu starten"
            case .shutdown: return "Herunterfahren"
            case .logout:   return "Abmelden"
            }
        }
        /// Restart, shut down and log out go through loginwindow, which shows the normal macOS
        /// confirmation dialog (with "Fenster beim erneuten Anmelden wieder öffnen" and the
        /// countdown), exactly like the Apple menu. System Events would skip that dialog.
        var script: String {
            switch self {
            case .sleep:    return "tell application \"System Events\" to sleep"
            case .restart:  return "tell application \"loginwindow\" to «event aevtrrst»"
            case .shutdown: return "tell application \"loginwindow\" to «event aevtrsdn»"
            case .logout:   return "tell application \"loginwindow\" to «event aevtlogo»"
            }
        }
    }

    static func runOSA(_ command: String) {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", command]
        try? p.run()
    }

    static func run(_ action: Action) { runOSA(action.script) }

    /// Power menu with the given entries (in that order). `onSelect` runs before the action
    /// (typically to close the Start menu).
    static func makeMenu(_ actions: [Action], onSelect: @escaping (Action) -> Void = { _ in }) -> NSMenu {
        let menu = NSMenu()
        for a in actions {
            menu.addItem(ClosureMenuItem(a.title) { onSelect(a); run(a) })
        }
        return menu
    }
}

// MARK: - Context menu of app entries

enum StartMenuContextMenu {
    /// Rechtsklick-Menü eines Eintrags: An Startmenü anheften/lösen und An Taskleiste anheften
    /// (nur Apps), Desktopverknüpfung erstellen (immer).
    static func make(for entry: AppEntry, pinned: Bool,
                     onTogglePin: @escaping () -> Void,
                     onPinTaskbar: (() -> Void)?) -> NSMenu {
        let menu = NSMenu()
        if entry.bundleID != nil {
            menu.addItem(ClosureMenuItem(pinned ? "Vom Startmenü lösen" : "An Startmenü anheften", onTogglePin))
            if let onPinTaskbar {
                menu.addItem(ClosureMenuItem("An Taskleiste anheften", onPinTaskbar))
            }
        }
        menu.addItem(ClosureMenuItem("Desktopverknüpfung erstellen") { createDesktopShortcut(for: entry) })
        return menu
    }

    /// Create a Finder alias for the app/file on the Desktop.
    static func createDesktopShortcut(for entry: AppEntry) {
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
}
