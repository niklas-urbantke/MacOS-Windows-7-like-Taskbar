# Windows 7 Taskbar für macOS — v1.0

Ein nativer Dock-Ersatz für macOS im Stil der Windows-7-Taskleiste (Swift/AppKit, ohne
externe Abhängigkeiten).

## ✨ Highlights
- **Aero-Glas-Taskleiste** mit animiertem Start-Orb (Standard / Hover / Menü-geöffnet)
- **Zweispalten-Startmenü** mit zwei Stilen (Akzentfarbe oder Aero-Glas), Suche über
  Programme **und** Dateien/Ordner, zuletzt geöffnete & angepinnte Apps, Profilbild
- **Fenstervorschau (Aero Peek)** mit Live-Thumbnails, minimierten Fenstern und ×-Schließen
- **Fenstergruppierung** mit gestapelten Rahmenkanten bei mehreren Fenstern
- **Drag & Drop**: Apps auf die Leiste ziehen zum Anheften, Icons frei umsortieren
- **Einzelklick** überall (kein Doppeltipp), Mittelklick öffnet ein neues Fenster
- **System-Tray**: Now-Playing (Spotify/Music), CPU/RAM-Monitor, WLAN, Akku, Lautstärke,
  Uhr mit Kalender — einzeln abschaltbar
- **Jump-Lists** per Rechtsklick: Browser-Profile, Finder-Ordner, Terminal/Mail/VS Code u. a.
- **Platz-Reservierung** für Fenster, **Auto-Ausblenden im Vollbild**, **Dock ausblenden**
- **Hotkeys**: fn (Globe)+Control = Startmenü, Ctrl+1…9 = angepinnte App
- Eigene **Orbs** ladbar, Einstellfenster in Tabs, Autostart-Schalter

## 📦 Installation
1. `Win7Taskbar.dmg` herunterladen und öffnen
2. **Win7Taskbar** in den **Programme**-Ordner ziehen
3. Starten — beim ersten Mal **Rechtsklick → Öffnen**

> ⚠️ Die App ist selbst-signiert (nicht von Apple notarisiert). Falls Gatekeeper meckert:
> Rechtsklick → Öffnen, oder im Terminal:
> `xattr -dr com.apple.quarantine /Applications/Win7Taskbar.app`

## 🔐 Berechtigungen (Systemeinstellungen → Datenschutz & Sicherheit)
- **Bildschirmaufnahme** – für die Fenstervorschau
- **Bedienungshilfen** – Platz-Reservierung, Fenster wiederherstellen/schließen, Hotkeys
- **Automatisierung** – Energie-Aktionen, Finder-Fenster, Now-Playing-Steuerung

## 🖥️ Voraussetzungen
macOS 14 oder neuer.

## ℹ️ Hinweise
- Das macOS-Dock kann in den Einstellungen ausgeblendet werden (Auto-Hide).
- Der Finder wird nie beendet – nur seine Fenster lassen sich schließen.

🤖 Erstellt mit [Claude Code](https://claude.com/claude-code)
