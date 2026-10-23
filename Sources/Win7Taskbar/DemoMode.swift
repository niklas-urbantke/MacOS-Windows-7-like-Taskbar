import AppKit

/// Demo mode for anonymised screenshots (`defaults write de.batix.win7taskbar demoMode -bool true`):
/// placeholder user, apps from `demoHiddenApps` (bundle IDs) hidden from taskbar and Start menu,
/// and sample content instead of the real networks, notifications and the playing track.
enum DemoMode {
    static var on: Bool { UserDefaults.standard.bool(forKey: "demoMode") }

    /// True when `bundleID` should not appear on screenshots.
    static func hides(_ bundleID: String?) -> Bool {
        guard on, let id = bundleID else { return false }
        return (UserDefaults.standard.stringArray(forKey: "demoHiddenApps") ?? []).contains(id)
    }

    static let wifiNetworks: [WifiManager.Network] = [
        .init(ssid: "Heimnetz", rssi: -42, secure: true, known: true, current: true),
        .init(ssid: "Gastnetz", rssi: -58, secure: true, known: true, current: false),
        .init(ssid: "Nachbarschaft", rssi: -67, secure: true, known: false, current: false),
        .init(ssid: "Café am Markt", rssi: -74, secure: false, known: false, current: false),
        .init(ssid: "Büro", rssi: -81, secure: true, known: true, current: false),
    ]

    static var notifications: [NotificationSources.Item] {
        func icon(_ id: String) -> NSImage? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        let now = Date()
        return [
            .init(app: "Kalender", icon: icon("com.apple.iCal"), title: "Team-Besprechung", body: "Heute, 15:00–15:30 · Raum 2",
                  date: now.addingTimeInterval(2 * 3600)) {},
            .init(app: "Kalender", icon: icon("com.apple.iCal"), title: "Zahnarzt", body: "Morgen, 09:30–10:00", date: now.addingTimeInterval(20 * 3600)) {},
            .init(app: "Mail", icon: icon("com.apple.mail"), title: "Erika Musterfrau", body: "Projektstand und nächste Schritte",
                  date: now.addingTimeInterval(-8 * 60)) {},
            .init(app: "Mail", icon: icon("com.apple.mail"), title: "Max Mustermann", body: "Re: Urlaubsplanung",
                  date: now.addingTimeInterval(-3 * 3600)) {},
            .init(app: "Slack", icon: icon("com.tinyspeck.slackmacgap"), title: "Slack", body: "3 ungelesene Benachrichtigungen", date: nil) {},
        ]
    }

    static let track = NowPlaying.Info(app: "Spotify", title: "Beispieltitel", artist: "Beispielinterpret",
                                       playing: true, fraction: 0.35, bundleID: "com.spotify.client")
}
