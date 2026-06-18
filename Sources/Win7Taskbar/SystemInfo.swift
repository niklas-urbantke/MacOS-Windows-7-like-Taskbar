import Foundation
import IOKit.ps

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
