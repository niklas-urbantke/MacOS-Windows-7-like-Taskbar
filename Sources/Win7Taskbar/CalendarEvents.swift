import AppKit
import EventKit

/// Termine aus dem macOS-Kalender (EventKit): alle dort eingebundenen Konten, z. B. Exchange/
/// Microsoft 365 (Outlook), Google, iCloud. Liest nur, schreibt nie.
final class CalendarEvents {
    static let shared = CalendarEvents()
    /// Posted on the main queue when calendars or events changed (or access was granted).
    static let changedNotification = Notification.Name("de.batix.win7taskbar.calendarEventsChanged")

    struct CalendarInfo {
        let id: String
        let title: String
        /// Account the calendar belongs to (e.g. "Exchange", "Google", an e-mail address).
        let account: String
        let color: NSColor
    }

    struct Event {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let location: String?
        let calendarID: String
        let color: NSColor
    }

    private let store = EKEventStore()

    private init() {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            NotificationCenter.default.post(name: CalendarEvents.changedNotification, object: nil)
        }
    }

    // MARK: - Settings

    /// "Termine anzeigen" (Standard: aus).
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "calendarEvents") }
    /// Calendars the user switched off (identifiers).
    static var hiddenCalendarIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "calendarHidden") ?? [])
    }
    static func setHidden(_ hidden: Bool, calendarID: String) {
        var ids = hiddenCalendarIDs
        if hidden { ids.insert(calendarID) } else { ids.remove(calendarID) }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: "calendarHidden")
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    // MARK: - Access

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var isDenied: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted
    }

    /// Asks once for calendar access (system prompt). `done` runs on the main queue.
    func requestAccess(_ done: @escaping (Bool) -> Void) {
        if isAuthorized { done(true); return }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    self.store.reset()
                    NotificationCenter.default.post(name: CalendarEvents.changedNotification, object: nil)
                }
                done(granted)
            }
        }
    }

    // MARK: - Queries

    /// All event calendars, grouped by account (account name, then calendar title).
    func calendars() -> [CalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                                account: $0.source?.title ?? "", color: $0.color ?? .systemBlue) }
            .sorted { $0.account != $1.account ? $0.account < $1.account : $0.title < $1.title }
    }

    private func visibleCalendars() -> [EKCalendar]? {
        guard Self.enabled, isAuthorized else { return nil }
        let hidden = Self.hiddenCalendarIDs
        let cals = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        return cals.isEmpty ? nil : cals
    }

    private func fetch(from start: Date, to end: Date) -> [EKEvent] {
        guard let cals = visibleCalendars() else { return [] }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        return store.events(matching: pred)
    }

    /// Events touching `day` (local calendar day): all-day events first, then by start time.
    /// Empty when "Termine anzeigen" is off or access is missing.
    func events(on day: Date) -> [Event] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return fetch(from: start, to: end)
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.startDate < $1.startDate
            }
            .map { e in
                Event(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "",
                      start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                      location: (e.location?.isEmpty == false) ? e.location : nil,
                      calendarID: e.calendar.calendarIdentifier, color: e.calendar.color ?? .systemBlue)
            }
    }

    /// Days (1…31) of the month containing `date` that have events, with the (distinct, max 3)
    /// calendar colours of that day, for the dots in the month grid.
    func daysWithEvents(inMonthOf date: Date) -> [Int: [NSColor]] {
        let cal = Calendar.current
        guard let month = cal.dateInterval(of: .month, for: date) else { return [:] }
        var result: [Int: [NSColor]] = [:]
        var seen: [Int: Set<String>] = [:]
        for e in fetch(from: month.start, to: month.end) {
            // An event can span several days: mark every day of this month it touches.
            var d = max(cal.startOfDay(for: e.startDate), month.start)
            let last = min(e.endDate.addingTimeInterval(-1), month.end.addingTimeInterval(-1))
            while d <= last {
                let day = cal.component(.day, from: d)
                let id = e.calendar.calendarIdentifier
                if seen[day, default: []].insert(id).inserted, result[day, default: []].count < 3 {
                    result[day, default: []].append(e.calendar.color ?? .systemBlue)
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
        }
        return result
    }

    /// Opens the Calendar app in day view at the event's date (Calendar has no public deep link
    /// to a single event). Runs the AppleScript in the background.
    func open(_ event: Event) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: event.start)
        guard let y = c.year, let m = c.month, let d = c.day else { return }
        let script = """
        set theDate to current date
        set day of theDate to 1
        set year of theDate to \(y)
        set month of theDate to \(m)
        set day of theDate to \(d)
        tell application "Calendar"
            activate
            switch view to day view
            view calendar at theDate
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.launchPath = "/usr/bin/osascript"
            p.arguments = ["-e", script]
            try? p.run()
        }
    }
}
