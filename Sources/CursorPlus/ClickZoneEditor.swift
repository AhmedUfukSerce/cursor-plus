import AppKit
import CoreGraphics

/// Borderless full-screen overlay window that can become key (to receive Esc /
/// Delete / Return). Spans the union of all displays.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Editor view

/// Interactive rectangle editor. Holds zones as view-local rects (top-left origin,
/// `isFlipped = true`, so mouse math and drawing share one coordinate system).
/// Drag empty space = create; click = select (8 resize handles appear); drag a
/// handle = crop/resize; drag interior = move; Delete = remove; Esc/Return = close.
final class ClickZoneEditorView: NSView {

    enum Handle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft:     return CGPoint(x: r.minX, y: r.minY)
            case .top:         return CGPoint(x: r.midX, y: r.minY)
            case .topRight:    return CGPoint(x: r.maxX, y: r.minY)
            case .left:        return CGPoint(x: r.minX, y: r.midY)
            case .right:       return CGPoint(x: r.maxX, y: r.midY)
            case .bottomLeft:  return CGPoint(x: r.minX, y: r.maxY)
            case .bottom:      return CGPoint(x: r.midX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
    }

    private enum HitTarget { case handle(Handle), interior(Int), empty }
    private enum DragMode { case none, creating, moving, resizing(Handle) }

    private(set) var rects: [CGRect] = []
    private var selected: Int?

    var onChange: (([CGRect]) -> Void)?
    var onClose: (() -> Void)?

    private let minSize: CGFloat = 10
    private let handleSize: CGFloat = 9
    private let handleTolerance: CGFloat = 9

    private var mode: DragMode = .none
    private var dragStart: CGPoint = .zero
    private var originalRect: CGRect = .zero
    private var creating: CGRect = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setRects(_ r: [CGRect]) { rects = r; selected = nil; needsDisplay = true }

    // MARK: Hit testing (handles of selected first, then interiors top-most, then empty)

    private func hitTarget(at p: CGPoint) -> HitTarget {
        if let i = selected, rects.indices.contains(i) {
            for h in Handle.allCases {
                let c = h.point(in: rects[i])
                let grab = CGRect(x: c.x - handleTolerance, y: c.y - handleTolerance,
                                  width: handleTolerance * 2, height: handleTolerance * 2)
                if grab.contains(p) { return .handle(h) }
            }
        }
        for i in stride(from: rects.count - 1, through: 0, by: -1) {
            if rects[i].contains(p) { return .interior(i) }
        }
        return .empty
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        switch hitTarget(at: p) {
        case .handle(let h):
            guard let i = selected, rects.indices.contains(i) else { return }
            originalRect = rects[i]
            mode = .resizing(h)
        case .interior(let i):
            selected = i
            originalRect = rects[i]
            mode = .moving
        case .empty:
            selected = nil
            creating = CGRect(origin: p, size: .zero)
            mode = .creating
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .creating:
            creating = normalized(from: dragStart, to: p)
        case .moving:
            guard let i = selected else { return }
            rects[i] = clampToBounds(originalRect.offsetBy(dx: p.x - dragStart.x, dy: p.y - dragStart.y))
        case .resizing(let h):
            guard let i = selected else { return }
            rects[i] = resize(originalRect, handle: h, to: p)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .creating:
            if creating.width >= minSize && creating.height >= minSize {
                rects.append(clampToBounds(creating))
                selected = rects.count - 1
                onChange?(rects)
            }
            creating = .zero
        case .moving, .resizing:
            onChange?(rects)
        case .none:
            break
        }
        mode = .none
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:                       // Delete / Forward-Delete
            if let i = selected, rects.indices.contains(i) {
                rects.remove(at: i)
                selected = nil
                onChange?(rects)
                needsDisplay = true
            }
        case 53, 36, 76:                    // Esc / Return / Enter -> done
            onClose?()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Geometry helpers

    private func normalized(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func resize(_ orig: CGRect, handle h: Handle, to p: CGPoint) -> CGRect {
        var left = orig.minX, right = orig.maxX, top = orig.minY, bottom = orig.maxY
        switch h {
        case .topLeft:     left = p.x; top = p.y
        case .top:         top = p.y
        case .topRight:    right = p.x; top = p.y
        case .left:        left = p.x
        case .right:       right = p.x
        case .bottomLeft:  left = p.x; bottom = p.y
        case .bottom:      bottom = p.y
        case .bottomRight: right = p.x; bottom = p.y
        }
        var r = CGRect(x: min(left, right), y: min(top, bottom),
                       width: abs(right - left), height: abs(bottom - top))
        if r.width < minSize { r.size.width = minSize }
        if r.height < minSize { r.size.height = minSize }
        return clampToBounds(r)
    }

    private func clampToBounds(_ r: CGRect) -> CGRect {
        var r = r
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim scrim so the user clearly sees they're in edit mode.
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()

        var live: [(CGRect, Bool)] = rects.enumerated().map { ($0.element, $0.offset == selected) }
        if case .creating = mode { live.append((creating, true)) }

        for (r, sel) in live {
            (sel ? NSColor.systemBlue : NSColor.white).withAlphaComponent(sel ? 0.28 : 0.15).setFill()
            r.fill()
            let path = NSBezierPath(rect: r)
            path.lineWidth = sel ? 2 : 1
            (sel ? NSColor.systemBlue : NSColor.white).setStroke()
            path.stroke()
        }

        if let i = selected, rects.indices.contains(i) {
            NSColor.white.setFill()
            NSColor.systemBlue.setStroke()
            for h in Handle.allCases {
                let c = h.point(in: rects[i])
                let sq = CGRect(x: c.x - handleSize / 2, y: c.y - handleSize / 2,
                                width: handleSize, height: handleSize)
                let hp = NSBezierPath(rect: sq)
                hp.fill(); hp.lineWidth = 1; hp.stroke()
            }
        }

        drawHint()
    }

    private func drawHint() {
        let text = "Drag to add a click zone  •  click to select  •  drag handles to crop  •  ⌫ delete  •  esc/return done"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 8
        // Top of a flipped view is y = 0.
        let box = CGRect(x: bounds.midX - (size.width + pad * 2) / 2, y: 18,
                         width: size.width + pad * 2, height: size.height + pad * 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        str.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad))
    }
}

// MARK: - Controller

/// Opens/closes the overlay editor and bridges its view-local rects to the CG
/// global top-left zones persisted in Settings.
final class ClickZoneEditorController {

    private let settings: Settings
    private var window: OverlayWindow?
    private var view: ClickZoneEditorView?

    /// Called after the editor closes (so the owner can clear its UI hold).
    var onClose: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
    }

    var isOpen: Bool { window != nil }

    func open() {
        if isOpen { window?.makeKeyAndOrderFront(nil); return }

        let frame = Self.unionScreenFrame()
        let win = OverlayWindow(contentRect: frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .screenSaver
        win.ignoresMouseEvents = false
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.setFrame(frame, display: true)

        let v = ClickZoneEditorView(frame: NSRect(origin: .zero, size: frame.size))
        v.autoresizingMask = [.width, .height]
        win.contentView = v
        self.window = win
        self.view = v

        // Convert persisted CG zones -> view-local for display (window is positioned now).
        v.setRects(settings.loadClickZones().map { cgToLocal($0) })
        v.onChange = { [weak self] _ in self?.persist() }
        v.onClose = { [weak self] in self?.close() }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(v)
    }

    func close() {
        persist()
        window?.orderOut(nil)
        window = nil
        view = nil
        onClose?()
    }

    private func persist() {
        guard let v = view else { return }
        settings.saveClickZones(v.rects.map { localToCG($0) })
    }

    // MARK: Coordinate conversion (view-local <-> CG global top-left)

    private func localToCG(_ local: CGRect) -> CGRect {
        guard let v = view, let w = window else { return local }
        let inWindow = v.convert(local, to: nil)
        let screen = w.convertToScreen(inWindow)
        return Geometry.cgRect(fromAppKit: screen)
    }

    private func cgToLocal(_ cg: CGRect) -> CGRect {
        guard let v = view, let w = window else { return cg }
        let screen = Geometry.cgRect(fromAppKit: cg)   // flip is its own inverse -> AppKit global
        let inWindow = w.convertFromScreen(screen)
        return v.convert(inWindow, from: nil)
    }

    /// Union of every screen's frame in AppKit (bottom-left) global coordinates.
    private static func unionScreenFrame() -> CGRect {
        let screens = NSScreen.screens
        guard let first = screens.first else { return .zero }
        return screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }
}
