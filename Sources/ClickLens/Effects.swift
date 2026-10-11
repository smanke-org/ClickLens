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

    var anyOn: Bool { spotlightOn || clicksOn || keystrokesOn }

    func start() {
        OverlayController.shared.start()
        let input = InputMonitor.shared
        input.onMouseDown = { [weak self] button, count, location in
            guard let self, self.ringsVisible else { return }
            OverlayController.shared.mouseDown(button: button, clickCount: count, at: location)
            if self.prefs.clickSound { ClickSounds.shared.play(down: true) }
        }
        input.onMouseUp = { [weak self] button in
            guard let self else { return }
            OverlayController.shared.mouseUp(button: button)
            if self.ringsVisible, self.prefs.clickSound { ClickSounds.shared.play(down: false) }
        }
        input.onKey = { [weak self] stroke, flags in
            guard let self, self.keystrokesOn else { return }
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
        onChange?()
    }

    func toggleClicks() {
        clicksOn.toggle()
        if !ringsVisible { OverlayController.shared.releaseAllRings() }
        ToggleAnnouncer.shared.announce(clicksOn ? "Click Rings On" : "Click Rings Off", symbol: "cursorarrow.click.2")
        onChange?()
    }

    func toggleKeystrokes() {
        keystrokesOn.toggle()
        if !keystrokesOn { KeystrokeDisplay.shared.clear() }
        if keystrokesOn, !InputMonitor.shared.isTrusted { InputMonitor.shared.requestTrust() }
        ToggleAnnouncer.shared.announce(keystrokesOn ? "Keystrokes On" : "Keystrokes Off", symbol: "keyboard")
        onChange?()
    }

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
