import AppKit

protocol TaskbarButtonDelegate: AnyObject {
    func taskbarButtonClicked(_ item: TaskbarItem, button: TaskbarButton?)
    func taskbarButtonToggledPin(_ item: TaskbarItem)
    func taskbarButtonQuit(_ item: TaskbarItem)
    func taskbarButtonHover(_ item: TaskbarItem, button: TaskbarButton)
    func taskbarButtonHoverEnded()
    func taskbarButtonDragBegan(_ button: TaskbarButton, atX x: CGFloat)
    func taskbarButtonDragged(_ button: TaskbarButton, toX x: CGFloat)
    func taskbarButtonDragEnded(_ button: TaskbarButton)
    func taskbarButtonMiddleClicked(_ item: TaskbarItem)
}

/// A single Win7-style taskbar button: icon + label, with running / active / hover states.
final class TaskbarButton: NSControl {
    let item: TaskbarItem
    weak var buttonDelegate: TaskbarButtonDelegate?

    private var hovering = false
    private var hoverTimer: Timer?
    private var downX: CGFloat = 0
    private var dragStarted = false

    init(item: TaskbarItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.buttonWidth, height: Theme.buttonHeight))
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        toolTip = item.name
    }

    required init?(coder: NSCoder) { fatalError() }

    // Deliver the very first click even when our window isn't active (no double-tap).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        hovering = true; needsDisplay = true
        guard item.isRunning else { return }
        hoverTimer?.invalidate()
        let t = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.buttonDelegate?.taskbarButtonHover(self.item, button: self)
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false; needsDisplay = true
        hoverTimer?.invalidate(); hoverTimer = nil
        buttonDelegate?.taskbarButtonHoverEnded()
    }

    private func glassX(_ event: NSEvent) -> CGFloat {
        superview?.convert(event.locationInWindow, from: nil).x ?? frame.minX
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
        hoverTimer?.invalidate(); hoverTimer = nil
        downX = glassX(event)
    }

    override func mouseDragged(with event: NSEvent) {
        let gx = glassX(event)
        if !dragStarted {
            if abs(gx - downX) < 5 { return }       // small threshold before a drag begins
            dragStarted = true
            buttonDelegate?.taskbarButtonDragBegan(self, atX: downX)
        }
        buttonDelegate?.taskbarButtonDragged(self, toX: gx)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStarted {
            buttonDelegate?.taskbarButtonDragEnded(self)
        } else {
            buttonDelegate?.taskbarButtonClicked(item, button: self)
        }
        dragStarted = false
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { buttonDelegate?.taskbarButtonMiddleClicked(item) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        // App-specific actions (e.g. Chromium profiles), like a Win7 jump list.
        let jump = JumpList.actions(for: item)
        if !jump.isEmpty {
            let header = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for action in jump {
                let mi = NSMenuItem(title: action.title, action: #selector(jumpAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = action
                mi.indentationLevel = 1
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }

        let pinTitle = item.pinned ? "Von Taskleiste lösen" : "An Taskleiste anheften"
        let pin = NSMenuItem(title: pinTitle, action: #selector(pinAction), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)

        if item.isRunning {
            menu.addItem(.separator())
            // Finder must never be quit (the desktop would vanish) — only close its windows.
            let isFinder = item.key == "com.apple.finder"
            let quit = NSMenuItem(title: isFinder ? "Alle Fenster schließen" : "Fenster schließen / Beenden",
                                  action: #selector(quitAction), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func jumpAction(_ sender: NSMenuItem) {
        (sender.representedObject as? JumpList.Action)?.perform()
    }

    @objc private func pinAction() { buttonDelegate?.taskbarButtonToggledPin(item) }
    @objc private func quitAction() { buttonDelegate?.taskbarButtonQuit(item) }

    override func draw(_ dirtyRect: NSRect) {
        // Option: button frames spanning the full bar height (top to bottom).
        // The Windows 7 theme always uses full-height slots.
        let win7 = Theme.taskbarStyle == .win7
        let full = win7 || UserDefaults.standard.bool(forKey: "fullHeightIcons")
        let inset = full ? bounds.insetBy(dx: 1, dy: 0) : bounds.insetBy(dx: 2, dy: 4)
        let radius: CGFloat = full ? 2 : 5
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)

        // Finder with only its (untitled) desktop window counts as "not open".
        let finderDesktopOnly = (item.key == "com.apple.finder" && item.windowCount == 0)
        let running = item.isRunning && !finderDesktopOnly
        let active = item.isActive && !finderDesktopOnly

        // The front slot rect (shrinks horizontally when several windows are stacked).
        var frontBox = inset
        if win7 {
            // Authentic Windows 7 button glass: the original state PNGs as 9-slice backgrounds.
            if let bg = win7Background(active: active, running: running) {
                // "Stacked" look: extra windows add sheets stepping to the RIGHT only. The left side
                // stays flush (no offset) and each sheet is clipped to its own, non-overlapping strip
                // so the translucent glass never stacks (no extra opacity). Stays within the box width.
                let layers = min(max(item.windowCount, 1), 3)
                let extra = layers - 1
                let step: CGFloat = 5
                let sheetW = inset.width - CGFloat(extra) * step
                for j in 0...extra {
                    let sheetRect = NSRect(x: inset.minX + CGFloat(j) * step, y: inset.minY,
                                           width: sheetW, height: inset.height)
                    let clipMinX = inset.minX + sheetW + CGFloat(max(j - 1, 0)) * step
                    let clipMaxX = inset.minX + sheetW + CGFloat(j) * step
                    let clip = NSRect(x: j == 0 ? inset.minX : clipMinX, y: inset.minY,
                                      width: (j == 0 ? sheetW : clipMaxX - clipMinX), height: inset.height)
                    NSGraphicsContext.current?.saveGraphicsState()
                    NSBezierPath(rect: clip).addClip()
                    bg.draw(in: sheetRect, from: .zero, operation: .sourceOver, fraction: 1)
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
                frontBox = NSRect(x: inset.minX, y: inset.minY, width: sheetW, height: inset.height)
            }
        } else if active {
            // Glassy translucent highlight for the active app (no colour tint, just lifted glass).
            NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.46),
                                NSColor(calibratedWhite: 1, alpha: 0.16)])?.draw(in: path, angle: -90)
            addGloss(to: inset, radius: radius)
            NSColor(calibratedWhite: 1, alpha: 0.75).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.28),
                                NSColor(calibratedWhite: 1, alpha: 0.09)])?.draw(in: path, angle: -90)
            addGloss(to: inset, radius: radius)
            NSColor(calibratedWhite: 1, alpha: 0.45).setStroke(); path.lineWidth = 1; path.stroke()
        } else if running {
            Theme.runningFill.setFill(); path.fill()
            Theme.runningStroke.setStroke(); path.lineWidth = 1; path.stroke()
        }

        // Icon only — centred, no label (Win7 "small/combine" taskbar mode).
        // Slightly smaller icons in the Windows 7 theme so they sit nicely inside the full-height slot.
        let iconS = win7 ? (Theme.iconSize * 0.85).rounded() : Theme.iconSize
        let iconRect = NSRect(x: frontBox.midX - iconS / 2,
                              y: (bounds.height - iconS) / 2,
                              width: iconS, height: iconS)
        item.icon.draw(in: iconRect,
                       from: .zero,
                       operation: .sourceOver,
                       fraction: running ? 1.0 : 0.78)

        // Notification badge (e.g. Slack/Teams unread) in the top-right of the icon.
        if let badge = item.badge {
            let d = Theme.s(16)
            let r = NSRect(x: iconRect.maxX - d + Theme.s(3),
                           y: iconRect.maxY - d + Theme.s(3), width: d, height: d)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = max(1, Theme.s(1.5))
            ring.stroke()

            let text = badge.count <= 2 ? badge : "·"
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.font(9.5, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            s.draw(in: NSRect(x: r.minX, y: r.midY - s.size().height / 2, width: r.width, height: s.size().height))
        }

        // Win7 "stacked" look for several windows: nested frame edges stepping in from the
        // RIGHT, clipped to the button so the left stays clean and nothing spills onto a
        // neighbour. Outlines only → the glass translucency is unchanged. More windows → narrower.
        if item.windowCount > 1 && Theme.taskbarStyle != .win7 {
            let extra = min(item.windowCount - 1, 3)
            let spacing: CGFloat = extra <= 1 ? 6 : (extra == 2 ? 5 : 4)
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()   // keep the nested frames inside the button (left stays clean)
            NSColor(calibratedWhite: 1, alpha: 0.32).setStroke()
            for i in 1...extra {
                let off = CGFloat(i) * spacing
                let r = NSRect(x: inset.minX - off, y: inset.minY, width: inset.width, height: inset.height)
                let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
                p.lineWidth = 1
                p.stroke()
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    /// The original Windows 7 button-slot background for the current state (nil = no background).
    private func win7Background(active: Bool, running: Bool) -> NSImage? {
        let name: String?
        if active {
            name = "ActiveNormal"
        } else if running {
            name = hovering ? "InactivePointerOver" : "InactiveNormal"
        } else {
            name = hovering ? "notRunningPointerOver" : nil   // pinned, not running: only on hover
        }
        return name.flatMap { ThemeAssets.resizable($0, caps: 8) }
    }

    /// Aero gloss: a bright highlight over the top half of the button.
    private func addGloss(to rect: NSRect, radius: CGFloat) {
        let glossRect = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.current?.saveGraphicsState()
        clip.addClip()
        NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.30),
                            NSColor(calibratedWhite: 1, alpha: 0.0)])?.draw(in: glossRect, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
