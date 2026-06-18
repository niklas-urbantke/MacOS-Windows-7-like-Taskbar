import Foundation

/// Lightweight file logger for diagnostics (unified-log delivery is unreliable for agent apps).
enum DebugLog {
    static let path = "/tmp/win7taskbar.log"

    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
