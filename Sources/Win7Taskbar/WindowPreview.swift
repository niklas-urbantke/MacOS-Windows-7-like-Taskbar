import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Private SkyLight bridge: CGWindowID backing an Accessibility window element, used to match an
/// AX window to its ScreenCaptureKit thumbnail.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// One window of an app, for the hover preview.
struct PreviewItem {
    let title: String
    var image: NSImage?
    let axElement: AXUIElement?
    let windowID: CGWindowID?
    let isMinimized: Bool
    let appIcon: NSImage?
}

enum WindowPreview {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Hide Finder's untitled desktop window (default on).
    private static var hideFinderDesktop: Bool {
        UserDefaults.standard.object(forKey: "hideFinderDesktop") == nil
            ? true : UserDefaults.standard.bool(forKey: "hideFinderDesktop")
    }
    private static func isFinder(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder"
    }
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Fetch (AX-based when trusted: includes minimized windows + enables close/restore)

    static func fetch(pid: pid_t, appIcon: NSImage?) async -> [PreviewItem] {
        guard AXIsProcessTrusted() else {
            // No Accessibility: fall back to ScreenCaptureKit thumbnails only (no minimized/close).
            return await thumbnailsOnly(pid: pid)
        }

        let axWins = axWindows(pid: pid)
        guard !axWins.isEmpty else { return await thumbnailsOnly(pid: pid) }

        let sck = await sckWindowMap(pid: pid)
        var items: [PreviewItem] = []
        for w in axWins {
            var image: NSImage?
            if !w.minimized, let scw = sck[w.windowID] {
                image = await capture(scw)
            }
            items.append(PreviewItem(title: w.title, image: image, axElement: w.element,
                                     windowID: w.windowID, isMinimized: w.minimized, appIcon: appIcon))
        }
        return items
    }

    // MARK: - AX window list

    private struct AXWin { let element: AXUIElement; let title: String; let minimized: Bool; let windowID: CGWindowID }

    private static func axWindows(pid: pid_t) -> [AXWin] {
        let appEl = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
              let wins = value as? [AXUIElement] else { return [] }

        var result = wins.prefix(20).compactMap { win -> AXWin? in
            // Only count real, user-facing windows. Apps like "new Outlook" (WebView) spawn many
            // phantom windows — 0×0, thin helper strips, off-screen reminder toasts — which must not
            // inflate the taskbar count or appear in previews.
            guard isRealWindow(win) else { return nil }
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            var minRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef)
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(win, &wid)
            return AXWin(element: win,
                         title: (titleRef as? String) ?? "",
                         minimized: (minRef as? Bool) ?? false,
                         windowID: wid)
        }
        // Drop Finder's untitled desktop window.
        if hideFinderDesktop && isFinder(pid) {
            result = result.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return result
    }

    /// Whether an AX window is a real, user-facing window (not a 0×0 helper, thin strip, dialog or
    /// reminder toast). Keeps standard windows and windows without a declared subrole (size-gated),
    /// and drops explicitly non-standard ones (AXDialog, AXFloatingWindow, system dialogs, …).
    private static func isRealWindow(_ win: AXUIElement) -> Bool {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let s = sizeRef else { return false }
        var size = CGSize.zero
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        if size.width < 120 || size.height < 80 { return false }   // 0×0 helpers, thin strips

        var srRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &srRef)
        let subrole = (srRef as? String) ?? ""
        if subrole == (kAXStandardWindowSubrole as String) { return true }
        if subrole.isEmpty { return true }                          // apps that don't set a subrole
        return false                                                // dialogs, floating toasts, etc.
    }

    // MARK: - ScreenCaptureKit

    private static func sckWindowMap(pid: pid_t) async -> [CGWindowID: SCWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true) else { return [:] }
        var map: [CGWindowID: SCWindow] = [:]
        for w in content.windows where w.owningApplication?.processID == pid {
            map[w.windowID] = w
        }
        return map
    }

    private static func thumbnailsOnly(pid: pid_t) async -> [PreviewItem] {
        let map = await sckWindowMap(pid: pid)
        let skipDesktop = hideFinderDesktop && isFinder(pid)
        var items: [PreviewItem] = []
        for w in map.values where w.windowLayer == 0 && w.frame.width > 60 && w.frame.height > 60 {
            if skipDesktop && (w.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let img = await capture(w)
            items.append(PreviewItem(title: w.title ?? "", image: img, axElement: nil,
                                     windowID: w.windowID, isMinimized: false, appIcon: nil))
        }
        return items
    }

    private static func capture(_ w: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let maxW: CGFloat = 420
        let scale = min(1, maxW / max(1, w.frame.width))
        cfg.width = max(1, Int(w.frame.width * scale))
        cfg.height = max(1, Int(w.frame.height * scale))
        cfg.showsCursor = false
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Actions

    /// Bring a specific window to the front (un-minimising it first), and focus its app.
    static func raise(_ item: PreviewItem, pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        guard let ax = resolveElement(item, pid: pid) else { return }
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }

    /// Close a specific window via its AX close button.
    static func close(_ item: PreviewItem, pid: pid_t) {
        guard let ax = resolveElement(item, pid: pid) else { return }
        var btn: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXCloseButtonAttribute as CFString, &btn) == .success,
           let b = btn {
            AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Match an item to a live AX element (items captured via SCK-only have no AX element).
    private static func resolveElement(_ item: PreviewItem, pid: pid_t) -> AXUIElement? {
        if let ax = item.axElement { return ax }
        guard let wid = item.windowID else { return nil }
        return axWindows(pid: pid).first { $0.windowID == wid }?.element
    }

    // MARK: - Used by the taskbar button

    static func hasVisibleWindow(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return true }   // can't tell → assume yes
        let wins = axWindows(pid: pid)
        guard !wins.isEmpty else { return true }
        return wins.contains { !$0.minimized }
    }

    /// Number of visible vs minimized windows. Returns (1, 0) if Accessibility isn't granted.
    static func windowSummary(pid: pid_t) -> (visible: Int, minimized: Int) {
        guard AXIsProcessTrusted() else { return (1, 0) }
        let wins = axWindows(pid: pid)
        return (wins.filter { !$0.minimized }.count, wins.filter { $0.minimized }.count)
    }

    /// Diagnostic: log every AX window of every regular app with its attributes (to /tmp log).
    static func dumpDiagnostics() {
        guard AXIsProcessTrusted() else { DebugLog.log("dump: AX not trusted"); return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
                  let wins = value as? [AXUIElement] else { continue }
            DebugLog.log("=== \(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "")] windows=\(wins.count) ===")
            for (i, win) in wins.enumerated() {
                func str(_ a: String) -> String {
                    var r: CFTypeRef?; AXUIElementCopyAttributeValue(win, a as CFString, &r); return (r as? String) ?? ""
                }
                func boolA(_ a: String) -> Bool {
                    var r: CFTypeRef?; AXUIElementCopyAttributeValue(win, a as CFString, &r); return (r as? Bool) ?? false
                }
                var size = CGSize.zero, pos = CGPoint.zero
                var sr: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sr) == .success, let s = sr {
                    AXValueGetValue(s as! AXValue, .cgSize, &size)
                }
                var pr: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pr) == .success, let p = pr {
                    AXValueGetValue(p as! AXValue, .cgPoint, &pos)
                }
                var cb: CFTypeRef?
                let hasClose = AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &cb) == .success && cb != nil
                DebugLog.log("  [\(i)] role=\(str(kAXRoleAttribute)) subrole=\(str(kAXSubroleAttribute)) min=\(boolA(kAXMinimizedAttribute)) close=\(hasClose) size=\(Int(size.width))x\(Int(size.height)) pos=\(Int(pos.x)),\(Int(pos.y)) title=\"\(str(kAXTitleAttribute))\"")
            }
        }
        DebugLog.log("=== dump end ===")
    }

    static func unminimizeAndRaise(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        guard AXIsProcessTrusted() else { return }
        for w in axWindows(pid: pid) where w.minimized {
            AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        }
    }
}
