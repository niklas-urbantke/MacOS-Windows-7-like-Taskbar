# Windows 7 Taskbar für macOS

Ein nativer Dock-Ersatz für macOS im Stil der Windows-7-Taskleiste — geschrieben in Swift/AppKit,
ohne externe Abhängigkeiten.

![Taskleiste](orb.png)

## Funktionen

- **Win7-Leiste** am unteren Bildschirmrand (60 px, Aero-Glas, nur Icons) mit Start-Orb
  (eigenes `orb.png` mit Hover-/Press-Animation).
- **Startmenü** im Zweispalten-Layout: links zuletzt geöffnete Programme (anpinnbar, Suche,
  „Alle Programme"), rechts Orte & Energie-Aktionen. Verwendet die in macOS gewählte Akzentfarbe.
- **Taskbar-Buttons** für laufende & angepinnte Apps mit Aktiv-/Laufend-Anzeige. Klick:
  - offene Fenster → nach vorn / ausblenden
  - nur minimierte → wiederherstellen
  - laufend ohne Fenster → neues Fenster öffnen
  - nicht gestartet → Programm starten
- **Fenstervorschau** (Aero Peek) beim Hovern via ScreenCaptureKit: Live-Thumbnails,
  minimierte Fenster, Schließen-Knopf (×), Klick holt das Fenster nach vorn.
- **Platz-Reservierung**: hält Fenster über der Leiste (per Bedienungshilfen-API).
- **Vollbild**: Leiste blendet sich automatisch aus, wenn eine App im Vollbild ist.
- **System-Tray**: Akku, Lautstärke (Slider), Uhr mit Kalender-Popover.
- **Dock ausblenden** per Rechtsklick auf den Orb.

## Bauen & Starten

```bash
# (Einmalig, optional) stabile Signatur, damit erteilte Berechtigungen Rebuilds überleben:
./setup-signing.sh

./build.sh
open Win7Taskbar.app
```

Voraussetzungen: macOS 14+, Xcode-Toolchain (Swift 5.9+).

## Berechtigungen

- **Bildschirmaufnahme** — für die Fenster-Vorschaubilder.
- **Bedienungshilfen** — für Platz-Reservierung, minimierte Fenster, Schließen/Wiederherstellen.

Beide unter *Systemeinstellungen → Datenschutz & Sicherheit* aktivieren.

## Autostart

Als Anmeldeobjekt einrichten: *Systemeinstellungen → Allgemein → Anmeldeobjekte* →
`Win7Taskbar.app` hinzufügen.

## Hinweise

- Eine Drittanbieter-App kann keinen OS-Slot wie das echte Dock reservieren; die Reservierung
  hält Fenster per Bedienungshilfen oberhalb der Leiste.
- Das macOS-Dock lässt sich nicht vollständig beenden — die App versetzt es in den Auto-Hide.
