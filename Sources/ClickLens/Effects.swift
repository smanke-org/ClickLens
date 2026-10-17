import AppKit
import ClickLensKit
import Observation

/// Which effects are on, and the wiring from input to drawing.
@Observable
@MainActor
final class Effects {
    static let shared = Effects()

    private(set) var spotlightOn = false
    /// Click rings switched on by themselves (rather than with the spotlight).
    private(set) var clicksOn = false
    private(set) var keystrokesOn = false
    /// The drawing tool in use, if any.
    private(set) var drawingTool: DrawTool?
    var boxOn: Bool { drawingTool == .box }
    var arrowOn: Bool { drawingTool == .arrow }

    /// Settings shows the spotlight while one of its sliders is being dragged.
    var previewingSpotlight = false { didSet { updateSpotlight() } }
    /// Settings shows click rings while its Clicks tab is open.
    var previewingClicks = false

    /// Called whenever an effect switches, for the menu bar icon.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var autoOffTask: Task<Void, Never>?
    private let prefs = Preferences.shared

    var ringsVisible: Bool {
        clicksOn || previewingClicks || (prefs.clicksWithSpotlight && spotlightOn)
    }

    /// When an effect was last on, so an automatic update can wait a while after a talk.
    @ObservationIgnored private(set) var lastActive = Date.distantPast

    var anyOn: Bool { spotlightOn || clicksOn || keystrokesOn || drawingTool != nil }

    func start() {
        OverlayController.shared.start()
        OverlayController.shared.onMarkFinished = { [weak self] in
            // One mark per shortcut press unless the user asked to keep drawing, so the
            // mouse goes straight back to their apps.
            guard let self, let tool = self.drawingTool, !self.keepDrawing(tool) else { return }
            self.setDrawing(nil, announce: false)
        }
        OverlayController.shared.onWaitingForEscapeChanged = { [weak self] _ in self?.updateEscapeKey() }
        HotKeyCenter.shared.onEscape = { [weak self] in self?.escapePressed() }
        let input = InputMonitor.shared
        input.onMouseDown = { [weak self] button, count, location in
            // Drawing is not a click to show.
            guard let self, self.ringsVisible, self.drawingTool == nil else { return }
            OverlayController.shared.mouseDown(button: button, clickCount: count, at: location)
            if self.prefs.clickSound { ClickSounds.shared.play(down: true) }
        }
        input.onMouseUp = { [weak self] button in
            guard let self else { return }
            OverlayController.shared.mouseUp(button: button)
            if self.ringsVisible, self.prefs.clickSound { ClickSounds.shared.play(down: false) }
        }
        input.onKey = { [weak self] stroke, flags in
            guard let self else { return }
            // Esc ends drawing, then clears marks waiting for it. This path needs
            // Accessibility; it is the fallback for when the Esc hot key can't be registered.
            if stroke.keyCode == 53, stroke.modifiers.isEmpty,
               self.drawingTool != nil || OverlayController.shared.waitingForEscape {
                self.escapePressed()
                return
            }
            guard self.keystrokesOn else { return }
            if self.prefs.ignoreOwnHotKeys, HotKeyCenter.shared.isOwnHotKey(keyCode: stroke.keyCode, flags: flags) { return }
            KeystrokeDisplay.shared.add(stroke)
        }
        input.onModifiers = { [weak self] modifiers in
            guard let self, self.keystrokesOn else { return }
            KeystrokeDisplay.shared.modifiersChanged(modifiers)
        }
        input.start()

        HotKeyCenter.shared.perform = { [weak self] action in
            guard let self else { return }
            // Carbon swallows the shortcut, so the keystroke display never sees it; show
            // it here when the user wants ClickLens's own shortcuts on screen too.
            if self.keystrokesOn, !self.prefs.ignoreOwnHotKeys, let key = action.hotKey {
                KeystrokeDisplay.shared.add(Self.keystroke(for: key))
            }
            switch action {
            case .spotlight: self.toggleSpotlight()
            case .clicks: self.toggleClicks()
            case .keystrokes: self.toggleKeystrokes()
            case .box: self.toggleBox()
            case .arrow: self.toggleArrow()
            }
        }
        HotKeyCenter.shared.apply()
    }

    // MARK: - Toggles

    func toggleSpotlight() { setSpotlight(!spotlightOn) }

    func setSpotlight(_ on: Bool) {
        spotlightOn = on
        updateSpotlight()
        autoOffTask?.cancel()
        if on, prefs.spotlightAutoOff {
            let seconds = prefs.spotlightAutoOffSeconds
            autoOffTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, self.spotlightOn else { return }
                self.setSpotlight(false)
            }
        }
        if !ringsVisible { OverlayController.shared.releaseAllRings() }
        ToggleAnnouncer.shared.announce(on ? "Spotlight On" : "Spotlight Off", symbol: on ? "circle.dashed.inset.filled" : "circle.dashed")
        noteActivity(); onChange?()
    }

    func toggleClicks() {
        clicksOn.toggle()
        if !ringsVisible { OverlayController.shared.releaseAllRings() }
        ToggleAnnouncer.shared.announce(clicksOn ? "Click Rings On" : "Click Rings Off", symbol: "cursorarrow.click.2")
        noteActivity(); onChange?()
    }

    func toggleKeystrokes() {
        keystrokesOn.toggle()
        if !keystrokesOn { KeystrokeDisplay.shared.clear() }
        if keystrokesOn, !InputMonitor.shared.isTrusted { InputMonitor.shared.requestTrust() }
        ToggleAnnouncer.shared.announce(keystrokesOn ? "Keystrokes On" : "Keystrokes Off", symbol: "keyboard")
        noteActivity(); onChange?()
    }

    func toggleBox() { setDrawing(boxOn ? nil : .box) }
    func toggleArrow() { setDrawing(arrowOn ? nil : .arrow) }

    private func keepDrawing(_ tool: DrawTool) -> Bool {
        tool == .box ? prefs.boxKeepDrawing : prefs.arrowKeepDrawing
    }

    /// While drawing, Esc stops drawing; otherwise it fades the marks waiting for it.
    private func escapePressed() {
        if drawingTool != nil {
            setDrawing(nil)
        } else {
            OverlayController.shared.fadeMarksOnEscape()
        }
    }

    /// Catch Esc only while something on screen uses it.
    private func updateEscapeKey() {
        HotKeyCenter.shared.catchesEscape = drawingTool != nil || OverlayController.shared.waitingForEscape
    }

    /// Starts drawing with `tool`, switches tools, or (with nil) ends drawing.
    func setDrawing(_ tool: DrawTool?, announce: Bool = true) {
        let previous = drawingTool
        guard tool != previous else { return }
        if previous == nil {
            appBeforeDrawing = NSWorkspace.shared.frontmostApplication
        }
        drawingTool = tool
        OverlayController.shared.setDrawing(tool)
        updateEscapeKey()
        if tool == nil, let app = appBeforeDrawing, app != NSRunningApplication.current {
            // Hand the keyboard back to the app that was in front before drawing began.
            app.activate()
        }
        if announce {
            switch tool {
            case .box:
                ToggleAnnouncer.shared.announce(prefs.boxKeepDrawing ? "Drag to Draw Boxes · Esc to Finish" : "Drag to Draw a Box",
                                                symbol: "rectangle.dashed")
            case .arrow:
                let start = prefs.arrowClickIsTip ? "Click What to Point At, Then Drag" : "Drag to Draw an Arrow"
                ToggleAnnouncer.shared.announce(prefs.arrowKeepDrawing ? start + " · Esc to Finish" : start, symbol: "arrow.up.right")
            case nil:
                ToggleAnnouncer.shared.announce("Drawing Off", symbol: previous == .arrow ? "arrow.up.right" : "rectangle.dashed")
            }
        }
        noteActivity(); onChange?()
    }

    @ObservationIgnored private var appBeforeDrawing: NSRunningApplication?

    /// Any switch, on or off, means effects were just in use.
    private func noteActivity() { lastActive = Date() }

    private func updateSpotlight() {
        OverlayController.shared.setSpotlight(spotlightOn || previewingSpotlight)
    }

    private static func keystroke(for key: HotKey) -> Keystroke {
        var modifiers: KeyModifiers = []
        let flags = key.menuKeyEquivalent.mask
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let name = String(key.display.drop(while: { "⌃⌥⇧⌘".contains($0) }))
        return Keystroke(keyCode: UInt16(key.keyCode), modifiers: modifiers,
                         charactersIgnoringModifiers: name.lowercased(), characters: name)
    }
}
