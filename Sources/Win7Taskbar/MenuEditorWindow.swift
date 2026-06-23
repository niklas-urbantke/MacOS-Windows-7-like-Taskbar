import AppKit
import UniformTypeIdentifiers

/// Carries a chosen catalogue option + the closure that applies the resulting action.
private final class ActionPick: NSObject {
    let option: MenuActionOption
    let apply: (MenuAction, String) -> Void
    init(_ option: MenuActionOption, _ apply: @escaping (MenuAction, String) -> Void) {
        self.option = option; self.apply = apply
    }
}

/// Editor for the Start-menu's right column: rename / reorder / add / remove entries, choose an
/// action per entry from a large catalogue (incl. "open a specific folder"), and assign the avatar
/// a free action. The username row is shown but locked.
final class MenuEditorWindowController: NSObject, NSTextFieldDelegate {
    var onChange: (() -> Void)?

    private var window: NSWindow?
    private var entries: [MenuEntry] = []
    private var avatar: MenuAction = MenuEntryStore.avatarAction()

    private let rowsStack = NSStackView()
    private let avatarButton = NSButton()

    func show() {
        entries = MenuEntryStore.entries()
        avatar = MenuEntryStore.avatarAction()
        if window == nil { build() }
        updateAvatarButton()
        rebuildRows()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Build

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Startmenü – Rechte Spalte bearbeiten"
        w.isReleasedWhenClosed = false

        let content = NSView()

        // Avatar action row.
        let avatarTitle = NSTextField(labelWithString: "Avatar-Aktion:")
        avatarButton.bezelStyle = .rounded
        avatarButton.target = self
        avatarButton.action = #selector(pickAvatarAction(_:))
        let avatarRow = NSStackView(views: [avatarTitle, avatarButton])
        avatarRow.orientation = .horizontal
        avatarRow.spacing = 8
        avatarRow.translatesAutoresizingMaskIntoConstraints = false

        // Locked username info row.
        let lockInfo = NSTextField(labelWithString:
            "👤  Benutzername (oberste Zeile) – Name und Aktion sind fest und nicht änderbar.")
        lockInfo.textColor = .secondaryLabelColor
        lockInfo.font = .systemFont(ofSize: 11)
        lockInfo.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable entry rows (the stack is the document view directly).
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rowsStack
        let clip = scroll.contentView

        // Bottom toolbar.
        let addButton = NSButton(title: "+ Eintrag", target: self, action: #selector(addRow))
        addButton.bezelStyle = .rounded
        let resetButton = NSButton(title: "Standard wiederherstellen", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        let doneButton = NSButton(title: "Fertig", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbar = NSStackView(views: [addButton, resetButton, spacer, doneButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(avatarRow)
        content.addSubview(lockInfo)
        content.addSubview(scroll)
        content.addSubview(toolbar)

        NSLayoutConstraint.activate([
            avatarRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            avatarRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            lockInfo.topAnchor.constraint(equalTo: avatarRow.bottomAnchor, constant: 12),
            lockInfo.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            lockInfo.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: lockInfo.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            toolbar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            toolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            // Document stack fills the clip view's width; its height grows with the rows.
            rowsStack.topAnchor.constraint(equalTo: clip.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            rowsStack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

        w.contentView = content
        window = w
    }

    // MARK: - Rows

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, entry) in entries.enumerated() {
            rowsStack.addArrangedSubview(makeRow(index: i, entry: entry))
        }
    }

    private func makeRow(index i: Int, entry: MenuEntry) -> NSView {
        let name = NSTextField(string: entry.title)
        name.tag = i
        name.delegate = self
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let act = NSButton(title: MenuActionCatalog.title(for: entry.action),
                           target: self, action: #selector(pickEntryAction(_:)))
        act.tag = i
        act.bezelStyle = .rounded
        act.translatesAutoresizingMaskIntoConstraints = false
        act.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let gap = NSButton(checkboxWithTitle: "Abstand", target: self, action: #selector(toggleGap(_:)))
        gap.tag = i; gap.state = entry.gapBefore ? .on : .off

        let sep = NSButton(checkboxWithTitle: "Linie", target: self, action: #selector(toggleSep(_:)))
        sep.tag = i; sep.state = entry.separatorBefore ? .on : .off

        let up = smallButton("↑", #selector(moveUp(_:)), tag: i)
        let down = smallButton("↓", #selector(moveDown(_:)), tag: i)
        let del = smallButton("✕", #selector(deleteRow(_:)), tag: i)

        let row = NSStackView(views: [name, act, gap, sep, up, down, del])
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func smallButton(_ title: String, _ action: Selector, tag: Int) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.tag = tag
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    private func updateAvatarButton() {
        avatarButton.title = MenuActionCatalog.title(for: avatar)
    }

    // MARK: - Action chooser

    private func actionMenu(apply: @escaping (MenuAction, String) -> Void) -> NSMenu {
        let menu = NSMenu()
        for (group, opts) in MenuActionCatalog.groups {
            let sub = NSMenu()
            for o in opts {
                let it = NSMenuItem(title: o.title, action: #selector(actionPicked(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = ActionPick(o, apply)
                sub.addItem(it)
            }
            let parent = NSMenuItem(title: group, action: nil, keyEquivalent: "")
            menu.addItem(parent)
            menu.setSubmenu(sub, for: parent)
        }
        return menu
    }

    @objc private func actionPicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? ActionPick else { return }
        resolve(pick.option) { action, title in pick.apply(action, title) }
    }

    /// For parameterised options, prompt for the folder / URL / app, then build the action.
    private func resolve(_ option: MenuActionOption, completion: @escaping (MenuAction, String) -> Void) {
        switch option.param {
        case .folder:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Wählen"
            runPanel(panel) { url in completion(MenuAction(.openFolder, param: url.path), url.lastPathComponent) }
        case .app:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.canChooseDirectories = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.prompt = "Wählen"
            runPanel(panel) { url in
                completion(MenuAction(.openApp, param: url.path), url.deletingPathExtension().lastPathComponent)
            }
        case .url:
            let alert = NSAlert()
            alert.messageText = "Website-Adresse"
            alert.informativeText = "Welche Adresse soll geöffnet werden?"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = "https://"
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Abbrechen")
            if let w = window {
                alert.beginSheetModal(for: w) { resp in
                    guard resp == .alertFirstButtonReturn else { return }
                    let s = field.stringValue.trimmingCharacters(in: .whitespaces)
                    guard !s.isEmpty else { return }
                    completion(MenuAction(.openURL, param: s), URL(string: s)?.host ?? s)
                }
            }
        case nil:
            completion(MenuAction(option.kind), option.title)
        }
    }

    private func runPanel(_ panel: NSOpenPanel, _ done: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { resp in
            if resp == .OK, let url = panel.url { done(url) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    // MARK: - Edits

    @objc private func pickEntryAction(_ sender: NSButton) {
        let i = sender.tag
        let menu = actionMenu { [weak self] action, title in
            guard let self, i < self.entries.count else { return }
            self.entries[i].action = action
            self.entries[i].title = title
            self.commit()
            self.rebuildRows()
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func pickAvatarAction(_ sender: NSButton) {
        let menu = actionMenu { [weak self] action, _ in
            guard let self else { return }
            self.avatar = action
            MenuEntryStore.saveAvatar(action)
            self.updateAvatarButton()
            self.onChange?()
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func toggleGap(_ s: NSButton) {
        guard s.tag < entries.count else { return }
        entries[s.tag].gapBefore = (s.state == .on); commit()
    }
    @objc private func toggleSep(_ s: NSButton) {
        guard s.tag < entries.count else { return }
        entries[s.tag].separatorBefore = (s.state == .on); commit()
    }
    @objc private func moveUp(_ s: NSButton) {
        let i = s.tag; guard i > 0, i < entries.count else { return }
        entries.swapAt(i, i - 1); commit(); rebuildRows()
    }
    @objc private func moveDown(_ s: NSButton) {
        let i = s.tag; guard i >= 0, i < entries.count - 1 else { return }
        entries.swapAt(i, i + 1); commit(); rebuildRows()
    }
    @objc private func deleteRow(_ s: NSButton) {
        let i = s.tag; guard i < entries.count else { return }
        entries.remove(at: i); commit(); rebuildRows()
    }
    @objc private func addRow() {
        entries.append(MenuEntry(title: "Neuer Eintrag", action: MenuAction(.home)))
        commit(); rebuildRows()
    }
    @objc private func resetDefaults() {
        MenuEntryStore.reset()
        entries = MenuEntryStore.entries()
        onChange?()
        rebuildRows()
    }
    @objc private func closeWindow() { window?.close() }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, f.tag < entries.count else { return }
        entries[f.tag].title = f.stringValue
        commit()   // no rebuild → keep editing focus
    }

    private func commit() {
        MenuEntryStore.save(entries)
        onChange?()
    }
}
