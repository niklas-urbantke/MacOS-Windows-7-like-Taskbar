# Windows 7 Taskbar für macOS

Ein nativer Dock-Ersatz für macOS im Stil der Windows-7-Taskleiste (Swift/AppKit, ohne
externe Abhängigkeiten).

## ✨ Highlights
- **Aero-Glas-Taskleiste** mit animiertem Start-Orb, Stil-Profilen (Vista / Windows 7 /
  Windows 11) und Farbmodus Hell/Dunkel
- **Original-Windows-7-Startmenü** (1:1 nach AeroThemePlasma) oder die bisherige
  Zweispalten-Variante — Suche über Programme **und** Dateien, „Alle Programme“, angepinnte &
  zuletzt geöffnete Apps, Profilbild
- **Fenstervorschau (Aero Peek)** mit Live-Thumbnails, minimierten Fenstern und ×-Schließen
- **Win7-Hover-Farbschimmer**, Fenstergruppierung, Badges aus dem Dock
- **Drag & Drop**: Apps auf die Leiste ziehen zum Anheften, Icons frei umsortieren
- **Infobereich** mit Original-Windows-7-Symbolen: Netzwerk, Lautstärke, Akku,
  Benachrichtigungs-Flagge (Mitteilungszentrale), Now-Playing, CPU/RAM, Uhr mit Kalender
- **Jump-Lists** per Rechtsklick: Browser-Profile, Finder-Ordner, Terminal/Mail/VS Code u. a.
- **Platz-Reservierung**, **Auto-Ausblenden**, **Dock ausblenden**, mehrere Bildschirme
- **Hotkeys**: fn (Globe)+Control = Startmenü, Ctrl+1…9 = angepinnte App
- Einstellungen mit Seitenleiste & Suche, Export/Import, **Self-Update** aus der App

## 📦 Installation
1. `Win7Taskbar.dmg` herunterladen und öffnen
2. **Win7Taskbar** in den **Programme**-Ordner ziehen
3. Starten — beim ersten Mal **Rechtsklick → Öffnen**

> ⚠️ Die App ist selbst-signiert (nicht von Apple notarisiert). Falls Gatekeeper meckert:
> Rechtsklick → Öffnen, oder im Terminal:
> `xattr -dr com.apple.quarantine /Applications/Win7Taskbar.app`

## 🔐 Berechtigungen (Systemeinstellungen → Datenschutz & Sicherheit)
- **Bildschirmaufnahme** – für die Fenstervorschau
- **Bedienungshilfen** – Platz-Reservierung, Fenster wiederherstellen/schließen, Badges, Hotkeys
- **Automatisierung** – Energie-Aktionen, Finder-Fenster, Now-Playing-Steuerung

## 🖥️ Voraussetzungen
macOS 14 oder neuer.

## ℹ️ Hinweise
- Das macOS-Dock kann in den Einstellungen ausgeblendet werden (Auto-Hide).
- Der Finder wird nie beendet – nur seine Fenster lassen sich schließen.
- Das Original-Startmenü nutzt Segoe UI, falls vorhanden: `segoeui.ttf` aus Windows 7 nach
  `~/Library/Application Support/Win7Taskbar/fonts/` kopieren (wird nicht mitgeliefert).

🤖 Erstellt mit [Claude Code](https://claude.com/claude-code)
