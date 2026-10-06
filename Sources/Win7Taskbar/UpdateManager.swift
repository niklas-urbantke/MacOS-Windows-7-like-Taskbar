import AppKit

/// Self-update by building from source (like Batix Local CMS): compare the baked-in build commit
/// against the remote via `git ls-remote`, then clone/update the source into Application Support,
/// run `build.sh` (stable-signed → granted permissions persist) and swap the running bundle via
/// `ditto`, relaunching. Progress is shown live in an in-app window (no Terminal).
enum UpdateManager {
    static let repoURL = "https://github.com/niklas-urbantke/MacOS-Windows-7-like-Taskbar.git"

    struct Target: Equatable { enum Kind { case branch, tag }; let kind: Kind; let ref: String }

    struct Info {
        let version: String
        let commit: String?
        var isDev: Bool { commit == nil }
        var shortCommit: String? { commit.map { String($0.prefix(8)) } }
    }

    struct CheckResult {
        let target: Target
        let remoteCommit: String?
        let updateAvailable: Bool
        let reason: String?
    }

    // MARK: - Current build info (baked in by build.sh)

    static func currentInfo() -> Info {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let c = (Bundle.main.infoDictionary?["GitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Info(version: v, commit: c)
    }

    // MARK: - Refs & check (fast, run on a background queue by callers)

    static func isReleaseTag(_ t: String) -> Bool { t.range(of: #"^v?\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil }
    private static func releaseKey(_ t: String) -> [Int] {
        guard let m = t.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return [0, 0, 0] }
        let parts = t[m].split(separator: ".").map { Int($0) ?? 0 }
        return [parts.first ?? 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0]
    }

    static func sortedReleaseTags(_ tags: [String]) -> [String] {
        tags.filter(isReleaseTag).sorted { a, b in
            let ka = releaseKey(a), kb = releaseKey(b)
            if ka[0] != kb[0] { return ka[0] > kb[0] }
            if ka[1] != kb[1] { return ka[1] > kb[1] }
            return ka[2] > kb[2]
        }
    }

    static func listRefs() -> (tags: [String], branches: [String]) {
        let (code, out) = capture(["ls-remote", "--tags", "--heads", repoURL])
        guard code == 0 else { return ([], []) }
        var tags: [String] = [], branches: [String] = []
        for line in out.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 2 else { continue }
            let ref = String(cols[1])
            if ref.hasPrefix("refs/tags/") {
                let n = String(ref.dropFirst(10)).replacingOccurrences(of: "^{}", with: "")
                if !tags.contains(n) { tags.append(n) }
            } else if ref.hasPrefix("refs/heads/") {
                branches.append(String(ref.dropFirst(11)))
            }
        }
        return (tags, branches)
    }

    /// Newest release tag, else main — the default check/update target.
    static func defaultTarget() -> Target {
        let releases = listRefs().tags.filter(isReleaseTag).sorted { a, b in
            let ka = releaseKey(a), kb = releaseKey(b)
            if ka[0] != kb[0] { return ka[0] > kb[0] }
            if ka[1] != kb[1] { return ka[1] > kb[1] }
            return ka[2] > kb[2]
        }
        if let newest = releases.first { return Target(kind: .tag, ref: newest) }
        return Target(kind: .branch, ref: "main")
    }

    private static func refPath(_ t: Target) -> String {
        t.kind == .tag ? "refs/tags/\(t.ref)" : "refs/heads/\(t.ref)"
    }

    static func resolveSha(_ t: Target) -> String? {
        let rp = refPath(t)
        // Annotated tags: also ask for the peeled ref (^{}) and prefer the commit SHA.
        let (code, out) = capture(["ls-remote", repoURL, rp, rp + "^{}"])
        guard code == 0 else { return nil }
        var direct: String?, peeled: String?
        for line in out.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 2 else { continue }
            if cols[1] == Substring(rp + "^{}") { peeled = String(cols[0]) }
            else if cols[1] == Substring(rp) { direct = String(cols[0]) }
        }
        return peeled ?? direct
    }

    static func checkForUpdate(_ target: Target?) -> CheckResult {
        let cur = currentInfo()
        let t = target ?? defaultTarget()
        guard gitAvailable() else {
            return CheckResult(target: t, remoteCommit: nil, updateAvailable: false, reason: "git ist nicht verfügbar.")
        }
        guard let sha = resolveSha(t) else {
            return CheckResult(target: t, remoteCommit: nil, updateAvailable: false, reason: "Ziel nicht gefunden / kein Netz.")
        }
        if cur.isDev {
            return CheckResult(target: t, remoteCommit: sha, updateAvailable: false, reason: "Kein eingebackener Build-Commit – Check nur informativ.")
        }
        let avail = sha != cur.commit
        return CheckResult(target: t, remoteCommit: sha, updateAvailable: avail,
                           reason: avail ? nil : "Bereits auf diesem Stand.")
    }

    // MARK: - Run the update (build from source) with live progress

    static func runUpdate(_ target: Target) {
        let progress = UpdateProgressWindow(title: "Taskleiste aktualisieren")
        progress.show()
        let dest = Bundle.main.bundleURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let newApp = try buildFromSource(target: target) { line in
                    DispatchQueue.main.async { progress.append(line) }
                }
                DispatchQueue.main.async {
                    progress.append("")
                    progress.append("✔ Fertig gebaut. Die Taskleiste wird ersetzt und neu gestartet …")
                    progress.finish(success: true)
                    launchInstaller(newApp: newApp, dest: dest)
                    // Give the installer a moment to start waiting, then quit so it can swap+relaunch.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
                }
            } catch {
                DispatchQueue.main.async {
                    progress.append("")
                    progress.append("✖ Update fehlgeschlagen: \(error.localizedDescription)")
                    progress.finish(success: false)
                }
            }
        }
    }

    private struct UpdateError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    private static func buildFromSource(target: Target, onLine: @escaping (String) -> Void) throws -> String {
        guard gitAvailable() else { throw UpdateError(msg: "git ist nicht verfügbar (Command Line Tools fehlen?).") }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Win7Taskbar/self-update", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) {
            onLine("Klone \(repoURL) …")
            if stream(["clone", repoURL, repo.path], onLine: onLine) != 0 { throw UpdateError(msg: "git clone fehlgeschlagen.") }
        } else {
            onLine("Aktualisiere Quelle (git fetch) …")
            _ = stream(["-C", repo.path, "fetch", "--all", "--tags", "--force", "--prune"], onLine: onLine)
        }

        onLine("Wechsle auf \(target.kind == .tag ? "Tag" : "Branch") \(target.ref) …")
        if target.kind == .tag {
            if stream(["-C", repo.path, "-c", "advice.detachedHead=false", "checkout", "-f", "refs/tags/\(target.ref)"], onLine: onLine) != 0 {
                throw UpdateError(msg: "Checkout (Tag) fehlgeschlagen.")
            }
            _ = stream(["-C", repo.path, "reset", "--hard", "refs/tags/\(target.ref)"], onLine: onLine)
        } else {
            if stream(["-C", repo.path, "checkout", "-B", target.ref, "origin/\(target.ref)"], onLine: onLine) != 0 {
                throw UpdateError(msg: "Checkout (Branch) fehlgeschlagen.")
            }
            _ = stream(["-C", repo.path, "reset", "--hard", "origin/\(target.ref)"], onLine: onLine)
        }
        _ = stream(["-C", repo.path, "clean", "-fdx", "--", "Win7Taskbar.app"], onLine: onLine)

        onLine("")
        onLine("Baue die App (./build.sh) – das kann ein bis zwei Minuten dauern …")
        let code = runShell(["./build.sh"], cwd: repo.path, onLine: onLine)
        if code != 0 { throw UpdateError(msg: "Build fehlgeschlagen (Code \(code)). Sind die Command Line Tools installiert?") }

        let newApp = repo.appendingPathComponent("Win7Taskbar.app").path
        guard FileManager.default.fileExists(atPath: newApp) else { throw UpdateError(msg: "Gebautes App-Bundle nicht gefunden.") }
        return newApp
    }

    /// Detached script: wait for this app to quit, swap the bundle via ditto, drop quarantine, relaunch.
    private static func launchInstaller(newApp: String, dest: String) {
        let script = """
        #!/bin/bash
        set -e
        PID="$1"; NEW="$2"; DEST="$3"
        for i in $(seq 1 120); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
        sleep 1
        rm -rf "$DEST"
        /usr/bin/ditto "$NEW" "$DEST"
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        open "$DEST"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("win7taskbar-selfupdate.sh")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // nohup + background so the installer survives this app terminating.
        p.arguments = ["-c", "nohup /bin/bash \"$0\" \"$@\" >/dev/null 2>&1 &",
                       url.path, String(ProcessInfo.processInfo.processIdentifier), newApp, dest]
        try? p.run()
    }

    // MARK: - Process helpers

    private static func gitAvailable() -> Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

    private static func baseEnv() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (e["PATH"] ?? "")
        return e
    }

    /// Run git, capturing all stdout (for ls-remote).
    private static func capture(_ args: [String]) -> (Int32, String) {
        guard gitAvailable() else { return (-1, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.environment = baseEnv()
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func stream(_ gitArgs: [String], onLine: @escaping (String) -> Void) -> Int32 {
        run("/usr/bin/git", gitArgs, cwd: nil, onLine: onLine)
    }
    private static func runShell(_ args: [String], cwd: String, onLine: @escaping (String) -> Void) -> Int32 {
        run("/bin/bash", args, cwd: cwd, onLine: onLine)
    }

    private static func run(_ launch: String, _ args: [String], cwd: String?, onLine: @escaping (String) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.environment = baseEnv()
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        var buf = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            buf.append(d)
            while let nl = buf.firstIndex(of: 0x0a) {
                let line = String(data: buf[..<nl], encoding: .utf8) ?? ""
                buf.removeSubrange(buf.startIndex...nl)
                onLine(line)
            }
        }
        do { try p.run() } catch { onLine("Fehler beim Start: \(error.localizedDescription)"); return -1 }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if !buf.isEmpty, let s = String(data: buf, encoding: .utf8), !s.isEmpty { onLine(s) }
        return p.terminationStatus
    }
}

// MARK: - In-app progress window

final class UpdateProgressWindow {
    private let window: NSWindow
    private let textView = NSTextView()
    private let spinner = NSProgressIndicator()
    private let closeButton = NSButton(title: "Schließen", target: nil, action: nil)

    init(title: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        scroll.documentView = textView

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.isEnabled = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(spinner)
        content.addSubview(closeButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            spinner.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            closeButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.contentView = content
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func append(_ line: String) {
        textView.string += (textView.string.isEmpty ? "" : "\n") + line
        textView.scrollToEndOfDocument(nil)
    }

    func finish(success: Bool) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        closeButton.isEnabled = true
    }

    @objc private func closeWindow() { window.close() }
}
