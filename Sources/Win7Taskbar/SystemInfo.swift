import Foundation
import IOKit.ps
import CoreAudio
import AudioToolbox
import AppKit
import ApplicationServices

enum SystemInfo {
    struct Battery { let percent: Int; let charging: Bool }

    /// Current battery state, or nil on desktops without a battery.
    static func battery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            guard max > 0 else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String
            let charging = (state == kIOPSACPowerValue)
            return Battery(percent: Int((Double(cur) / Double(max) * 100).rounded()), charging: charging)
        }
        return nil
    }

    // MARK: - Volume: fast read via CoreAudio (for the tray glyph, polled), writes via AppleScript.

    private static func defaultOutputDevice() -> AudioObjectID? {
        var id = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr ? id : nil
    }

    /// Output volume 0–100 via CoreAudio (no process spawn), or nil if it can't be read.
    static func outputVolumeFast() -> Int? {
        guard let dev = defaultOutputDevice() else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var v = Float32(0); var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return Int((max(0, min(1, v)) * 100).rounded())
    }

    /// Output mute state via CoreAudio, or nil if it can't be read.
    static func isMutedFast() -> Bool? {
        guard let dev = defaultOutputDevice() else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var m = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr else { return nil }
        return m != 0
    }

    // MARK: - Volume (via AppleScript, the simplest reliable route)

    static func outputVolume() -> Int {
        let out = runOSA("output volume of (get volume settings)")
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func isMuted() -> Bool {
        runOSA("output muted of (get volume settings)").trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func setVolume(_ value: Int) {
        _ = runOSA("set volume output volume \(max(0, min(100, value)))")
    }

    static func setMuted(_ muted: Bool) {
        _ = runOSA("set volume \(muted ? "with" : "without") output muted")
    }

    // MARK: - Notification Center

    /// Opens macOS Notification Center the same way clicking the menu-bar clock does. On macOS 26/27
    /// the menu bar is SwiftUI: the clock lives in the MenuBarAgent, exposes no AXPress, so we locate
    /// it via Accessibility (the app already holds this permission for window reservation) and send a
    /// synthetic click at its centre. The cursor is restored afterwards. First use without
    /// Accessibility shows the permission prompt.
    static func openNotificationCenter() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            return
        }
        // AX reads + the synthetic click run off the main thread (the AX value is briefly flaky, so
        // we retry) to avoid stalling the taskbar.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let rect = menuBarClockRect() else { return }
            let target = CGPoint(x: rect.midX, y: rect.midY)
            let restore = CGEvent(source: nil)?.location
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(40_000)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(30_000)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
            if let restore { usleep(30_000); CGWarpMouseCursorPosition(restore) }
        }
    }

    /// Screen rect of the menu-bar clock: the widest status item in the MenuBarAgent's extras bar
    /// (the date/time is far wider than the icon items). Retries briefly because the AX value can be
    /// momentarily absent. Coordinates are top-left origin, matching CGEvent.
    private static func menuBarClockRect() -> CGRect? {
        guard let agent = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        func copyVal(_ el: AXUIElement, _ a: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success ? v : nil
        }
        var bar: AXUIElement?
        for _ in 0..<15 {
            if let v = copyVal(app, "AXExtrasMenuBar") { bar = (v as! AXUIElement); break }
            usleep(40_000)
        }
        guard let bar, let items = copyVal(bar, kAXChildrenAttribute as String) as? [AXUIElement] else { return nil }
        func rect(_ el: AXUIElement) -> CGRect? {
            guard let pv = copyVal(el, "AXPosition"), let sv = copyVal(el, "AXSize") else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            return CGRect(origin: pt, size: sz)
        }
        return items.compactMap(rect).max(by: { $0.width < $1.width })
    }

    @discardableResult
    private static func runOSA(_ command: String) -> String {
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
