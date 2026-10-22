import AppKit

/// What the Windows 7 notification flyout can show. macOS has no API to read other apps'
/// notifications, so it gathers what an app may read:
/// - Apple Mail: unread inbox messages (sender, subject, date) via AppleScript — only while Mail
///   runs (it is never launched for this); needs the Automation permission for Mail.
/// - Slack, Teams, Outlook, … : the unread count of every app with a Dock badge (DockBadges,
///   Accessibility) — the message text itself isn't available.
/// - Calendar: today's remaining and tomorrow's events (CalendarEvents, if "Termine" is on).
enum NotificationSources {
    struct Item {
        let app: String
        let icon: NSImage?
        let title: String
        let body: String?
        let date: Date?
        let open: () -> Void
    }

    private static let queue = DispatchQueue(label: "notification.sources", qos: .userInitiated)

    /// Collects everything in the background; `done` runs on the main queue, newest first per app.
    static func gather(_ done: @escaping ([Item]) -> Void) {
        let badges = DockBadges.current()
        let mailRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
        queue.async {
            var items: [Item] = []
            if mailRunning { items += mailItems() }
            let calendar = calendarItems()
            DispatchQueue.main.async {
                done(calendar + items + badgeItems(badges, skipMail: mailRunning))
            }
        }
    }

    // MARK: Mail

    private static func mailItems() -> [Item] {
        let script = """
        tell application "Mail"
            set res to {}
            set msgs to (messages of inbox whose read status is false)
            set n to count of msgs
            if n > 15 then set n to 15
            repeat with i from 1 to n
                set m to item i of msgs
                set end of res to (sender of m) & tab & (subject of m) & tab & ((date received of m) as «class isot» as string) & tab & (message id of m)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return res as text
        end tell
        """
        let out = run(script)
        let icon = appIcon("com.apple.mail")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        iso.timeZone = .current
        return out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 4 else { return nil }
            let sender = f[0].replacingOccurrences(of: #"\s*<[^>]*>"#, with: "", options: .regularExpression)
            let id = f[3]
            return Item(app: "Mail", icon: icon, title: sender.isEmpty ? f[0] : sender,
                        body: f[1].isEmpty ? "(Kein Betreff)" : f[1], date: iso.date(from: f[2])) {
                let enc = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
                if let url = URL(string: "message://%3C\(enc)%3E") { NSWorkspace.shared.open(url) }
            }
        }
    }

    // MARK: Dock badges

    private static func badgeItems(_ badges: [String: String], skipMail: Bool) -> [Item] {
        let running = NSWorkspace.shared.runningApplications
        return badges.keys.sorted().compactMap { name in
            let app = running.first { $0.localizedName == name }
            if skipMail && app?.bundleIdentifier == "com.apple.mail" { return nil }   // listed in detail above
            let badge = badges[name] ?? ""
            let text: String
            if let n = Int(badge) {
                text = n == 1 ? "1 ungelesene Benachrichtigung" : "\(n) ungelesene Benachrichtigungen"
            } else {
                text = "Neue Benachrichtigungen"
            }
            return Item(app: name, icon: app?.icon, title: name, body: text, date: nil) {
                if let url = app?.bundleURL { NSWorkspace.shared.open(url) } else { app?.activate() }
            }
        }
    }

    // MARK: Calendar

    private static func calendarItems() -> [Item] {
        guard CalendarEvents.enabled else { return [] }
        let now = Date()
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let events = CalendarEvents.shared.events(on: now).filter { $0.end > now } + CalendarEvents.shared.events(on: tomorrow)
        let icon = appIcon("com.apple.iCal")
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        return events.prefix(10).map { e in
            let day = cal.isDateInToday(e.start) || e.start < now ? "Heute" : "Morgen"
            let when = e.isAllDay ? "\(day), ganztägig" : "\(day), \(tf.string(from: e.start))–\(tf.string(from: e.end))"
            // Online-meeting links as "location" would only clutter the entry.
            let place = e.location.flatMap { $0.contains("://") || $0.hasPrefix("www.") ? nil : $0 }
            let body = [when, place].compactMap { $0 }.joined(separator: " · ")
            return Item(app: "Kalender", icon: icon, title: e.title, body: body, date: e.start) {
                CalendarEvents.shared.open(e)
            }
        }
    }

    // MARK: Helpers

    private static func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private static func run(_ script: String) -> String {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
