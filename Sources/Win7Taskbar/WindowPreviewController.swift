import AppKit

/// Windows-7 "Aero Peek" style hover preview: a floating glass panel above the taskbar button
/// showing live thumbnails of an app's windows. Clicking a thumbnail raises that window.
final class WindowPreviewController {
    private let panel: NSPanel
    private let content = PreviewContentView()
    private var currentPID: pid_t?
    private var hideWork: DispatchWorkItem?
    private var token = 0
    private var ctx: (pid: pid_t, appName: String, icon: NSImage?, anchor: NSRect, screen: NSScreen)?

    private let thumbH: CGFloat = 122
    private let titleH: CGFloat = 18
    private let pad: CGFloat = 10
    private let spacing: CGFloat = 8

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
            self.build(items: items, pid: pid, anchorRect: anchorRect, screen: screen,
                       needsPermission: !granted)
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
        panel.orderOut(nil)
    }

    // MARK: - Build

    private func build(items: [PreviewItem], pid: pid_t, anchorRect: NSRect,
                       screen: NSScreen, needsPermission: Bool) {
        content.subviews.forEach { $0.removeFromSuperview() }

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
            content.addSubview(thumb)
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
        DebugLog.log("preview shown frame=\(panel.frame) thumbs=\(content.subviews.count)")
    }
}

// MARK: - Panel background with hover tracking

private final class PreviewContentView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }

    override func draw(_ dirtyRect: NSRect) {
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
