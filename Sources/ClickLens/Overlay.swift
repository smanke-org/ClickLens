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

/// Draws the spotlight and click rings on every screen.
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
        var ringLayers: [UUID: CAShapeLayer] = [:]

        init(screen: NSScreen) {
            self.screen = screen
            panel = OverlayPanel(screen: screen)
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
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
            for layer in [dim, edge, rings] as [CALayer] {
                layer.actions = OverlayController.noAnimations
                root.addSublayer(layer)
            }
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

    // MARK: - Drawing

    @objc private func screensChanged() {
        rebuild()
    }

    private func rebuild() {
        for overlay in overlays { overlay.panel.orderOut(nil) }
        displayLink?.invalidate()
        displayLink = nil
        overlays = NSScreen.screens.map(ScreenOverlay.init)
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

        let active = spotlightLevel > 0 || spotlightTarget > 0 || !rings.isEmpty
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

        // The soft edge: a radial fade inside the circle, from clear to the dim colour
        // at the rim, so it meets the dimmed area without a seam.
        let softness = min(max(prefs.spotlightSoftness, 0), 0.95)
        overlay.edge.isHidden = softness <= 0
        overlay.edge.frame = circle
        overlay.edge.cornerRadius = r
        overlay.edge.colors = [color.with(alpha: 0).cgColor, color.with(alpha: 0).cgColor, color.cgColor]
        overlay.edge.locations = [0, NSNumber(value: 1 - softness), 1]
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
