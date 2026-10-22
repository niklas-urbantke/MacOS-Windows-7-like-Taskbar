import AudioToolbox
import CoreAudio
import Foundation

/// Default output/input device, its volume and mute via CoreAudio (immediate, unlike the AppleScript
/// route), for the Windows 7 volume flyout. macOS has no per-application mixer, so only the device
/// level is available.
enum AudioOutput {
    enum Kind {
        case output, input
        var scope: AudioObjectPropertyScope { self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput }
        var defaultSelector: AudioObjectPropertySelector {
            self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        }
    }

    struct Device: Equatable {
        let id: AudioObjectID
        let name: String
    }

    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultDeviceID(_ kind: Kind) -> AudioObjectID? {
        var id = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = address(kind.defaultSelector)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func setDefault(_ d: Device, _ kind: Kind) {
        var id = d.id
        var a = address(kind.defaultSelector)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    /// All devices with streams in that direction.
    static func devices(_ kind: Kind) -> [Device] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var sa = address(kAudioDevicePropertyStreams, kind.scope)
            var ss: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 else { return nil }
            return Device(id: id, name: name(id) ?? "Gerät")
        }
    }

    static func defaultDevice(_ kind: Kind) -> Device? {
        guard let id = defaultDeviceID(kind) else { return nil }
        return Device(id: id, name: name(id) ?? "Gerät")
    }

    private static func name(_ id: AudioObjectID) -> String? {
        var a = address(kAudioObjectPropertyName)
        var n: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &n) == noErr, let s = n?.takeRetainedValue() else { return nil }
        return s as String
    }

    /// Volume 0…1 (nil if the device has no volume control, e.g. HDMI).
    static func volume(_ kind: Kind) -> Float? {
        guard let id = defaultDeviceID(kind) else { return nil }
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kind.scope)
        var v: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    static func setVolume(_ value: Float, _ kind: Kind) {
        guard let id = defaultDeviceID(kind) else { return }
        var v = Float32(max(0, min(1, value)))
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kind.scope)
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func muted(_ kind: Kind) -> Bool {
        guard let id = defaultDeviceID(kind) else { return false }
        var a = address(kAudioDevicePropertyMute, kind.scope)
        var m: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &m) == noErr else { return false }
        return m != 0
    }

    static func setMuted(_ on: Bool, _ kind: Kind) {
        guard let id = defaultDeviceID(kind) else { return }
        var a = address(kAudioDevicePropertyMute, kind.scope)
        var m: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }
}
