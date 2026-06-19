import AppKit

protocol TaskbarButtonDelegate: AnyObject {
    func taskbarButtonClicked(_ item: TaskbarItem)
    func taskbarButtonToggledPin(_ item: TaskbarItem)
    func taskbarButtonQuit(_ item: TaskbarItem)
    func taskbarButtonHover(_ item: TaskbarItem, button: TaskbarButton)
    func taskbarButtonHoverEnded()
    func taskbarButtonDragBegan(_ button: TaskbarButton, atX x: CGFloat)
    func taskbarButtonDragged(_ button: TaskbarButton, toX x: CGFloat)
    func taskbarButtonDragEnded(_ button: TaskbarButton)
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
            buttonDelegate?.taskbarButtonClicked(item)
        }
        dragStarted = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let pinTitle = item.pinned ? "Von Taskleiste lösen" : "An Taskleiste anheften"
        let pin = NSMenuItem(title: pinTitle, action: #selector(pinAction), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)

        if item.isRunning {
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Fenster schließen / Beenden",
                                  action: #selector(quitAction), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func pinAction() { buttonDelegate?.taskbarButtonToggledPin(item) }
    @objc private func quitAction() { buttonDelegate?.taskbarButtonQuit(item) }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 2, dy: 4)
        let path = NSBezierPath(roundedRect: inset, xRadius: 5, yRadius: 5)

        if item.isActive {
            // Accent-tinted glass for the active app.
            let top = Theme.accent(brightness: 1.25, saturation: 0.7, alpha: 0.45)
            let bottom = Theme.accent(brightness: 0.85, saturation: 1.0, alpha: 0.45)
            NSGradient(colors: [top, bottom])?.draw(in: path, angle: -90)
            addGloss(to: inset)
            Theme.accent(brightness: 1.2, alpha: 0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            let top = Theme.accent(brightness: 1.3, saturation: 0.5, alpha: 0.28)
            let bottom = Theme.accent(brightness: 1.0, saturation: 0.7, alpha: 0.28)
            NSGradient(colors: [top, bottom])?.draw(in: path, angle: -90)
            addGloss(to: inset)
            Theme.accent(brightness: 1.2, alpha: 0.5).setStroke(); path.lineWidth = 1; path.stroke()
        } else if item.isRunning {
            Theme.runningFill.setFill(); path.fill()
            Theme.runningStroke.setStroke(); path.lineWidth = 1; path.stroke()
        }

        // Icon only — centred, no label (Win7 "small/combine" taskbar mode).
        let iconRect = NSRect(x: (bounds.width - Theme.iconSize) / 2,
                              y: (bounds.height - Theme.iconSize) / 2,
                              width: Theme.iconSize, height: Theme.iconSize)
        item.icon.draw(in: iconRect,
                       from: .zero,
                       operation: .sourceOver,
                       fraction: item.isRunning ? 1.0 : 0.78)

        // Running indicator: a thin lit underline along the bottom of the button.
        if item.isRunning {
            let color = item.isActive ? Theme.accent(brightness: 1.3) : Theme.accent(brightness: 1.0, alpha: 0.7)
            color.setStroke()
            let underline = NSBezierPath()
            underline.move(to: NSPoint(x: inset.minX + 8, y: inset.minY + 2))
            underline.line(to: NSPoint(x: inset.maxX - 8, y: inset.minY + 2))
            underline.lineWidth = 2.5
            underline.stroke()
        }
    }

    /// Aero gloss: a bright highlight over the top half of the button.
    private func addGloss(to rect: NSRect) {
        let glossRect = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        let clip = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.current?.saveGraphicsState()
        clip.addClip()
        NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.30),
                            NSColor(calibratedWhite: 1, alpha: 0.0)])?.draw(in: glossRect, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
