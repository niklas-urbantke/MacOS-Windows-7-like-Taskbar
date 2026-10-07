import AppKit
import UniformTypeIdentifiers

/// Central settings window collecting all toggles.
final class SettingsWindowController: NSObject {
    weak var controller: TaskbarController?
    private var window: NSWindow?

    private let dockBox = NSButton(checkboxWithTitle: "macOS-Dock ausblenden", target: nil, action: nil)
    private let reserveBox = NSButton(checkboxWithTitle: "Fensterbereich reservieren (Bedienungshilfen)", target: nil, action: nil)
    private let finderBox = NSButton(checkboxWithTitle: "Finder-Klick öffnet immer ein neues Fenster", target: nil, action: nil)
    private let nowPlayingBox = NSButton(checkboxWithTitle: "Now-Playing-Spieler in der Taskleiste anzeigen", target: nil, action: nil)
    private let wifiBox = NSButton(checkboxWithTitle: "WLAN-Symbol anzeigen", target: nil, action: nil)
    private let monitorBox = NSButton(checkboxWithTitle: "Hardware-Monitor (CPU/RAM) anzeigen", target: nil, action: nil)
    private let autostartBox = NSButton(checkboxWithTitle: "Beim Anmelden automatisch starten", target: nil, action: nil)
    private let secondsBox = NSButton(checkboxWithTitle: "Uhr mit Sekunden", target: nil, action: nil)
    private let allScreensBox = NSButton(checkboxWithTitle: "Taskleiste auf allen Bildschirmen (Nebenbildschirme ohne Medien und Leistung)", target: nil, action: nil)
    private let autoHideBox = NSButton(checkboxWithTitle: "Taskleiste automatisch ausblenden (am unteren Rand einblenden)", target: nil, action: nil)
    private let finderDesktopBox = NSButton(checkboxWithTitle: "Finder-Desktopfenster nicht als Fenster zählen", target: nil, action: nil)
    private let fullHeightBox = NSButton(checkboxWithTitle: "Icon-Rahmen über volle Höhe", target: nil, action: nil)
    private let orbPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var orbs: [(label: String, file: String)] = []
    private let menuStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let menuStyles: [(label: String, value: String)] = [("Akzentfarbe", "accent"), ("Taskbar (Aero)", "aero")]
    private let heightSlider = NSSlider(frame: .zero)
    private let heightLabel = NSTextField(labelWithString: "")
    private let iconWidthSlider = NSSlider(frame: .zero)
    private let iconWidthLabel = NSTextField(labelWithString: "")
    private let orbGapSlider = NSSlider(frame: .zero)
    private let orbGapLabel = NSTextField(labelWithString: "")

    // Startmenü-Tastenkürzel-Rekorder.
    private let hotkeyButton = HotkeyRecorderButton(title: "—", target: nil, action: nil)

    // Finder-Symbol (nur für diese Taskleiste).
    private let finderIconStatus = NSTextField(labelWithString: "")

    // App-Update (Self-Update aus der Quelle).
    private let updInfoLabel = NSTextField(labelWithString: "")
    private let updState = NSTextField(labelWithString: "")
    private let updVersionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let updDevBox = NSButton(checkboxWithTitle: "Auch Entwicklerversionen (Branches) anzeigen", target: nil, action: nil)
    private let updAutoBox = NSButton(checkboxWithTitle: "Beim Start automatisch nach Updates suchen", target: nil, action: nil)
    private let updCheckButton = NSButton(title: "Nach Updates suchen", target: nil, action: nil)
    private let updRunButton = NSButton(title: "Jetzt aktualisieren", target: nil, action: nil)
    private var updTargets: [(label: String, target: UpdateManager.Target)] = []

    // Taskleisten-Stil-Profil.
    private let taskbarStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let taskbarStyles: [(label: String, value: String)] = [("Windows Vista", "vista"), ("Windows 7", "win7"), ("Windows 11", "win11")]

    // Fenstervorschau beim Hovern.
    private let previewPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let previewModes: [(label: String, value: String)] = [
        ("DockDoor", "dockdoor"), ("Eigene Vorschau", "builtin"), ("Aus", "off")]

    // Kalender-Termine (EventKit): Schalter, Hinweis und Kalenderauswahl.
    private let eventsBox = NSButton(checkboxWithTitle: "Termine im Kalender der Uhr anzeigen", target: nil, action: nil)
    private let eventsStatus = NSTextField(wrappingLabelWithString: "")
    private let calendarList = NSStackView()

    // Farbmodus (alle Profile); Ausrichtung und Acryl-Look nur im Windows-11-Profil.
    private let win11AppearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let win11Appearances: [(label: String, value: String)] = [("System", "system"), ("Hell", "light"), ("Dunkel", "dark")]
    private let win11AlignmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let win11Alignments: [(label: String, value: String)] = [("Zentriert", "center"), ("Links", "left")]
    private let win11AcrylicBox = NSButton(checkboxWithTitle: "Acryl-Look", target: nil, action: nil)
    // Acryl je Fläche: (Fläche, Frost-Regler, Frost-Wert, Tönungs-Regler, Tönungs-Wert).
    private let acrylicSurfaces: [(role: Theme.Win11.Surface, label: String)] = [
        (.bar, "Leiste"), (.menu, "Startmenü"), (.flyout, "Flyouts (Kalender, Medien, Vorschau)")]
    private var frostSliders: [NSSlider] = []
    private var frostLabels: [NSTextField] = []
    private var tintSliders: [NSSlider] = []
    private var tintLabels: [NSTextField] = []
    // Controls that only apply to Vista/Win7 (disabled in the Win11 profile).
    private var classicOnlyControls: [NSControl] = []

    // Transparenz / Unschärfe (getrennt für Taskleiste und Startmenü).
    private let taskbarOpacitySlider = NSSlider(frame: .zero)
    private let taskbarOpacityLabel = NSTextField(labelWithString: "")
    private let taskbarBlurSlider = NSSlider(frame: .zero)
    private let taskbarBlurLabel = NSTextField(labelWithString: "")
    private let win7GlassSlider = NSSlider(frame: .zero)
    private let win7GlassLabel = NSTextField(labelWithString: "")
    private let menuOpacitySlider = NSSlider(frame: .zero)
    private let menuOpacityLabel = NSTextField(labelWithString: "")
    private let menuBlurSlider = NSSlider(frame: .zero)
    private let menuBlurLabel = NSTextField(labelWithString: "")

    func show() {
        if window == nil { build() }
        reloadOrbPopup()        // pick up orbs added/dropped since last time
        syncFromController()
        reloadCalendarSettings()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 470),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 560, height: 320)
        w.title = "Windows 7 Taskleiste – Einstellungen"
        w.isReleasedWhenClosed = false

        // Start-orb selection.
        orbPopup.target = self
        orbPopup.action = #selector(orbChanged)
        reloadOrbPopup()
        let addButton = NSButton(title: "Orb hinzufügen…", target: self, action: #selector(addOrbAction))
        addButton.bezelStyle = .rounded
        let folderButton = NSButton(title: "Ordner…", target: self, action: #selector(openFolderAction))
        folderButton.bezelStyle = .rounded
        let orbRow = NSStackView(views: [NSTextField(labelWithString: "Start-Symbol:"),
                                         orbPopup, addButton, folderButton])
        orbRow.orientation = .horizontal
        orbRow.spacing = 8

        // Start-menu style.
        menuStylePopup.removeAllItems()
        menuStylePopup.addItems(withTitles: menuStyles.map { $0.label })
        menuStylePopup.target = self
        menuStylePopup.action = #selector(menuStyleChanged)
        let menuEditButton = NSButton(title: "Rechte Spalte bearbeiten…", target: self, action: #selector(openMenuEditor))
        menuEditButton.bezelStyle = .rounded
        let styleRow = NSStackView(views: [NSTextField(labelWithString: "Startmenü-Stil:"), menuStylePopup, menuEditButton])
        styleRow.orientation = .horizontal
        styleRow.spacing = 8

        // Bar height.
        heightSlider.isContinuous = true    // label follows live; the relayout runs on release
        heightSlider.target = self
        heightSlider.action = #selector(heightChanged)
        heightSlider.translatesAutoresizingMaskIntoConstraints = false
        heightSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let dockSizeButton = NSButton(title: "Passend zum Dock", target: self, action: #selector(matchDockSize))
        dockSizeButton.bezelStyle = .rounded
        let heightRow = NSStackView(views: [NSTextField(labelWithString: "Leistenhöhe:"), heightSlider, heightLabel, dockSizeButton])
        heightRow.orientation = .horizontal
        heightRow.spacing = 8

        // Icon frame width (px).
        iconWidthSlider.isContinuous = true
        iconWidthSlider.target = self
        iconWidthSlider.action = #selector(iconWidthChanged)
        iconWidthSlider.translatesAutoresizingMaskIntoConstraints = false
        iconWidthSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let iconWidthRow = NSStackView(views: [NSTextField(labelWithString: "Icon-Rahmenbreite:"), iconWidthSlider, iconWidthLabel])
        iconWidthRow.orientation = .horizontal
        iconWidthRow.spacing = 8

        // Gap between the Start orb and the first icon (px).
        orbGapSlider.isContinuous = true
        orbGapSlider.target = self
        orbGapSlider.action = #selector(orbGapChanged)
        orbGapSlider.translatesAutoresizingMaskIntoConstraints = false
        orbGapSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let orbGapRow = NSStackView(views: [NSTextField(labelWithString: "Abstand Orb–Icons:"), orbGapSlider, orbGapLabel])
        orbGapRow.orientation = .horizontal
        orbGapRow.spacing = 8

        // Taskleisten-Stil-Profil.
        taskbarStylePopup.removeAllItems()
        taskbarStylePopup.addItems(withTitles: taskbarStyles.map { $0.label })
        taskbarStylePopup.target = self
        taskbarStylePopup.action = #selector(taskbarStyleChanged)
        let tbStyleRow = NSStackView(views: [NSTextField(labelWithString: "Stil-Profil:"), taskbarStylePopup])
        tbStyleRow.orientation = .horizontal
        tbStyleRow.spacing = 8

        // Windows-11-Optionen.
        let win11Header = NSTextField(labelWithString: "Windows 11")
        win11Header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        win11AppearancePopup.removeAllItems()
        win11AppearancePopup.addItems(withTitles: win11Appearances.map { $0.label })
        win11AppearancePopup.target = self
        win11AppearancePopup.action = #selector(win11AppearanceChanged)
        win11AlignmentPopup.removeAllItems()
        win11AlignmentPopup.addItems(withTitles: win11Alignments.map { $0.label })
        win11AlignmentPopup.target = self
        win11AlignmentPopup.action = #selector(win11AlignmentChanged)
        win11AcrylicBox.target = self
        win11AcrylicBox.action = #selector(win11AcrylicChanged)
        // Acryl-Tabelle: je Fläche ein Frost- und ein Tönungs-Regler (tag = Index der Fläche).
        func acrylicSlider(_ action: Selector, tag: Int) -> NSSlider {
            let sl = NSSlider(frame: .zero)
            sl.minValue = 0
            sl.maxValue = 1
            sl.isContinuous = true    // label follows live; the change applies on release
            sl.target = self
            sl.action = action
            sl.tag = tag
            sl.translatesAutoresizingMaskIntoConstraints = false
            sl.widthAnchor.constraint(equalToConstant: 140).isActive = true
            return sl
        }
        func valueLabel() -> NSTextField {
            let l = NSTextField(labelWithString: "")
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 40).isActive = true
            return l
        }
        let frostHead = NSTextField(labelWithString: "Frost")
        let tintHead = NSTextField(labelWithString: "Tönung")
        var gridRows: [[NSView]] = [[win11AcrylicBox, frostHead, NSGridCell.emptyContentView, tintHead, NSGridCell.emptyContentView]]
        for (i, s) in acrylicSurfaces.enumerated() {
            let fs = acrylicSlider(#selector(frostChanged(_:)), tag: i), fl = valueLabel()
            let ts = acrylicSlider(#selector(tintChanged(_:)), tag: i), tl = valueLabel()
            frostSliders.append(fs); frostLabels.append(fl)
            tintSliders.append(ts); tintLabels.append(tl)
            gridRows.append([NSTextField(labelWithString: s.label + ":"), fs, fl, ts, tl])
        }
        let acrylicGrid = NSGridView(views: gridRows)
        acrylicGrid.rowSpacing = 8
        acrylicGrid.columnSpacing = 8
        let resetAcrylic = NSButton(title: "Acryl zurücksetzen", target: self, action: #selector(resetAcrylic))
        resetAcrylic.bezelStyle = .rounded
        let appearanceRow = NSStackView(views: [NSTextField(labelWithString: "Farbmodus:"), win11AppearancePopup])
        appearanceRow.orientation = .horizontal
        appearanceRow.spacing = 8
        let win11Row = NSStackView(views: [NSTextField(labelWithString: "Ausrichtung:"), win11AlignmentPopup])
        win11Row.orientation = .horizontal
        win11Row.spacing = 8

        // Transparenz / Unschärfe – je ein Regler (0–100 %) für Taskleiste und Startmenü.
        let tbOpacityRow = makeSurfaceRow("Deckkraft:", taskbarOpacitySlider, taskbarOpacityLabel,
                                          #selector(taskbarOpacityChanged))
        let tbBlurRow = makeSurfaceRow("Unschärfe:", taskbarBlurSlider, taskbarBlurLabel,
                                       #selector(taskbarBlurChanged))
        let tbGlassRow = makeSurfaceRow("Icon-Glas:", win7GlassSlider, win7GlassLabel,
                                        #selector(win7GlassChanged))
        let menuOpacityRow = makeSurfaceRow("Deckkraft:", menuOpacitySlider, menuOpacityLabel,
                                            #selector(menuOpacityChanged))
        let menuBlurRow = makeSurfaceRow("Unschärfe:", menuBlurSlider, menuBlurLabel,
                                         #selector(menuBlurChanged))
        let tbHeader = NSTextField(labelWithString: "Taskleiste")
        tbHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let menuHeader = NSTextField(labelWithString: "Startmenü")
        menuHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        for box in [dockBox, reserveBox, finderBox, finderDesktopBox, nowPlayingBox,
                    wifiBox, monitorBox, autostartBox, fullHeightBox, secondsBox, allScreensBox, autoHideBox] {
            box.target = self
            box.action = #selector(changed(_:))
        }

        // Start-menu shortcut recorder.
        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.target = self
        hotkeyButton.action = #selector(recordHotkey)
        hotkeyButton.onCapture = { [weak self] keyCode, mods, chars in
            guard let self else { return }
            let modOnly = (keyCode == HotkeyRecorderButton.modifierOnly)
            let label = modOnly
                ? SettingsWindowController.modString(mods)
                : SettingsWindowController.shortcutString(mods, keyCode, chars)
            self.controller?.setStartHotkey(keyCode: modOnly ? -1 : Int(keyCode), mods: mods.rawValue, label: label)
            self.hotkeyButton.title = label
        }
        hotkeyButton.onCancel = { [weak self] in
            self?.hotkeyButton.title = self?.controller?.startHotkeyLabel ?? "—"
        }
        let hotkeyClear = NSButton(title: "Zurücksetzen", target: self, action: #selector(clearHotkey))
        hotkeyClear.bezelStyle = .rounded
        let hotkeyRow = NSStackView(views: [NSTextField(labelWithString: "Startmenü-Kürzel:"),
                                            hotkeyButton, hotkeyClear])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8

        // Custom Finder icon (this taskbar only).
        let finderIconButton = NSButton(title: "Bild wählen…", target: self, action: #selector(chooseFinderIcon))
        finderIconButton.bezelStyle = .rounded
        let finderIconReset = NSButton(title: "Zurücksetzen", target: self, action: #selector(resetFinderIcon))
        finderIconReset.bezelStyle = .rounded
        let finderIconRow = NSStackView(views: [NSTextField(labelWithString: "Finder-Symbol:"),
                                                finderIconButton, finderIconReset, finderIconStatus])
        finderIconRow.orientation = .horizontal
        finderIconRow.spacing = 8

        // Categorised tabs.
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        let dockPinsButton = NSButton(title: "Angeheftete Dock-Apps übernehmen", target: self, action: #selector(importDockPins))
        dockPinsButton.bezelStyle = .rounded
        let exportButton = NSButton(title: "Einstellungen exportieren…", target: self, action: #selector(exportSettings))
        exportButton.bezelStyle = .rounded
        let importButton = NSButton(title: "Einstellungen importieren…", target: self, action: #selector(importSettings))
        importButton.bezelStyle = .rounded
        let backupRow = NSStackView(views: [exportButton, importButton])
        backupRow.orientation = .horizontal; backupRow.spacing = 8
        // App-Update section (self-update by building from source, with live progress).
        let updHeader = NSTextField(labelWithString: "App-Update")
        updHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        updInfoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updInfoLabel.textColor = .secondaryLabelColor
        updVersionPopup.target = self
        updVersionPopup.action = #selector(updVersionChanged)
        let updVersionRow = NSStackView(views: [NSTextField(labelWithString: "Zielversion:"), updVersionPopup])
        updVersionRow.orientation = .horizontal; updVersionRow.spacing = 8
        updDevBox.target = self; updDevBox.action = #selector(updDevToggled)
        updCheckButton.bezelStyle = .rounded; updCheckButton.target = self; updCheckButton.action = #selector(updCheck)
        updRunButton.bezelStyle = .rounded; updRunButton.target = self; updRunButton.action = #selector(updRun)
        updRunButton.isEnabled = false
        updState.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let updButtonsRow = NSStackView(views: [updCheckButton, updRunButton, updState])
        updButtonsRow.orientation = .horizontal; updButtonsRow.spacing = 8
        updAutoBox.target = self; updAutoBox.action = #selector(updAutoToggled)

        tabView.addTabViewItem(makeTab("Allgemein", [dockBox, reserveBox, autoHideBox, autostartBox, allScreensBox, hotkeyRow, dockPinsButton, backupRow,
                                                     updHeader, updInfoLabel, updVersionRow, updDevBox, updButtonsRow, updAutoBox]))
        previewPopup.removeAllItems()
        previewPopup.addItems(withTitles: previewModes.map { $0.label })
        previewPopup.target = self
        previewPopup.action = #selector(previewModeChanged)
        let previewHint = NSTextField(labelWithString: "DockDoor zeigt seine Vorschau dann auch für diese Taskleiste.")
        previewHint.textColor = .secondaryLabelColor
        previewHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let previewRow = NSStackView(views: [NSTextField(labelWithString: "Fenstervorschau:"), previewPopup, previewHint])
        previewRow.orientation = .horizontal
        previewRow.spacing = 8
        tabView.addTabViewItem(makeTab("Darstellung", [tbStyleRow, appearanceRow, previewRow, orbRow, styleRow, heightRow, iconWidthRow, orbGapRow, fullHeightBox,
                                                       win11Header, win11Row, acrylicGrid, resetAcrylic]))
        tabView.addTabViewItem(makeTab("Transparenz",
                                       [tbHeader, tbOpacityRow, tbBlurRow, tbGlassRow,
                                        menuHeader, menuOpacityRow, menuBlurRow]))
        classicOnlyControls = [orbPopup, addButton, folderButton, menuStylePopup, menuEditButton, fullHeightBox, wifiBox,
                               taskbarOpacitySlider, taskbarBlurSlider, win7GlassSlider,
                               menuOpacitySlider, menuBlurSlider]
        tabView.addTabViewItem(makeTab("Tray", [nowPlayingBox, wifiBox, monitorBox, secondsBox]))
        tabView.addTabViewItem(makeTab("Finder", [finderBox, finderDesktopBox, finderIconRow]))

        // Kalender: Termine aus allen in macOS eingebundenen Konten (Outlook/Exchange, Google …).
        eventsBox.target = self
        eventsBox.action = #selector(eventsToggled)
        eventsStatus.textColor = .secondaryLabelColor
        eventsStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        eventsStatus.preferredMaxLayoutWidth = 560
        calendarList.orientation = .vertical
        calendarList.alignment = .leading
        calendarList.spacing = 6
        tabView.addTabViewItem(makeTab("Kalender", [eventsBox, eventsStatus, calendarList]))

        let quit = NSButton(title: "Taskleiste beenden", target: self, action: #selector(quitAction))
        quit.bezelStyle = .rounded
        quit.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tabView)
        content.addSubview(quit)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            quit.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 14),
            quit.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            quit.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        w.contentView = content
        window = w
    }

    /// A tab whose content scrolls vertically, so nothing is cut off when a tab holds more rows
    /// than the window is tall.
    private func makeTab(_ title: String, _ views: [NSView]) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()   // top-down, so the content starts at the top of the scroll view
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = doc

        let v = NSView()
        v.addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: v.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
        ])
        item.view = v
        return item
    }

    private func makeSurfaceRow(_ title: String, _ slider: NSSlider,
                                _ valueLabel: NSTextField, _ action: Selector) -> NSStackView {
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true        // Vorschau in Echtzeit (nur alphaValue, günstig)
        slider.target = self
        slider.action = action
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let row = NSStackView(views: [label, slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }

    @objc private func taskbarOpacityChanged() {
        controller?.setTaskbarOpacity(CGFloat(taskbarOpacitySlider.doubleValue))
        taskbarOpacityLabel.stringValue = percent(taskbarOpacitySlider.doubleValue)
    }
    @objc private func taskbarBlurChanged() {
        controller?.setTaskbarBlur(CGFloat(taskbarBlurSlider.doubleValue))
        taskbarBlurLabel.stringValue = percent(taskbarBlurSlider.doubleValue)
    }
    @objc private func win7GlassChanged() {
        controller?.setWin7GlassStrength(CGFloat(win7GlassSlider.doubleValue))
        win7GlassLabel.stringValue = percent(win7GlassSlider.doubleValue)
    }
    @objc private func menuOpacityChanged() {
        controller?.setMenuOpacity(CGFloat(menuOpacitySlider.doubleValue))
        menuOpacityLabel.stringValue = percent(menuOpacitySlider.doubleValue)
    }
    @objc private func menuBlurChanged() {
        controller?.setMenuBlur(CGFloat(menuBlurSlider.doubleValue))
        menuBlurLabel.stringValue = percent(menuBlurSlider.doubleValue)
    }

    private func syncFromController() {
        guard let c = controller else { return }
        dockBox.state = c.dockIsHidden ? .on : .off
        reserveBox.state = c.reserveEnabled ? .on : .off
        finderBox.state = c.finderNewWindow ? .on : .off
        nowPlayingBox.state = c.nowPlayingEnabled ? .on : .off
        wifiBox.state = c.wifiEnabled ? .on : .off
        monitorBox.state = c.monitorEnabled ? .on : .off
        autostartBox.state = c.autostartEnabled ? .on : .off
        secondsBox.state = c.clockSeconds ? .on : .off
        if let idx = previewModes.firstIndex(where: { $0.value == c.previewMode }) {
            previewPopup.selectItem(at: idx)
        }
        // DockDoor only selectable when installed.
        previewPopup.item(at: 0)?.isEnabled = Theme.isDockDoorInstalled
        previewPopup.autoenablesItems = false
        allScreensBox.state = c.showOnAllScreens ? .on : .off
        autoHideBox.state = c.autoHideEnabled ? .on : .off
        hotkeyButton.title = c.startHotkeyLabel
        updateFinderIconStatus()

        let info = UpdateManager.currentInfo()
        updInfoLabel.stringValue = info.isDev
            ? "Installiert: \(info.version) (Dev – kein Build-Commit)"
            : "Installiert: \(info.version) (\(info.shortCommit ?? "?"))"
        updAutoBox.state = (UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true) ? .on : .off
        updDevBox.state = UserDefaults.standard.bool(forKey: "updShowDev") ? .on : .off
        if updTargets.isEmpty { populateUpdateVersions() }
        finderDesktopBox.state = c.hideFinderDesktopEnabled ? .on : .off
        fullHeightBox.state = c.fullHeightIcons ? .on : .off
        if let idx = orbs.firstIndex(where: { $0.file == c.selectedOrbFile }) {
            orbPopup.selectItem(at: idx)
        }
        if let idx = menuStyles.firstIndex(where: { $0.value == c.menuStyle }) {
            menuStylePopup.selectItem(at: idx)
        }
        heightSlider.minValue = Double(c.minBarHeight)
        heightSlider.maxValue = Double(c.maxBarHeight)
        heightSlider.doubleValue = Double(c.barHeightValue)
        heightLabel.stringValue = "\(Int(c.barHeightValue)) px"
        iconWidthSlider.minValue = 36
        iconWidthSlider.maxValue = 160
        iconWidthSlider.doubleValue = Double(c.iconWidthValue)
        iconWidthLabel.stringValue = "\(Int(c.iconWidthValue)) px"
        orbGapSlider.minValue = 0
        orbGapSlider.maxValue = 80
        orbGapSlider.doubleValue = Double(c.orbGapValue)
        orbGapLabel.stringValue = "\(Int(c.orbGapValue)) px"

        if let idx = taskbarStyles.firstIndex(where: { $0.value == c.taskbarStyle }) {
            taskbarStylePopup.selectItem(at: idx)
        }
        taskbarOpacitySlider.doubleValue = Double(c.taskbarOpacity)
        taskbarOpacityLabel.stringValue = percent(Double(c.taskbarOpacity))
        taskbarBlurSlider.doubleValue = Double(c.taskbarBlur)
        taskbarBlurLabel.stringValue = percent(Double(c.taskbarBlur))
        win7GlassSlider.doubleValue = Double(c.win7GlassStrength)
        win7GlassLabel.stringValue = percent(Double(c.win7GlassStrength))
        menuOpacitySlider.doubleValue = Double(c.menuOpacity)
        menuOpacityLabel.stringValue = percent(Double(c.menuOpacity))
        menuBlurSlider.doubleValue = Double(c.menuBlur)
        menuBlurLabel.stringValue = percent(Double(c.menuBlur))

        if let idx = win11Appearances.firstIndex(where: { $0.value == c.win11Appearance }) {
            win11AppearancePopup.selectItem(at: idx)
        }
        if let idx = win11Alignments.firstIndex(where: { $0.value == c.win11Alignment }) {
            win11AlignmentPopup.selectItem(at: idx)
        }
        win11AcrylicBox.state = c.win11Acrylic ? .on : .off
        for (i, s) in acrylicSurfaces.enumerated() {
            frostSliders[i].doubleValue = Double(c.win11Frost(s.role))
            frostLabels[i].stringValue = percent(frostSliders[i].doubleValue)
            tintSliders[i].doubleValue = Double(c.win11Tint(s.role))
            tintLabels[i].stringValue = percent(tintSliders[i].doubleValue)
        }

        // Profile-specific controls: Win11 options only in the Win11 profile, the classic ones otherwise.
        let win11 = c.taskbarStyle == "win11"
        classicOnlyControls.forEach { $0.isEnabled = !win11 }
        [win11AlignmentPopup, win11AcrylicBox].forEach { $0.isEnabled = win11 }   // Farbmodus gilt für alle Profile
        (frostSliders + tintSliders).forEach { $0.isEnabled = win11 && c.win11Acrylic }
    }

    // MARK: - Kalender

    @objc private func eventsToggled() {
        let on = eventsBox.state == .on
        UserDefaults.standard.set(on, forKey: "calendarEvents")
        NotificationCenter.default.post(name: CalendarEvents.changedNotification, object: nil)
        if on && !CalendarEvents.shared.isAuthorized {
            CalendarEvents.shared.requestAccess { [weak self] _ in self?.reloadCalendarSettings() }
        }
        reloadCalendarSettings()
    }

    /// Status text plus one checkbox per calendar (with its colour), grouped by account.
    private func reloadCalendarSettings() {
        let ev = CalendarEvents.shared
        eventsBox.state = CalendarEvents.enabled ? .on : .off
        calendarList.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if ev.isDenied {
            eventsStatus.stringValue = "Kein Zugriff auf den Kalender. Bitte unter Systemeinstellungen → "
                + "Datenschutz & Sicherheit → Kalender für Win7Taskbar den vollen Zugriff erlauben."
            return
        }
        if !ev.isAuthorized {
            eventsStatus.stringValue = "Die Termine kommen aus allen Konten, die in macOS eingebunden sind "
                + "(Systemeinstellungen → Internetaccounts, z. B. Microsoft Exchange für Outlook, Google). "
                + "Beim Einschalten fragt macOS einmal nach dem Kalenderzugriff."
            return
        }
        eventsStatus.stringValue = "Angezeigte Kalender:"
        var account: String?
        for c in ev.calendars() {
            if c.account != account {
                account = c.account
                let head = NSTextField(labelWithString: c.account.isEmpty ? "Weitere" : c.account)
                head.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
                calendarList.addArrangedSubview(head)
            }
            let box = NSButton(checkboxWithTitle: c.title, target: self, action: #selector(calendarToggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(c.id)
            box.state = CalendarEvents.hiddenCalendarIDs.contains(c.id) ? .off : .on
            box.isEnabled = CalendarEvents.enabled
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = c.color.cgColor
            swatch.layer?.cornerRadius = 5
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true
            let row = NSStackView(views: [swatch, box])
            row.orientation = .horizontal
            row.spacing = 6
            calendarList.addArrangedSubview(row)
        }
    }

    @objc private func calendarToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        CalendarEvents.setHidden(sender.state == .off, calendarID: id)
    }

    @objc private func previewModeChanged() {
        let i = previewPopup.indexOfSelectedItem
        guard i >= 0, i < previewModes.count else { return }
        controller?.setPreviewMode(previewModes[i].value)
    }

    @objc private func matchDockSize() {
        controller?.matchDockSize()
        syncFromController()
    }
    @objc private func importDockPins() { controller?.importDockPins() }

    @objc private func win11AppearanceChanged() {
        let i = win11AppearancePopup.indexOfSelectedItem
        guard i >= 0, i < win11Appearances.count else { return }
        controller?.setWin11Appearance(win11Appearances[i].value)
    }
    @objc private func win11AlignmentChanged() {
        let i = win11AlignmentPopup.indexOfSelectedItem
        guard i >= 0, i < win11Alignments.count else { return }
        controller?.setWin11Alignment(win11Alignments[i].value)
    }
    @objc private func win11AcrylicChanged() {
        controller?.setWin11Acrylic(win11AcrylicBox.state == .on)
        (frostSliders + tintSliders).forEach { $0.isEnabled = win11AcrylicBox.state == .on }
    }
    @objc private func frostChanged(_ sender: NSSlider) {
        frostLabels[sender.tag].stringValue = percent(sender.doubleValue)
        guard sliderReleased else { return }
        controller?.setWin11Frost(CGFloat(sender.doubleValue), for: acrylicSurfaces[sender.tag].role)
    }
    @objc private func tintChanged(_ sender: NSSlider) {
        tintLabels[sender.tag].stringValue = percent(sender.doubleValue)
        guard sliderReleased else { return }
        controller?.setWin11Tint(CGFloat(sender.doubleValue), for: acrylicSurfaces[sender.tag].role)
    }
    /// Alle drei Flächen auf den gemeinsamen Standard (Frost 88 %, Tönung 25 %).
    @objc private func resetAcrylic() {
        for s in acrylicSurfaces {
            controller?.setWin11Frost(Theme.Win11.defaultFrost, for: s.role)
            controller?.setWin11Tint(Theme.Win11.defaultTint, for: s.role)
        }
        syncFromController()
    }

    /// True when the slider action comes from letting go of the knob (or a click/keyboard step),
    /// false while dragging. Heavy changes only apply then.
    private var sliderReleased: Bool {
        NSApp.currentEvent?.type != .leftMouseDragged
    }

    @objc private func heightChanged() {
        let v = heightSlider.doubleValue.rounded()
        heightLabel.stringValue = "\(Int(v)) px"
        guard sliderReleased else { return }
        controller?.setBarHeight(CGFloat(v))
    }

    @objc private func iconWidthChanged() {
        let v = iconWidthSlider.doubleValue.rounded()
        iconWidthLabel.stringValue = "\(Int(v)) px"
        guard sliderReleased else { return }
        controller?.setIconWidth(CGFloat(v))
    }

    @objc private func orbGapChanged() {
        let v = orbGapSlider.doubleValue.rounded()
        orbGapLabel.stringValue = "\(Int(v)) px"
        guard sliderReleased else { return }
        controller?.setOrbGap(CGFloat(v))
    }

    @objc private func orbChanged() {
        guard let c = controller, orbPopup.indexOfSelectedItem >= 0,
              orbPopup.indexOfSelectedItem < orbs.count else { return }
        c.setOrb(orbs[orbPopup.indexOfSelectedItem].file)
    }

    private func reloadOrbPopup() {
        orbs = controller?.availableOrbs ?? []
        orbPopup.removeAllItems()
        orbPopup.addItems(withTitles: orbs.map { $0.label })
        if let file = controller?.selectedOrbFile,
           let idx = orbs.firstIndex(where: { $0.file == file }) {
            orbPopup.selectItem(at: idx)
        }
    }

    @objc private func taskbarStyleChanged() {
        let i = taskbarStylePopup.indexOfSelectedItem
        guard i >= 0, i < taskbarStyles.count else { return }
        controller?.setTaskbarStyle(taskbarStyles[i].value)
        syncFromController()   // das Profil ändert die empfohlenen Blur-/Deckkraftwerte
    }

    @objc private func openMenuEditor() { controller?.openMenuEditor() }

    // MARK: - Custom Finder icon

    @objc private func chooseFinderIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image, .icns]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Bild für das Finder-Symbol dieser Taskleiste wählen"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            self.controller?.setFinderIcon(from: url)
            self.updateFinderIconStatus()
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    @objc private func resetFinderIcon() {
        controller?.clearFinderIcon()
        updateFinderIconStatus()
    }

    private func updateFinderIconStatus() {
        finderIconStatus.stringValue = (controller?.hasCustomFinderIcon ?? false) ? "eigenes Bild aktiv" : "Standard"
    }

    // MARK: - Start-menu shortcut recorder

    @objc private func recordHotkey() {
        hotkeyButton.title = "Tasten drücken… (Esc bricht ab)"
        hotkeyButton.beginRecording()
    }

    @objc private func clearHotkey() {
        controller?.clearStartHotkey()
        hotkeyButton.title = controller?.startHotkeyLabel ?? "—"
    }

    private static func modString(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.function) { s += "fn" }
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }

    private static func shortcutString(_ mods: NSEvent.ModifierFlags, _ keyCode: UInt16, _ chars: String?) -> String {
        modString(mods) + keyName(keyCode, chars)
    }

    private static func keyName(_ keyCode: UInt16, _ chars: String?) -> String {
        switch keyCode {
        case 53: return "⎋"
        case 49: return "Leertaste"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"; case 100: return "F8"
        case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        default:
            if let c = chars, !c.isEmpty, c != " " { return c.uppercased() }
            return "Taste \(keyCode)"
        }
    }

    @objc private func menuStyleChanged() {
        let i = menuStylePopup.indexOfSelectedItem
        guard i >= 0, i < menuStyles.count else { return }
        controller?.setMenuStyle(menuStyles[i].value)
    }

    @objc private func addOrbAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "PNG mit drei gestapelten Zuständen (normal / Hover / gedrückt) wählen"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self, let c = self.controller else { return }
            if let file = c.addOrb(from: url) {
                self.reloadOrbPopup()
                if let idx = self.orbs.firstIndex(where: { $0.file == file }) {
                    self.orbPopup.selectItem(at: idx)
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    @objc private func openFolderAction() { controller?.openOrbsFolder() }

    @objc private func changed(_ sender: NSButton) {
        guard let c = controller else { return }
        let on = sender.state == .on
        switch sender {
        case dockBox:
            c.setDockHidden(on)
        case reserveBox:
            if on {
                if !c.setReserveEnabled(true) {
                    sender.state = .off
                    let alert = NSAlert()
                    alert.messageText = "Berechtigung Bedienungshilfen nötig"
                    alert.informativeText = "Bitte aktiviere Win7Taskbar unter Systemeinstellungen → "
                        + "Datenschutz & Sicherheit → Bedienungshilfen und setze den Haken erneut."
                    alert.runModal()
                }
            } else {
                _ = c.setReserveEnabled(false)
            }
        case finderBox:
            c.setFinderNewWindow(on)
        case nowPlayingBox:
            c.setShowNowPlaying(on)
        case wifiBox:
            c.setShowWifi(on)
        case monitorBox:
            c.setShowMonitor(on)
        case autostartBox:
            c.setAutostart(on)
        case finderDesktopBox:
            c.setHideFinderDesktop(on)
        case fullHeightBox:
            c.setFullHeightIcons(on)
        case secondsBox:
            c.setClockSeconds(on)
        case allScreensBox:
            c.setShowOnAllScreens(on)
        case autoHideBox:
            c.setAutoHide(on)
        default:
            break
        }
    }

    // MARK: - App-Update

    private func selectedTarget() -> UpdateManager.Target? {
        let i = updVersionPopup.indexOfSelectedItem
        guard i >= 0, i < updTargets.count else { return nil }
        return updTargets[i].target
    }

    @objc private func updVersionChanged() { updRunButton.isEnabled = false; updState.stringValue = "" }
    @objc private func updDevToggled() {
        UserDefaults.standard.set(updDevBox.state == .on, forKey: "updShowDev")
        populateUpdateVersions()
    }
    @objc private func updAutoToggled() {
        UserDefaults.standard.set(updAutoBox.state == .on, forKey: "autoCheckUpdates")
    }

    @objc private func updCheck() {
        guard let t = selectedTarget() else { return }
        updState.stringValue = "Prüfe …"; updState.textColor = .secondaryLabelColor
        updCheckButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let r = UpdateManager.checkForUpdate(t)
            DispatchQueue.main.async {
                self.updCheckButton.isEnabled = true
                self.updRunButton.isEnabled = r.updateAvailable
                if r.updateAvailable {
                    self.updState.stringValue = "Update verfügbar (" + (r.remoteCommit.map { String($0.prefix(8)) } ?? "?") + ")"
                    self.updState.textColor = .systemGreen
                } else {
                    self.updState.stringValue = r.reason ?? "Aktuell."
                    self.updState.textColor = .secondaryLabelColor
                }
            }
        }
    }

    @objc private func updRun() {
        guard let t = selectedTarget() else { return }
        UpdateManager.runUpdate(t)
    }

    private func populateUpdateVersions() {
        updVersionPopup.removeAllItems()
        updVersionPopup.addItem(withTitle: "Lade …")
        updTargets = []
        let showDev = updDevBox.state == .on
        DispatchQueue.global(qos: .userInitiated).async {
            let refs = UpdateManager.listRefs()
            var items: [(String, UpdateManager.Target)] = []
            for tag in UpdateManager.sortedReleaseTags(refs.tags) {
                items.append(("Version \(tag)", UpdateManager.Target(kind: .tag, ref: tag)))
            }
            if showDev {
                let branches = refs.branches.sorted { ($0 == "main" ? "" : $0) < ($1 == "main" ? "" : $1) }
                for b in branches { items.append(("Branch: \(b)", UpdateManager.Target(kind: .branch, ref: b))) }
                let otherTags = refs.tags.filter { !UpdateManager.isReleaseTag($0) }
                for tg in otherTags { items.append(("Tag: \(tg)", UpdateManager.Target(kind: .tag, ref: tg))) }
            }
            if items.isEmpty { items.append(("Branch: main", UpdateManager.Target(kind: .branch, ref: "main"))) }
            DispatchQueue.main.async {
                self.updTargets = items
                self.updVersionPopup.removeAllItems()
                self.updVersionPopup.addItems(withTitles: items.map { $0.0 })
                self.updVersionPopup.selectItem(at: 0)
            }
        }
    }

    // MARK: - Einstellungen Export / Import

    private var settingsFileType: UTType { UTType(filenameExtension: SettingsIO.fileExtension) ?? .propertyList }

    @objc private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [settingsFileType]
        panel.nameFieldStringValue = "Win7Taskbar-Einstellungen.\(SettingsIO.fileExtension)"
        panel.message = "Alle Einstellungen (inkl. eigener Orbs/Finder-Icon) in eine Datei sichern."
        let run: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url, let data = SettingsIO.makeExportData() else { return }
            do { try data.write(to: url) }
            catch {
                let a = NSAlert(); a.messageText = "Export fehlgeschlagen"
                a.informativeText = error.localizedDescription; a.runModal()
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    @objc private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [settingsFileType, .propertyList, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Einstellungsdatei (.\(SettingsIO.fileExtension)) wählen."
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url), SettingsIO.importData(data) else {
                let a = NSAlert(); a.messageText = "Import fehlgeschlagen"
                a.informativeText = "Die Datei konnte nicht gelesen werden."; a.runModal(); return
            }
            let a = NSAlert()
            a.messageText = "Einstellungen importiert"
            a.informativeText = "Die Taskleiste wird jetzt neu gestartet, damit alles angewendet wird."
            a.addButton(withTitle: "Neu starten")
            a.runModal()
            self?.window?.close()
            SettingsIO.relaunchApp()
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}

/// A button that records a key combination: while recording it becomes first responder and captures
/// the next key (with modifiers) directly — including ⌘-combos via performKeyEquivalent. Esc cancels.
final class HotkeyRecorderButton: NSButton {
    /// Sentinel keyCode meaning "modifiers only" (e.g. ⌃⌘ with no regular key).
    static let modifierOnly: UInt16 = 0xFFFF
    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    var onCapture: ((UInt16, NSEvent.ModifierFlags, String?) -> Void)?
    var onCancel: (() -> Void)?
    private var recording = false
    private var pendingMods: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }

    func beginRecording() {
        recording = true
        pendingMods = []
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { handleKey(event); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if recording { handleKey(event) } else { super.keyDown(with: event) }
    }

    // Modifier-only combos (⌃⌘ etc.) only produce flagsChanged: accumulate while held, commit on release.
    override func flagsChanged(with event: NSEvent) {
        guard recording else { super.flagsChanged(with: event); return }
        let mods = event.modifierFlags.intersection(Self.mask)
        if mods.isEmpty {
            if modCount(pendingMods) >= 2 {
                recording = false
                onCapture?(Self.modifierOnly, pendingMods, nil)
            }
            pendingMods = []
        } else {
            pendingMods.formUnion(mods)
        }
    }

    private func handleKey(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(Self.mask)
        if e.keyCode == 53 && mods.isEmpty { recording = false; onCancel?(); return }  // Esc cancels
        guard !mods.isEmpty else { return }                                            // need a modifier
        recording = false
        onCapture?(e.keyCode, mods, e.charactersIgnoringModifiers)
    }

    private func modCount(_ m: NSEvent.ModifierFlags) -> Int {
        [.command, .option, .control, .shift, .function].reduce(0) { $0 + (m.contains($1) ? 1 : 0) }
    }
}
