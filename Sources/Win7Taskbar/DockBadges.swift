import AppKit
import ApplicationServices

/// Reads notification badges (e.g. Slack/Teams unread counts) from the Dock via Accessibility.
/// The Dock keeps these labels for running apps even while it is auto-hidden.
enum DockBadges {
    /// Map of app display name → badge text (only apps that currently have a badge).
    static func current() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }

        let appEl = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]
        walk(appEl, depth: 0, into: &result)
        return result
    }

    private static func walk(_ element: AXUIElement, depth: Int, into result: inout [String: String]) {
        if depth > 4 { return }

        if let title = string(element, kAXTitleAttribute), !title.isEmpty,
           let badge = string(element, "AXStatusLabel"), !badge.isEmpty {
            result[title] = badge
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children { walk(child, depth: depth + 1, into: &result) }
        }
    }

    private static func string(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
