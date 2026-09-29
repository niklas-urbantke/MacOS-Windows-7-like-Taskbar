import AppKit

/// Hover preview above the taskbar button: one card per window (title row with app icon and
/// window title, live thumbnail below). Clicking a card raises that window, × closes it.
/// The panel follows the style profile (`FlyoutLook`): Win11 like the Win11 flyouts (Acryl), Vista
/// and Windows 7 as an Aero glass panel ("Aero Peek").
final class WindowPreviewController {
    private let panel: NSPanel
    private let content = PreviewContentView()
    private var currentPID: pid_t?
    private var hideWork: DispatchWorkItem?
    private var token = 0
    private var ctx: (pid: pid_t, appName: String, icon: NSImage?, anchor: NSRect, screen: NSScreen)?
    /// Win11 fade-out in progress (a show during it takes over the panel again).
    private var hiding = false
    private var hideGen = 0

    /// Panel metrics (not scaled with the bar height, like the flyouts).
    private struct Metrics {
        let thumbH: CGFloat
        let pad: CGFloat       // panel edge → cards
        let spacing: CGFloat   // between cards
        static let win11 = Metrics(thumbH: 116, pad: 6, spacing: 2)
        static let aero = Metrics(thumbH: 116, pad: 8, spacing: 4)
    }
    /// Win11 placement.
    private enum W11 {
        static let gap: CGFloat = 12       // bar top → panel
        static let margin: CGFloat = 12    // minimum distance to the screen edges
        static let slide: CGFloat = 10
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isFloatingPanel = true

        content.onEnter = { [weak self] in self?.cancelHide() }
        content.onExit = { [weak self] in self?.scheduleHide() }
        panel.contentView = content
    }

    // MARK: - Show / hide

    func show(pid: pid_t, appName: String, icon: NSImage?, anchorRect: NSRect, screen: NSScreen,
              force: Bool = false) {
        cancelHide()
        if !force && panel.isVisible && currentPID == pid { return }
        currentPID = pid
        ctx = (pid, appName, icon, anchorRect, screen)
        token += 1
        let myToken = token

        Task { @MainActor in
            let granted = WindowPreview.hasScreenRecording
            if !granted { _ = WindowPreview.requestScreenRecording() }
            let items = await WindowPreview.fetch(pid: pid, appIcon: icon)
            DebugLog.log("preview pid=\(pid) screenRec=\(granted) ax=\(AXIsProcessTrusted()) items=\(items.count)")

            guard self.token == myToken, self.currentPID == pid else { return }
            if items.isEmpty { self.hideNow(); return }
            self.build(items: items, pid: pid, appName: appName, icon: icon,
                       anchorRect: anchorRect, screen: screen)
        }
    }

    private func reload() {
        guard let c = ctx else { return }
        show(pid: c.pid, appName: c.appName, icon: c.icon, anchorRect: c.anchor, screen: c.screen, force: true)
    }

    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideNow() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    func cancelHide() { hideWork?.cancel(); hideWork = nil }

    private func hideNow() {
        currentPID = nil
        hideGen += 1
        guard Theme.isWin11, panel.isVisible, !reduceMotion else {
            hiding = false
            panel.orderOut(nil)
            return
        }
        // Win11: short fade-out; a new show() in the meantime cancels the orderOut.
        hiding = true
        let g = hideGen
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGen == g else { return }
            self.hiding = false
            self.panel.orderOut(nil)
        })
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Takes the panel over for a new build: cancels a running fade-out.
    private func claimPanel() {
        hideGen += 1
        hiding = false
    }

    // MARK: - Build

    /// One card per window, panel in the look of the profile. Win11: 12 px above the bar, centred
    /// over the button, fades and slides in. Vista / Windows 7: right above the button, appears at once.
    private func build(items: [PreviewItem], pid: pid_t, appName: String, icon: NSImage?,
                       anchorRect: NSRect, screen: NSScreen) {
        let aero = FlyoutLook.isAero
        let m = aero ? Metrics.aero : Metrics.win11
        let appearing = !panel.isVisible || hiding
        claimPanel()
        panel.appearance = Theme.nsAppearance
        content.applyLook()
        content.cards.subviews.forEach { $0.removeFromSuperview() }

        var x = m.pad
        var cardH: CGFloat = 0
        for item in items {
            let aspect = (item.image.map { $0.size.width / max(1, $0.size.height) }) ?? 1.5
            let tw = item.image != nil ? min(260, max(150, m.thumbH * aspect)).rounded() : 170
            let title = item.title.trimmingCharacters(in: .whitespaces).isEmpty ? appName : item.title
            let card = PreviewCard(
                item: item, title: title, icon: item.appIcon ?? icon,
                thumbSize: NSSize(width: tw, height: m.thumbH),
                onClick: { [weak self] in WindowPreview.raise(item, pid: pid); self?.hideNow() },
                onClose: { [weak self] in
                    WindowPreview.close(item, pid: pid)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.reload() }
                })
            let size = card.preferredSize
            card.frame = NSRect(x: x, y: m.pad, width: size.width, height: size.height)
            content.cards.addSubview(card)
            x += size.width + m.spacing
            cardH = max(cardH, size.height)
        }
        let panelW = x - m.spacing + m.pad
        let panelH = cardH + 2 * m.pad
        let sf = screen.frame

        if aero {
            // Classic placement (as before): right above the button, kept on the screen.
            var px = (anchorRect.midX - panelW / 2).rounded()
            px = max(sf.minX + 4, min(px, sf.maxX - panelW - 4))
            let target = NSRect(x: px, y: (anchorRect.maxY + 6).rounded(), width: panelW, height: panelH)
            content.frame = NSRect(origin: .zero, size: target.size)
            panel.alphaValue = 1
            panel.setFrame(target, display: true)
            panel.orderFront(nil)
            panel.invalidateShadow()
            DebugLog.log("preview shown frame=\(target) cards=\(content.cards.subviews.count)")
            return
        }

        var px = (anchorRect.midX - panelW / 2).rounded()
        px = max(sf.minX + W11.margin, min(px, sf.maxX - W11.margin - panelW))
        let py = (sf.minY + Theme.barHeight + W11.gap).rounded()
        let target = NSRect(x: px, y: py, width: panelW, height: panelH)
        content.frame = NSRect(origin: .zero, size: target.size)

        if !appearing {
            // Already open (e.g. moved to the next button, or reloaded after a close): jump.
            panel.alphaValue = 1
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        } else if reduceMotion {
            panel.setFrame(target, display: true)
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                self.panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        } else {
            panel.setFrame(target.offsetBy(dx: 0, dy: -W11.slide), display: true)
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
                self.panel.animator().setFrame(target, display: true)
                self.panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        }
        DebugLog.log("preview11 shown frame=\(target) cards=\(content.cards.subviews.count)")
    }
}

// MARK: - Panel background with hover tracking

/// Panel content: blur, surface (Acryl or Aero glass), the cards, border on top.
private final class PreviewContentView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// Holds the cards (above the surface, below the border).
    let cards = NSView()

    private let blur = NSVisualEffectView()
    private let surface = Win11FlyoutSurface()
    private let stroke = Win11FlyoutStroke()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for v in [blur, surface, cards, stroke] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        applyLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Re-reads profile and colour mode (called on every build).
    func applyLook() {
        FlyoutLook.configureBlur(blur)
        surface.needsDisplay = true
        stroke.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

// MARK: - Card (title row + thumbnail)

/// Eine Vorschaukarte: Titelzeile (App-Symbol, Fenstertitel, × bei Hover), darunter das
/// Vorschaubild. Hover hebt die Karte hervor (Win11 flach, Aero als Glas); Hover auf × färbt es rot.
private final class PreviewCard: NSView {
    private let item: PreviewItem
    private let title: String
    private let icon: NSImage?
    private let thumbSize: NSSize
    private let onClick: () -> Void
    private let onClose: () -> Void
    private var hovering = false
    private var closeHover = false

    private let aero = FlyoutLook.isAero
    private let pad: CGFloat = 8          // card edge → content
    private let top: CGFloat = 6
    private let titleH: CGFloat = 24
    private let titleGap: CGFloat = 4     // title row → thumbnail
    private let iconSize: CGFloat = 16
    private var closeSize: CGFloat { aero ? 20 : 24 }
    private var cardRadius: CGFloat { aero ? 4 : 6 }
    private var imageRadius: CGFloat { aero ? 1 : 4 }

    var preferredSize: NSSize {
        NSSize(width: thumbSize.width + 2 * pad, height: top + titleH + titleGap + thumbSize.height + pad)
    }

    init(item: PreviewItem, title: String, icon: NSImage?, thumbSize: NSSize,
         onClick: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.item = item; self.title = title; self.icon = icon; self.thumbSize = thumbSize
        self.onClick = onClick; self.onClose = onClose
        super.init(frame: .zero)
        toolTip = title
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - (aero ? 6 : 4) - closeSize, y: top + ((titleH - closeSize) / 2).rounded(),
               width: closeSize, height: closeSize)
    }
    private var thumbRect: NSRect {
        NSRect(x: pad, y: top + titleH + titleGap, width: thumbSize.width, height: thumbSize.height)
    }

    private func updateHover(_ e: NSEvent?) {
        let p = e.map { convert($0.locationInWindow, from: nil) }
        let h = p.map { bounds.contains($0) } ?? false
        let c = h && (p.map { closeRect.contains($0) } ?? false)
        if h != hovering || c != closeHover { hovering = h; closeHover = c; needsDisplay = true }
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { updateHover(nil) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if hovering && closeRect.contains(p) { onClose() } else { onClick() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let L = FlyoutLook.self
        if hovering { L.drawHover(bounds, radius: cardRadius) }

        // Title row: icon, title (shortened), × on hover.
        let rowMidY = top + titleH / 2
        var tx = pad
        if let icon {
            let r = NSRect(x: pad, y: (rowMidY - iconSize / 2).rounded(), width: iconSize, height: iconSize)
            icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: item.isMinimized ? 0.6 : 1,
                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            tx = r.maxX + (aero ? 6 : 8)
        }
        let t = Win11TrayDraw.text(title, font: NSFont.systemFont(ofSize: 12),
                                   color: item.isMinimized && aero ? L.textSecondary : L.textPrimary)
        let th = ceil(t.size().height)
        t.draw(in: NSRect(x: tx, y: (rowMidY - th / 2).rounded(), width: max(0, closeRect.minX - 4 - tx), height: th))

        if hovering {
            let c = closeRect
            if closeHover { L.drawCloseHover(c, radius: aero ? 3 : 4) }
            if let x = Win11TrayDraw.symbol(["xmark"], pointSize: aero ? 10 : 11, weight: aero ? .bold : .medium,
                                             color: closeHover ? .white : L.textPrimary) {
                Win11TrayDraw.draw(x, centeredIn: c)
            }
        }

        drawThumbnail(in: thumbRect)
    }

    private func drawThumbnail(in area: NSRect) {
        let L = FlyoutLook.self
        if let img = item.image {
            // Aspect fit, rounded corners on the image itself (Aero: nearly square with a thin frame).
            let aspect = img.size.width / max(1, img.size.height)
            var dw = area.width, dh = dw / aspect
            if dh > area.height { dh = area.height; dw = dh * aspect }
            let dest = NSRect(x: (area.midX - dw / 2).rounded(), y: (area.midY - dh / 2).rounded(),
                              width: dw.rounded(), height: dh.rounded())
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSBezierPath(roundedRect: dest, xRadius: imageRadius, yRadius: imageRadius).addClip()
            img.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            L.drawImageFrame(dest, radius: imageRadius)
            return
        }
        // Minimised (or no thumbnail): app icon on a subtle tile, slightly dimmed when minimised.
        Win11TrayDraw.fill(area, radius: aero ? 2 : 4, L.tileFill)
        if aero { L.drawImageFrame(area.insetBy(dx: 0.5, dy: 0.5), radius: 2) }
        let s: CGFloat = 48
        let hasBadge = item.isMinimized
        let iconY = area.midY - s / 2 - (hasBadge ? 8 : 0)
        icon?.draw(in: NSRect(x: (area.midX - s / 2).rounded(), y: iconY.rounded(), width: s, height: s),
                   from: .zero, operation: .sourceOver, fraction: hasBadge ? 0.6 : 0.9,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        if hasBadge {
            let b = Win11TrayDraw.text("minimiert", font: NSFont.systemFont(ofSize: 11),
                                       color: L.textSecondary, alignment: .center)
            let bh = ceil(b.size().height)
            b.draw(in: NSRect(x: area.minX, y: (iconY + s + 4).rounded(), width: area.width, height: bh))
        }
    }
}
