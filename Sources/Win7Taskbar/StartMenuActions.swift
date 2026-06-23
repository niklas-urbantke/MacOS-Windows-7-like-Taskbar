import AppKit

/// An action that a Start-menu entry (or the avatar) can trigger.
/// `param` carries the folder path / URL / app path for the three parameterised kinds.
struct MenuAction: Codable, Equatable {
    enum Kind: String, Codable {
        // Orte
        case home, documents, downloads, desktop, pictures, music, movies, publicFolder
        case icloud, applications, utilities, computer, trash
        case openFolder            // param = Ordnerpfad
        // System
        case systemSettings, activityMonitor, terminal, launchpad, missionControl, screenshot
        // Web & Programme
        case openURL               // param = URL
        case helpApple
        case openApp               // param = App-Pfad
        // Energie
        case sleep, lock, logout, restart, shutdown
    }

    var kind: Kind
    var param: String?

    init(_ kind: Kind, param: String? = nil) { self.kind = kind; self.param = param }
}

/// One configurable entry in the Start-menu's right column.
struct MenuEntry: Codable, Equatable {
    var title: String
    var action: MenuAction
    var gapBefore: Bool
    var separatorBefore: Bool

    init(title: String, action: MenuAction, gapBefore: Bool = false, separatorBefore: Bool = false) {
        self.title = title; self.action = action
        self.gapBefore = gapBefore; self.separatorBefore = separatorBefore
    }
}

/// A pickable suggestion shown in the action chooser.
struct MenuActionOption {
    enum Param { case folder, url, app }
    let kind: MenuAction.Kind
    let title: String
    let param: Param?
    init(_ kind: MenuAction.Kind, _ title: String, _ param: Param? = nil) {
        self.kind = kind; self.title = title; self.param = param
    }
}

/// The large catalogue of action suggestions, grouped for the chooser menu.
enum MenuActionCatalog {
    static let groups: [(String, [MenuActionOption])] = [
        ("Orte", [
            MenuActionOption(.home, "Persönlicher Ordner"),
            MenuActionOption(.documents, "Dokumente"),
            MenuActionOption(.downloads, "Downloads"),
            MenuActionOption(.desktop, "Schreibtisch"),
            MenuActionOption(.pictures, "Bilder"),
            MenuActionOption(.music, "Musik"),
            MenuActionOption(.movies, "Filme"),
            MenuActionOption(.publicFolder, "Öffentlich"),
            MenuActionOption(.icloud, "iCloud Drive"),
            MenuActionOption(.applications, "Programme"),
            MenuActionOption(.utilities, "Dienstprogramme"),
            MenuActionOption(.computer, "Computer"),
            MenuActionOption(.trash, "Papierkorb"),
            MenuActionOption(.openFolder, "Bestimmten Ordner öffnen…", .folder),
        ]),
        ("System", [
            MenuActionOption(.systemSettings, "Systemeinstellungen"),
            MenuActionOption(.activityMonitor, "Aktivitätsanzeige"),
            MenuActionOption(.terminal, "Terminal"),
            MenuActionOption(.launchpad, "Launchpad"),
            MenuActionOption(.missionControl, "Mission Control"),
            MenuActionOption(.screenshot, "Bildschirmfoto"),
        ]),
        ("Web & Programme", [
            MenuActionOption(.openURL, "Website öffnen…", .url),
            MenuActionOption(.helpApple, "Hilfe und Support"),
            MenuActionOption(.openApp, "Programm öffnen…", .app),
        ]),
        ("Energie", [
            MenuActionOption(.sleep, "Ruhezustand"),
            MenuActionOption(.lock, "Bildschirm sperren"),
            MenuActionOption(.logout, "Abmelden"),
            MenuActionOption(.restart, "Neu starten"),
            MenuActionOption(.shutdown, "Herunterfahren"),
        ]),
    ]

    private static let titleByKind: [MenuAction.Kind: String] = {
        var d: [MenuAction.Kind: String] = [:]
        for (_, opts) in groups { for o in opts { d[o.kind] = o.title } }
        return d
    }()

    /// A human-readable label for an action (used in the editor and as a default entry title).
    static func title(for a: MenuAction) -> String {
        switch a.kind {
        case .openFolder:
            return a.param.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Ordner"
        case .openURL:
            return a.param.flatMap { URL(string: $0)?.host } ?? a.param ?? "Website"
        case .openApp:
            return a.param.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Programm"
        default:
            return titleByKind[a.kind] ?? a.kind.rawValue
        }
    }
}

/// Persistence for the right-column entries and the avatar action.
enum MenuEntryStore {
    private static let entriesKey = "menuEntries"
    private static let avatarKey = "menuAvatarAction"

    static var defaults: [MenuEntry] {
        [
            MenuEntry(title: "Dokumente",          action: MenuAction(.documents), gapBefore: true),
            MenuEntry(title: "Bilder",             action: MenuAction(.pictures)),
            MenuEntry(title: "Musik",              action: MenuAction(.music)),
            MenuEntry(title: "Spiele",             action: MenuAction(.applications), gapBefore: true, separatorBefore: true),
            MenuEntry(title: "Computer",           action: MenuAction(.computer)),
            MenuEntry(title: "Systemsteuerung",    action: MenuAction(.systemSettings), gapBefore: true, separatorBefore: true),
            MenuEntry(title: "Geräte und Drucker", action: MenuAction(.systemSettings)),
            MenuEntry(title: "Standardprogramme",  action: MenuAction(.systemSettings)),
            MenuEntry(title: "Hilfe und Support",  action: MenuAction(.helpApple)),
        ]
    }

    static func entries() -> [MenuEntry] {
        guard let data = UserDefaults.standard.data(forKey: entriesKey),
              let decoded = try? JSONDecoder().decode([MenuEntry].self, from: data)
        else { return defaults }
        return decoded
    }

    static func save(_ entries: [MenuEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: entriesKey) }

    static func avatarAction() -> MenuAction {
        guard let data = UserDefaults.standard.data(forKey: avatarKey),
              let a = try? JSONDecoder().decode(MenuAction.self, from: data)
        else { return MenuAction(.home) }
        return a
    }

    static func saveAvatar(_ a: MenuAction) {
        if let data = try? JSONEncoder().encode(a) {
            UserDefaults.standard.set(data, forKey: avatarKey)
        }
    }
}
