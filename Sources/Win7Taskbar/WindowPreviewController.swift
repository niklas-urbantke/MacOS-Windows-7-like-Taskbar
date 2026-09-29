import AppKit

/// Windows-7 "Aero Peek" style hover preview: a floating glass panel above the taskbar button
/// showing live thumbnails of an app's windows. Clicking a thumbnail raises that window.
/// In the Win11 profile the panel looks like the Win11 flyouts (Acryl, cards with a title row).
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

    private let thumbH: CGFloat = 122
    private let titleH: CGFloat = 18
    private let pad: CGFloat = 10
    private let spacing: CGFloat = 8

    /// Win11 metrics (panels are not scaled with the bar height, like the flyouts).
    private enum W11 {
        static let thumbH: CGFloat = 116
        static let pad: CGFloat = 6        // panel edge → cards
        static let spacing: CGFloat = 2    // between cards
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
            if Theme.isWin11 {
                self.buildWin11(items: items, pid: pid, appName: appName, icon: icon,
                                anchorRect: anchorRect, screen: screen)
            } else {
                self.build(items: items, pid: pid, anchorRect: anchorRect, screen: screen,
                           needsPermission: !granted)
            }
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

    private func build(items: [PreviewItem], pid: pid_t, anchorRect: NSRect,
                       screen: NSScreen, needsPermission: Bool) {
        claimPanel()
        panel.alphaValue = 1
        panel.appearance = nil
        content.style = .classic
        content.cards.subviews.forEach { $0.removeFromSuperview() }

        var x = pad
        for item in items {
            let aspect = (item.image.map { $0.size.width / max(1, $0.size.height) }) ?? 1.5
            let w = item.image != nil ? min(260, max(150, thumbH * aspect)) : 170
            let thumb = PreviewThumb(
                item: item,
                size: NSSize(width: w, height: thumbH + titleH),
                onClick: { [weak self] in WindowPreview.raise(item, pid: pid); self?.hideNow() },
                onClose: { [weak self] in
                    WindowPreview.close(item, pid: pid)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.reload() }
                })
            thumb.frame = NSRect(x: x, y: pad, width: w, height: thumbH + titleH)
            content.cards.addSubview(thumb)
            x += w + spacing
        }
        let panelW = x - spacing + pad
        let panelH = thumbH + titleH + pad * 2

        var px = anchorRect.midX - panelW / 2
        px = max(screen.frame.minX + 4, min(px, screen.frame.maxX - panelW - 4))
        let py = anchorRect.maxY + 6
        panel.setFrame(NSRect(x: px, y: py, width: panelW, height: panelH), display: true)
        content.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
        panel.orderFront(nil)
        DebugLog.log("preview shown frame=\(panel.frame) thumbs=\(content.cards.subviews.count)")
    }

    /// Win11 look: one card per window (title row with icon, thumbnail below), panel like a flyout,
    /// 12 px above the bar, centred over the taskbar button, fades and slides in.
    private func buildWin11(items: [PreviewItem], pid: pid_t, appName: String, icon: NSImage?,
                            anchorRect: NSRect, screen: NSScreen) {
        let appearing = !panel.isVisible || hiding
        claimPanel()
        panel.appearance = Theme.win11NSAppearance
        content.style = .win11
        content.cards.subviews.forEach { $0.removeFromSuperview() }

        var x = W11.pad
        var cardH: CGFloat = 0
        for item in items {
            let aspect = (item.image.map { $0.size.width / max(1, $0.size.height) }) ?? 1.5
            let tw = item.image != nil ? min(260, max(150, W11.thumbH * aspect)).rounded() : 170
            let title = item.title.trimmingCharacters(in: .whitespaces).isEmpty ? appName : item.title
            let card = Win11PreviewCard(
                item: item, title: title, icon: item.appIcon ?? icon,
                thumbSize: NSSize(width: tw, height: W11.thumbH),
                onClick: { [weak self] in WindowPreview.raise(item, pid: pid); self?.hideNow() },
                onClose: { [weak self] in
                    WindowPreview.close(item, pid: pid)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.reload() }
                })
            let size = card.preferredSize
            card.frame = NSRect(x: x, y: W11.pad, width: size.width, height: size.height)
            content.cards.addSubview(card)
            x += size.width + W11.spacing
            cardH = max(cardH, size.height)
        }
        let panelW = x - W11.spacing + W11.pad
        let panelH = cardH + 2 * W11.pad

        let sf = screen.frame
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

private final class PreviewContentView: NSView {
    enum Style { case classic, win11 }

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// Holds the thumbnails / cards (above the Win11 surface, below its border).
    let cards = NSView()
    var style: Style = .classic { didSet { applyStyle() } }

    // Win11 layers: blur (Acryl), tinted surface, border on top.
    private let blur = NSVisualEffectView()
    private let surface = Win11FlyoutSurface()
    private let stroke = Win11FlyoutStroke()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for v in [blur, surface, cards, stroke] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyStyle() {
        let win11 = style == .win11
        blur.isHidden = !win11
        surface.isHidden = !win11
        stroke.isHidden = !win11
        if win11 {
            Theme.Win11.configureBlur(blur, for: .flyout)   // hides itself when Acryl is off
            blur.maskImage = Win11FlyoutPanel.roundedMask(radius: Theme.Win11.panelRadius)
            layer?.cornerRadius = 0
            layer?.masksToBounds = false
            layer?.borderWidth = 0
            surface.needsDisplay = true
            stroke.needsDisplay = true
        } else {
            layer?.cornerRadius = 8
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }

    override func draw(_ dirtyRect: NSRect) {
        guard style == .classic else { return }   // Win11: drawn by the surface / stroke views
        NSGradient(colors: [NSColor(calibratedWhite: 0.20, alpha: 0.96),
                            NSColor(calibratedWhite: 0.08, alpha: 0.97)])?.draw(in: bounds, angle: -90)
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

// MARK: - A single thumbnail (image + title) or title row

private final class PreviewThumb: NSView {
    private let item: PreviewItem
    private let onClick: () -> Void
    private let onClose: () -> Void
    private var hovering = false
    private let titleH: CGFloat = 18
    private let closeSize: CGFloat = 18

    init(item: PreviewItem, size: NSSize, onClick: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.item = item; self.onClick = onClick; self.onClose = onClose
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - closeSize - 4, y: bounds.maxY - closeSize - 4, width: closeSize, height: closeSize)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if hovering && closeRect.contains(p) { onClose() } else { onClick() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.accent(brightness: 1.3, saturation: 0.7, alpha: 0.35).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            Theme.accent(brightness: 1.2, alpha: 0.9).setStroke()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            p.lineWidth = 1; p.stroke()
        }

        let area = NSRect(x: 4, y: titleH + 2, width: bounds.width - 8, height: bounds.height - titleH - 6)
        if let img = item.image {
            let aspect = img.size.width / max(1, img.size.height)
            var dw = area.width, dh = dw / aspect
            if dh > area.height { dh = area.height; dw = dh * aspect }
            let dest = NSRect(x: area.midX - dw / 2, y: area.midY - dh / 2, width: dw, height: dh)
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: dest.insetBy(dx: -1, dy: -1)).fill()
            img.draw(in: dest)
        } else {
            // Minimised (or no thumbnail): show the app icon as a placeholder.
            let s: CGFloat = 56
            let r = NSRect(x: area.midX - s / 2, y: area.midY - s / 2, width: s, height: s)
            item.appIcon?.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.9)
            if item.isMinimized {
                let badge = NSAttributedString(string: "minimiert", attributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor(calibratedWhite: 0.8, alpha: 1)])
                let bs = badge.size()
                badge.draw(at: NSPoint(x: area.midX - bs.width / 2, y: area.minY + 2))
            }
        }

        drawTitle(in: NSRect(x: 4, y: 1, width: bounds.width - 8, height: titleH))
        if hovering { drawCloseButton() }
    }

    private func drawCloseButton() {
        let r = closeRect
        NSColor(calibratedRed: 0.82, green: 0.20, blue: 0.18, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.white.setStroke()
        let x = NSBezierPath(); x.lineWidth = 1.6
        let i = r.insetBy(dx: 5, dy: 5)
        x.move(to: NSPoint(x: i.minX, y: i.minY)); x.line(to: NSPoint(x: i.maxX, y: i.maxY))
        x.move(to: NSPoint(x: i.minX, y: i.maxY)); x.line(to: NSPoint(x: i.maxX, y: i.minY))
        x.stroke()
    }

    private func drawTitle(in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1),
            .paragraphStyle: style,
        ]
        let s = NSAttributedString(string: item.title.isEmpty ? "Fenster" : item.title, attributes: attrs)
        s.draw(in: NSRect(x: rect.minX, y: rect.midY - 7, width: rect.width, height: 14))
    }
}

// MARK: - Win11 card (title row + thumbnail)

/// Eine Win11-Vorschaukarte: Titelzeile (App-Symbol, Fenstertitel, × bei Hover), darunter das
/// Vorschaubild. Hover füllt die Karte; Hover auf × färbt es rot.
private final class Win11PreviewCard: NSView {
    private let item: PreviewItem
    private let title: String
    private let icon: NSImage?
    private let thumbSize: NSSize
    private let onClick: () -> Void
    private let onClose: () -> Void
    private var hovering = false
    private var closeHover = false

    private let pad: CGFloat = 8          // card edge → content
    private let top: CGFloat = 6
    private let titleH: CGFloat = 24
    private let titleGap: CGFloat = 4     // title row → thumbnail
    private let iconSize: CGFloat = 16
    private let closeSize: CGFloat = 24

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
        NSRect(x: bounds.maxX - 4 - closeSize, y: top + ((titleH - closeSize) / 2).rounded(),
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
        let W = Theme.Win11.self
        if hovering { Win11TrayDraw.fill(bounds, radius: 6, W.hoverFill) }

        // Title row: icon, title (shortened), × on hover.
        let rowMidY = top + titleH / 2
        var tx = pad
        if let icon {
            let r = NSRect(x: pad, y: (rowMidY - iconSize / 2).rounded(), width: iconSize, height: iconSize)
            icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: item.isMinimized ? 0.6 : 1,
                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            tx = r.maxX + 8
        }
        let t = Win11TrayDraw.text(title, font: NSFont.systemFont(ofSize: 12), color: W.textPrimary)
        let th = ceil(t.size().height)
        t.draw(in: NSRect(x: tx, y: (rowMidY - th / 2).rounded(), width: max(0, closeRect.minX - 4 - tx), height: th))

        if hovering {
            let c = closeRect
            if closeHover { Win11TrayDraw.fill(c, radius: 4, NSColor.systemRed) }
            if let x = Win11TrayDraw.symbol(["xmark"], pointSize: 11, weight: .medium,
                                             color: closeHover ? .white : W.textPrimary) {
                Win11TrayDraw.draw(x, centeredIn: c)
            }
        }

        drawThumbnail(in: thumbRect)
    }

    private func drawThumbnail(in area: NSRect) {
        let W = Theme.Win11.self
        if let img = item.image {
            // Aspect fit, rounded corners on the image itself.
            let aspect = img.size.width / max(1, img.size.height)
            var dw = area.width, dh = dw / aspect
            if dh > area.height { dh = area.height; dw = dh * aspect }
            let dest = NSRect(x: (area.midX - dw / 2).rounded(), y: (area.midY - dh / 2).rounded(),
                              width: dw.rounded(), height: dh.rounded())
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSBezierPath(roundedRect: dest, xRadius: 4, yRadius: 4).addClip()
            img.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        // Minimised (or no thumbnail): app icon on a subtle tile, slightly dimmed when minimised.
        Win11TrayDraw.fill(area, radius: 4, W.controlFill)
        let s: CGFloat = 48
        let hasBadge = item.isMinimized
        let iconY = area.midY - s / 2 - (hasBadge ? 8 : 0)
        icon?.draw(in: NSRect(x: (area.midX - s / 2).rounded(), y: iconY.rounded(), width: s, height: s),
                   from: .zero, operation: .sourceOver, fraction: hasBadge ? 0.6 : 0.9,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        if hasBadge {
            let b = Win11TrayDraw.text("minimiert", font: NSFont.systemFont(ofSize: 11),
                                       color: W.textSecondary, alignment: .center)
            let bh = ceil(b.size().height)
            b.draw(in: NSRect(x: area.minX, y: (iconY + s + 4).rounded(), width: area.width, height: bh))
        }
    }
}
