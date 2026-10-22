import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Battery details for the Windows 7 battery flyout (IOKit power sources) and the
/// "Ruhezustand manuell verhindern" switch (a power assertion while it is on).
enum BatteryStatus {
    struct Info {
        let percent: Int
        let onAC: Bool
        let charging: Bool
        let charged: Bool
        /// Minutes until empty (on battery) or full (charging); nil while macOS is still estimating.
        let minutesLeft: Int?
    }

    static func current() -> Info? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let charged = d[kIOPSIsChargedKey] as? Bool ?? false
            let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let t = d[key] as? Int ?? -1
            return Info(percent: max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur,
                        onAC: onAC, charging: charging, charged: charged || (onAC && !charging && cur >= max),
                        minutesLeft: t > 0 ? t : nil)
        }
        return nil
    }

    /// macOS "Stromsparmodus" (the Windows power plans are only shown, switching needs admin rights).
    static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    // MARK: Prevent sleep

    private static var assertion: IOPMAssertionID = 0
    static var preventingSleep: Bool { assertion != 0 }

    /// Keeps the display (and thus the system) awake and the screen from locking on idle.
    static func setPreventSleep(_ on: Bool) {
        if on, assertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Windows 7 Taskleiste: Ruhezustand manuell verhindert" as CFString,
                                           &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
