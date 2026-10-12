import AppKit
import ClickLensKit
import QuartzCore

/// A borderless, see-through panel covering one screen. Clicks pass straight through it,
/// it never takes focus, and it sits above full-screen apps and the menu bar so the
/// effects show during a Keynote or PowerPoint presentation too.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The overlay's content view. It ignores the mouse except in box-drawing mode, when
/// the panel stops passing clicks through and drags here draw a box.
final class OverlayView: NSView {
    var onDrag: ((_ phase: NSEvent.EventType) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // activeAlways: ClickLens is never the active app while you draw over another one.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .cursorUpdate, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseDown(with event: NSEvent) { NSCursor.crosshair.set(); onDrag?(.leftMouseDown) }
    override func mouseDragged(with event: NSEvent) { onDrag?(.leftMouseDragged) }
    override func mouseUp(with event: NSEvent) { onDrag?(.leftMouseUp) }
}

/// The drawing tools: a box (keyline) or an arrow.
enum DrawTool { case box, arrow }

/// Draws the spotlight, click rings, boxes and arrows on every screen.
@MainActor
final class OverlayController: NSObject {
    static let shared = OverlayController()

    /// One overlay per screen, with its spotlight layers.
    @MainActor private final class ScreenOverlay {
        let screen: NSScreen
        let panel: OverlayPanel
        let dim = CAShapeLayer()
        let edge = CAGradientLayer()
        let rings = CALayer()
        let boxes = CALayer()
        var ringLayers: [UUID: CAShapeLayer] = [:]
        var boxLayers: [UUID: CAShapeLayer] = [:]

        init(screen: NSScreen) {
            self.screen = screen
            panel = OverlayPanel(screen: screen)
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            panel.contentView = view
            let root = view.layer!
            dim.fillRule = .evenOdd
            dim.frame = root.bounds
            edge.type = .radial
            edge.startPoint = CGPoint(x: 0.5, y: 0.5)
            edge.endPoint = CGPoint(x: 1, y: 1)
            edge.masksToBounds = true
            rings.frame = root.bounds
            boxes.frame = root.bounds
            for layer in [dim, edge, boxes, rings] as [CALayer] {
                layer.actions = OverlayController.noAnimations
                root.addSublayer(layer)
            }
        }
    }

    /// A box or arrow drawn on screen. Its look is fixed when it is drawn, so changing
    /// settings later leaves marks already on screen alone.
    private struct Mark {
        let id = UUID()
        let tool: DrawTool
        /// Where the drag began and where it is now (or ended).
        let start: CGPoint
        var end: CGPoint
        let color: RGBA
        let thickness: Double
        let fadeAfter: Double
        let shape: ArrowShape
        let clickIsTip: Bool
        /// When the drag ended; the mark fades once `fadeAfter` has passed.
        var finished: CFTimeInterval?

        var rect: CGRect {
            CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                   width: abs(end.x - start.x), height: abs(end.y - start.y))
        }

        var length: Double { hypot(end.x - start.x, end.y - start.y) }

        /// Big enough to keep: a click without a drag draws nothing.
        var isDrawn: Bool {
            tool == .box ? rect.width >= 4 && rect.height >= 4 : length >= 10
        }

        /// The area it covers, with room for a line's width and an arrowhead.
        var bounds: CGRect {
            rect.insetBy(dx: -(thickness * 4 + 30), dy: -(thickness * 4 + 30))
        }
    }

    private struct Ring {
        let id = UUID()
        var location: CGPoint
        let color: RGBA
        let count: Int
        var released: CFTimeInterval?
    }

    static let noAnimations: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(), "opacity": NSNull(), "fillColor": NSNull(),
        "strokeColor": NSNull(), "colors": NSNull(), "locations": NSNull(), "frame": NSNull(),
        "cornerRadius": NSNull(), "hidden": NSNull(), "sublayers": NSNull(), "contents": NSNull(),
    ]

    private var overlays: [ScreenOverlay] = []
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var visible = false

    /// 0 = off, 1 = fully on; eased between by `spotlightTarget`.
    private var spotlightLevel = 0.0
    private var spotlightTarget = 0.0
    private var rings: [Ring] = []
    private var marks: [Mark] = []
    private var drawingMark: UUID?
    /// The drawing tool in use: the overlays take the mouse instead of passing it through.
    private(set) var tool: DrawTool?
    private var drawing: Bool { tool != nil }
    /// Called when a drag ends, so drawing mode can end after one mark.
    var onMarkFinished: (() -> Void)?
    /// How long a finished mark fades out over.
    private static let markFadeDuration = 0.4
    /// Ring for each held button, so it follows the pointer until release.
    private var heldRings: [Int: UUID] = [:]

    private let prefs = Preferences.shared

    func start() {
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Spotlight

    var spotlightIsOn: Bool { spotlightTarget > 0 }

    func setSpotlight(_ on: Bool) {
        spotlightTarget = on ? 1 : 0
        if !prefs.spotlightAnimates { spotlightLevel = spotlightTarget }
        wake()
    }

    // MARK: - Clicks

    /// - Parameters:
    ///   - button: 0 left, 1 right, 2+ other.
    func mouseDown(button: Int, clickCount: Int, at location: CGPoint) {
        let color = switch button {
        case 0: prefs.leftClickColor
        case 1: prefs.rightClickColor
        default: prefs.otherClickColor
        }
        // A double click replaces the single click's ring with a double one.
        if let previous = heldRings[button] { release(previous) }
        let ring = Ring(location: location, color: color, count: min(max(clickCount, 1), 3))
        rings.append(ring)
        heldRings[button] = ring.id
        wake()
    }

    func mouseUp(button: Int) {
        guard let id = heldRings.removeValue(forKey: button) else { return }
        release(id)
    }

    /// Lets go of every held ring, for when rings are switched off mid-click.
    func releaseAllRings() {
        for id in heldRings.values { release(id) }
        heldRings.removeAll()
    }

    private func release(_ id: UUID) {
        guard let i = rings.firstIndex(where: { $0.id == id }), rings[i].released == nil else { return }
        rings[i].released = CACurrentMediaTime()
        wake()
    }

    // MARK: - Boxes and arrows

    func setDrawing(_ tool: DrawTool?) {
        if self.tool != nil, tool == nil, let id = drawingMark { finishMark(id) }
        self.tool = tool
        for overlay in overlays { overlay.panel.ignoresMouseEvents = tool == nil }
        if tool != nil {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
        wake()
    }

    /// A box or arrow in the middle of the screen with the pointer, to judge the settings by.
    func showSample(_ tool: DrawTool) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.screens[0]
        let f = screen.frame
        var mark: Mark
        switch tool {
        case .box:
            let size = CGSize(width: f.width * 0.3, height: f.height * 0.2)
            let origin = CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
            mark = newMark(.box, at: origin)
            mark.end = CGPoint(x: origin.x + size.width, y: origin.y + size.height)
        case .arrow:
            // Drawn as if dragged, so the "click marks the tip" setting shows too.
            let a = CGPoint(x: f.midX - f.width * 0.15, y: f.midY - f.height * 0.1)
            let b = CGPoint(x: f.midX + f.width * 0.1, y: f.midY + f.height * 0.08)
            mark = newMark(.arrow, at: prefs.arrowClickIsTip ? b : a)
            mark.end = prefs.arrowClickIsTip ? a : b
        }
        mark.finished = CACurrentMediaTime()
        marks.append(mark)
        wake()
    }

    func clearMarks() {
        marks.removeAll()
        drawingMark = nil
        wake()
    }

    private func newMark(_ tool: DrawTool, at point: CGPoint) -> Mark {
        switch tool {
        case .box:
            Mark(tool: .box, start: point, end: point, color: prefs.boxColor, thickness: prefs.boxThickness,
                 fadeAfter: prefs.boxFadeAfter, shape: .classic, clickIsTip: false)
        case .arrow:
            Mark(tool: .arrow, start: point, end: point, color: prefs.arrowColor, thickness: prefs.arrowThickness,
                 fadeAfter: prefs.arrowFadeAfter, shape: prefs.arrowShape, clickIsTip: prefs.arrowClickIsTip)
        }
    }

    private func drag(_ phase: NSEvent.EventType) {
        guard let tool else { return }
        let pointer = NSEvent.mouseLocation
        switch phase {
        case .leftMouseDown:
            let mark = newMark(tool, at: pointer)
            marks.append(mark)
            drawingMark = mark.id
        case .leftMouseDragged:
            if let id = drawingMark, let i = marks.firstIndex(where: { $0.id == id }) { marks[i].end = pointer }
        default:
            if let id = drawingMark {
                if let i = marks.firstIndex(where: { $0.id == id }) { marks[i].end = pointer }
                finishMark(id)
            }
            onMarkFinished?()
        }
        wake()
    }

    private func finishMark(_ id: UUID) {
        drawingMark = nil
        guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
        if marks[i].isDrawn {
            marks[i].finished = CACurrentMediaTime()
        } else {
            marks.remove(at: i)
        }
    }

    private func opacity(_ mark: Mark, now: CFTimeInterval) -> Double {
        guard let finished = mark.finished else { return 1 }
        let fadeStart = finished + mark.fadeAfter
        guard now > fadeStart else { return 1 }
        return max(0, 1 - (now - fadeStart) / Self.markFadeDuration)
    }

    // MARK: - Drawing

    @objc private func screensChanged() {
        rebuild()
    }

    private func rebuild() {
        for overlay in overlays { overlay.panel.orderOut(nil) }
        displayLink?.invalidate()
        displayLink = nil
        overlays = NSScreen.screens.map(ScreenOverlay.init)
        for overlay in overlays {
            overlay.panel.ignoresMouseEvents = !drawing
            (overlay.panel.contentView as? OverlayView)?.onDrag = { [weak self] phase in self?.drag(phase) }
        }
        if let view = overlays.first?.panel.contentView {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link
        }
        visible = false
        wake()
    }

    /// Starts drawing; `tick` stops again once there is nothing left to show.
    private func wake() {
        lastTick = CACurrentMediaTime()
        displayLink?.isPaused = false
        draw(now: lastTick)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        if spotlightLevel != spotlightTarget {
            let duration = max(prefs.spotlightAnimationDuration, 0.01)
            let step = dt / duration
            spotlightLevel = spotlightTarget > spotlightLevel
                ? min(spotlightTarget, spotlightLevel + step)
                : max(spotlightTarget, spotlightLevel - step)
        }
        draw(now: now)
    }

    private func draw(now: CFTimeInterval) {
        let pointer = NSEvent.mouseLocation
        for id in heldRings.values {
            if let i = rings.firstIndex(where: { $0.id == id }) { rings[i].location = pointer }
        }
        rings.removeAll { ring in
            guard let released = ring.released else { return false }
            return now - released >= prefs.clickFadeDuration
        }

        marks.removeAll { opacity($0, now: now) <= 0 }

        let active = spotlightLevel > 0 || spotlightTarget > 0 || !rings.isEmpty || !marks.isEmpty || drawing
        setVisible(active)
        guard active else {
            displayLink?.isPaused = true
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for overlay in overlays {
            drawSpotlight(on: overlay, pointer: pointer)
            drawRings(on: overlay, now: now)
            drawMarks(on: overlay, now: now)
        }
        CATransaction.commit()
    }

    private func setVisible(_ show: Bool) {
        guard show != visible else { return }
        visible = show
        for overlay in overlays {
            if show { overlay.panel.orderFrontRegardless() } else { overlay.panel.orderOut(nil) }
        }
    }

    private func drawSpotlight(on overlay: ScreenOverlay, pointer: CGPoint) {
        guard spotlightLevel > 0 else {
            overlay.dim.isHidden = true
            overlay.edge.isHidden = true
            return
        }
        let size = overlay.screen.frame.size
        let diagonal = (size.width * size.width + size.height * size.height).squareRoot()
        let frame = SpotlightFrame.at(level: spotlightLevel, radius: prefs.spotlightRadius,
                                      screenDiagonal: diagonal, zoom: prefs.spotlightAnimates)
        let origin = overlay.screen.frame.origin
        let center = CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
        let r = frame.radius
        let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let color = prefs.dimColor.with(alpha: prefs.dimColor.alpha * frame.dimFraction)

        let path = CGMutablePath()
        path.addRect(overlay.dim.bounds)
        path.addEllipse(in: circle)
        overlay.dim.path = path
        overlay.dim.fillColor = color.cgColor
        overlay.dim.isHidden = false

        // The soft edge: a radial fade inside the circle, from clear to the dim color
        // at the rim, so it meets the dimmed area without a seam.
        let softness = min(max(prefs.spotlightSoftness, 0), 0.95)
        overlay.edge.isHidden = softness <= 0
        overlay.edge.frame = circle
        overlay.edge.cornerRadius = r
        overlay.edge.colors = [color.with(alpha: 0).cgColor, color.with(alpha: 0).cgColor, color.cgColor]
        overlay.edge.locations = [0, NSNumber(value: 1 - softness), 1]
    }

    private func drawMarks(on overlay: ScreenOverlay, now: CFTimeInterval) {
        let frame = overlay.screen.frame
        var live = Set<UUID>()
        for mark in marks {
            guard mark.bounds.intersects(frame) else { continue }
            live.insert(mark.id)
            let layer = overlay.boxLayers[mark.id] ?? {
                let layer = CAShapeLayer()
                layer.actions = Self.noAnimations
                layer.lineJoin = .round
                layer.lineCap = .round
                // A soft shadow keeps the line readable on both light and dark content.
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = 0.35
                layer.shadowRadius = 3
                layer.shadowOffset = .zero
                overlay.boxes.addSublayer(layer)
                overlay.boxLayers[mark.id] = layer
                return layer
            }()
            let shift = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
            let color = mark.color.cgColor
            switch mark.tool {
            case .box:
                let local = mark.rect.applying(shift)
                let corner = min(mark.thickness * 1.5, local.width / 2, local.height / 2)
                layer.path = CGPath(roundedRect: local, cornerWidth: corner, cornerHeight: corner, transform: nil)
                layer.lineWidth = mark.thickness
                layer.fillColor = nil
                layer.sublayers = nil
            case .arrow:
                let tail = (mark.clickIsTip ? mark.end : mark.start).applying(shift)
                let tip = (mark.clickIsTip ? mark.start : mark.end).applying(shift)
                let arrow = ArrowGeometry.path(from: tail, to: tip, shape: mark.shape, thickness: mark.thickness)
                layer.path = arrow.line
                layer.lineWidth = arrow.lineWidth
                layer.fillColor = nil
                let head = (layer.sublayers?.first as? CAShapeLayer) ?? {
                    let head = CAShapeLayer()
                    head.actions = Self.noAnimations
                    head.lineJoin = .round
                    layer.addSublayer(head)
                    return head
                }()
                head.path = arrow.head
                head.fillColor = color
                head.strokeColor = color
                head.lineWidth = arrow.lineWidth
            }
            layer.strokeColor = color
            layer.opacity = Float(opacity(mark, now: now))
        }
        for (id, layer) in overlay.boxLayers where !live.contains(id) {
            layer.removeFromSuperlayer()
            overlay.boxLayers[id] = nil
        }
    }

    private func drawRings(on overlay: ScreenOverlay, now: CFTimeInterval) {
        let frame = overlay.screen.frame
        var live = Set<UUID>()
        for ring in rings {
            let reach = prefs.clickRadius * 2 + 30
            guard frame.insetBy(dx: -reach, dy: -reach).contains(ring.location) else { continue }
            live.insert(ring.id)
            let layer = overlay.ringLayers[ring.id] ?? {
                let layer = CAShapeLayer()
                layer.actions = Self.noAnimations
                layer.lineWidth = 3.5
                overlay.rings.addSublayer(layer)
                overlay.ringLayers[ring.id] = layer
                return layer
            }()
            let shape = ClickRingFrame.at(sinceRelease: ring.released.map { now - $0 },
                                          radius: prefs.clickRadius, duration: prefs.clickFadeDuration,
                                          expand: prefs.clickExpands)
            let center = CGPoint(x: ring.location.x - frame.minX, y: ring.location.y - frame.minY)
            let path = CGMutablePath()
            for i in 0..<ring.count {
                let r = shape.radius + Double(i) * 8
                path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
            layer.path = path
            layer.strokeColor = ring.color.cgColor
            layer.fillColor = ring.color.with(alpha: ring.color.alpha * 0.22).cgColor
            layer.fillRule = .evenOdd
            layer.opacity = Float(shape.opacity)
        }
        for (id, layer) in overlay.ringLayers where !live.contains(id) {
            layer.removeFromSuperlayer()
            overlay.ringLayers[id] = nil
        }
    }
}
