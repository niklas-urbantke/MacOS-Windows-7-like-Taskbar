import AppKit

/// Self-update: pull the latest code via git and rebuild with build.sh (which re-signs with the
/// stable identity, so granted TCC permissions are preserved), then relaunch the taskbar.
/// Runs in Terminal so the build survives this app quitting and its progress/errors are visible.
enum UpdateManager {
    static func runUpdate() {
        let repo = Bundle.main.bundleURL.deletingLastPathComponent()
        let appPath = repo.appendingPathComponent("Win7Taskbar.app").path
        let fm = FileManager.default

        guard fm.fileExists(atPath: repo.appendingPathComponent(".git").path),
              fm.fileExists(atPath: repo.appendingPathComponent("build.sh").path) else {
            alert("Update nicht möglich",
                  "Die App läuft nicht aus dem Projektordner (kein .git/build.sh in \(repo.path)). "
                  + "Das git-Update funktioniert nur, wenn die Taskleiste aus dem geklonten Repository gestartet wird.")
            return
        }

        let script = """
        #!/bin/bash
        export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        cd \(shQuote(repo.path)) || { echo "Repo nicht gefunden"; read -r; exit 1; }
        echo "== Windows 7 Taskleiste: Update =="
        echo ""
        echo "-> git pull (rebase, autostash) ..."
        git pull --rebase --autostash || { echo ""; echo "!! git pull fehlgeschlagen. Enter zum Schliessen."; read -r; exit 1; }
        echo ""
        echo "-> Neu bauen (./build.sh) ..."
        ./build.sh || { echo ""; echo "!! Build fehlgeschlagen. Enter zum Schliessen."; read -r; exit 1; }
        echo ""
        echo "-> Taskleiste neu starten ..."
        pkill -f Win7Taskbar.app || true
        sleep 1
        open \(shQuote(appPath))
        echo ""
        echo "** Update fertig. Dieses Fenster kann geschlossen werden. **"
        """

        let scriptURL = fm.temporaryDirectory.appendingPathComponent("win7taskbar-update.command")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            alert("Update-Fehler", "Konnte das Update-Skript nicht schreiben: \(error.localizedDescription)")
            return
        }

        // Run it in Terminal (independent of this app, which gets restarted by the script).
        let osa = "tell application \"Terminal\"\nactivate\ndo script \(osaQuote(scriptURL.path))\nend tell"
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", osa]
        do { try p.run() }
        catch { alert("Update-Fehler", "Terminal konnte nicht gestartet werden: \(error.localizedDescription)") }
    }

    // MARK: - Helpers

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func osaQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private static func alert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.runModal()
    }
}
