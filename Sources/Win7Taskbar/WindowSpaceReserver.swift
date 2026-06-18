import AppKit
import ApplicationServices

/// Best-effort "reserved space" for the taskbar.
///
/// macOS gives no public way to carve out a Dock-style reserved strip, so instead we use the
/// Accessibility API to keep every other app's windows above the taskbar: any window whose
/// bottom edge reaches into the reserved strip gets shrunk (or nudged up). Requires the
/// "Accessibility" permission. Toggleable; the choice is remembered across launches.
final class WindowSpaceReserver {
    private let key = "reserveSpace"
    private var timer: Timer?
    private(set) var enabled = false

    init() {
        let firstRun = UserDefaults.standard.object(forKey: key) == nil
        if firstRun {
            // Default ON so the bar reserves space out of the box.
            enabled = true
            UserDefaults.standard.set(true, forKey: key)
        } else {
            enabled = UserDefaults.standard.bool(forKey: key)
        }
        if enabled {
            if firstRun {
                // Prompt for the Accessibility permission once on first launch.
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            start()
        }
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Enable reservation, prompting for Accessibility permission if needed.
    /// Returns false if permission is still missing (user must grant it in System Settings).
    @discardableResult
    func enable() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        enabled = true
        UserDefaults.standard.set(true, forKey: key)
        if trusted { start() }
        return trusted
    }

    func disable() {
        enabled = false
        UserDefaults.standard.set(false, forKey: key)
        stop()
    }

    func toggle() -> Bool {
        if enabled { disable(); return true }
        return enable()
    }

    // MARK: - Loop

    private func start() {
        stop()
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.enforce() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        enforce()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Geometry

    private func geometry() -> (limit: CGFloat, minTop: CGFloat, primaryW: CGFloat, primaryH: CGFloat)? {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        guard let primary else { return nil }
        let h = primary.frame.height
        let w = primary.frame.width
        let menuBarHeight = max(0, primary.frame.maxY - primary.visibleFrame.maxY)
        let limit = h - Theme.barHeight          // AX y of the taskbar's top edge
        return (limit, menuBarHeight, w, h)
    }

    private func enforce() {
        guard AXIsProcessTrusted(), let g = geometry() else { return }
        let myPID = getpid()

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != myPID {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }

            for win in windows {
                clamp(win, g)
            }
        }
    }

    private func clamp(_ win: AXUIElement, _ g: (limit: CGFloat, minTop: CGFloat, primaryW: CGFloat, primaryH: CGFloat)) {
        if boolAttr(win, kAXMinimizedAttribute) == true { return }
        guard let pos = pointAttr(win, kAXPositionAttribute),
              let size = sizeAttr(win, kAXSizeAttribute) else { return }

        // Ignore windows that live on another display.
        if pos.x >= g.primaryW || (pos.x + size.width) <= 0 { return }
        // Ignore native full-screen windows (their own space, don't touch).
        if pos.y <= 1 && size.height >= g.primaryH - 2 { return }

        let bottom = pos.y + size.height
        guard bottom > g.limit + 1 else { return }

        let newHeight = g.limit - pos.y
        if newHeight >= 120 {
            setSize(win, CGSize(width: size.width, height: newHeight))
        } else {
            let newY = max(g.minTop, g.limit - size.height)
            setPos(win, CGPoint(x: pos.x, y: newY))
            let avail = g.limit - newY
            if size.height > avail {
                setSize(win, CGSize(width: size.width, height: avail))
            }
        }
    }

    // MARK: - AX helpers

    private func pointAttr(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &pt)
        return pt
    }

    private func sizeAttr(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var sz = CGSize.zero
        AXValueGetValue(v as! AXValue, .cgSize, &sz)
        return sz
    }

    private func boolAttr(_ el: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return (ref as? Bool)
    }

    private func setPos(_ el: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
    }

    private func setSize(_ el: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
        }
    }
}
