import AppKit
import CoreLocation
import CoreWLAN

/// Wi-Fi access for the network flyout via CoreWLAN: scan, connect/disconnect, power.
/// macOS (14+) only reveals network names (SSIDs) to apps with Location permission, so the flyout
/// asks for it once; saved networks (profiles) are known by name even without it.
final class WifiManager: NSObject, CLLocationManagerDelegate {
    static let shared = WifiManager()

    struct Network: Equatable {
        let ssid: String?
        let rssi: Int
        let secure: Bool
        let known: Bool
        let current: Bool
        fileprivate let cw: CWNetwork?
        static func == (a: Network, b: Network) -> Bool { a.ssid == b.ssid && a.current == b.current && a.rssi == b.rssi }

        /// An entry without a scan result (e.g. the current connection before the first scan).
        init(ssid: String?, rssi: Int, secure: Bool, known: Bool, current: Bool) {
            self.init(ssid: ssid, rssi: rssi, secure: secure, known: known, current: current, cw: nil)
        }
        fileprivate init(ssid: String?, rssi: Int, secure: Bool, known: Bool, current: Bool, cw: CWNetwork?) {
            self.ssid = ssid; self.rssi = rssi; self.secure = secure; self.known = known; self.current = current; self.cw = cw
        }
    }

    enum ConnectError: Error { case needsPassword, failed(String) }

    /// Posted on the main queue when power, the current network or the location permission change.
    static let changedNotification = Notification.Name("WifiManagerChanged")

    private let client = CWWiFiClient.shared()
    private let location = CLLocationManager()
    private let queue = DispatchQueue(label: "wifi.scan", qos: .userInitiated)
    private(set) var scanning = false

    private override init() {
        super.init()
        location.delegate = self
    }

    var interface: CWInterface? { client.interface() }
    var hasWifi: Bool { interface != nil }
    var powerOn: Bool { interface?.powerOn() == true }
    var currentSSID: String? { interface?.ssid() }
    var currentRSSI: Int { interface?.rssiValue() ?? 0 }
    /// Connected to some Wi-Fi network (the SSID may be hidden without Location permission).
    var connected: Bool { powerOn && (currentSSID != nil || currentRSSI != 0) }

    // MARK: Location permission (only for the network names)

    var locationStatus: CLAuthorizationStatus { location.authorizationStatus }
    var namesVisible: Bool { [.authorizedAlways, .authorized].contains(locationStatus) }
    var canAskForLocation: Bool { locationStatus == .notDetermined }

    func requestLocation() {
        if canAskForLocation {
            location.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
    }

    // MARK: Networks

    /// Names of the saved networks (readable without Location permission).
    var knownSSIDs: Set<String> {
        let profiles = interface?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        return Set(profiles.compactMap { $0.ssid })
    }

    /// Scans in the background (takes a few seconds) and returns one entry per network name —
    /// the strongest access point — sorted like Windows 7: connected first, then by signal.
    func scan(_ done: @escaping ([Network]) -> Void) {
        guard let iface = interface, iface.powerOn() else { done([]); return }
        scanning = true
        let known = knownSSIDs, current = iface.ssid()
        queue.async { [weak self] in
            let found = (try? iface.scanForNetworks(withName: nil)) ?? []
            var bySSID: [String: CWNetwork] = [:]
            var unnamed: [CWNetwork] = []
            for n in found {
                guard let s = n.ssid, !s.isEmpty else { unnamed.append(n); continue }
                if let have = bySSID[s], have.rssiValue >= n.rssiValue { continue }
                bySSID[s] = n
            }
            var list = bySSID.values.map { n in
                Network(ssid: n.ssid, rssi: n.rssiValue, secure: !n.supportsSecurity(.none),
                        known: known.contains(n.ssid ?? ""), current: n.ssid == current, cw: n)
            }
            // Without the names the access points can't be told apart: keep them as anonymous entries.
            list += unnamed.map { Network(ssid: nil, rssi: $0.rssiValue, secure: !$0.supportsSecurity(.none),
                                          known: false, current: false, cw: $0) }
            list.sort { a, b in a.current != b.current ? a.current : a.rssi > b.rssi }
            DispatchQueue.main.async {
                self?.scanning = false
                done(list)
            }
        }
    }

    /// Connects in the background. Saved networks are tried without a password first (macOS may
    /// find it), then with the password from the keychain (macOS asks for permission); if that
    /// doesn't work either, `.needsPassword` asks the flyout for the security key.
    func connect(_ n: Network, password: String?, _ done: @escaping (Result<Void, ConnectError>) -> Void) {
        guard let iface = interface, let cw = n.cw else { done(.failure(.failed("Kein WLAN-Adapter"))); return }
        queue.async {
            func attempt(_ pw: String?) -> Error? {
                do { try iface.associate(to: cw, password: pw); return nil } catch { return error }
            }
            var error: Error?
            if let pw = password, !pw.isEmpty {
                error = attempt(pw)
            } else if !n.secure {
                error = attempt(nil)
            } else if n.known {
                error = attempt(nil)
                if error != nil, let ssidData = cw.ssidData, let pw = Self.keychainPassword(ssidData) {
                    error = attempt(pw)
                }
                if error != nil { DispatchQueue.main.async { done(.failure(.needsPassword)) }; return }
            } else {
                DispatchQueue.main.async { done(.failure(.needsPassword)) }; return
            }
            DispatchQueue.main.async {
                if let e = error {
                    done(.failure(.failed((e as NSError).localizedDescription)))
                } else {
                    done(.success(()))
                }
                NotificationCenter.default.post(name: Self.changedNotification, object: nil)
            }
        }
    }

    private static func keychainPassword(_ ssid: Data) -> String? {
        for domain in [CWKeychainDomain.user, .system] {
            var pw: NSString?
            if CWKeychainFindWiFiPassword(domain, ssid, &pw) == errSecSuccess, let p = pw { return p as String }
        }
        return nil
    }

    func disconnect() {
        interface?.disassociate()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    func setPower(_ on: Bool) {
        try? interface?.setPower(on)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    /// Windows 7 style signal level (0, 25, 50, 75, 100) for an RSSI in dBm.
    static func level(rssi: Int) -> Int {
        switch rssi {
        case 0: return 100          // connected but RSSI hidden
        case (-55)...: return 100
        case (-65)...: return 75
        case (-72)...: return 50
        case (-80)...: return 25
        default: return 0
        }
    }
}
