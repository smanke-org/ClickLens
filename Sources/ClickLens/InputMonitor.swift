import AppKit
import ApplicationServices
import ClickLensKit

/// Watches clicks and keystrokes system-wide through AppKit's global event monitors.
///
/// Mouse events arrive without any permission, but **key events only arrive if the app
/// is trusted for Accessibility**, and when it isn't they are simply never delivered,
/// with no error. Trust is therefore tracked here and shown in the menu and Settings,
/// and the monitors are registered again when it changes, because a monitor registered
/// before trust was granted does not start receiving key events by itself.
@MainActor
final class InputMonitor {
    static let shared = InputMonitor()
    static let trustDidChange = Notification.Name("InputMonitor.trustDidChange")

    var onMouseDown: ((_ button: Int, _ clickCount: Int, _ location: CGPoint) -> Void)?
    var onMouseUp: ((_ button: Int) -> Void)?
    var onKey: ((Keystroke, NSEvent.ModifierFlags) -> Void)?
    var onModifiers: ((KeyModifiers) -> Void)?

    private(set) var isTrusted = AXIsProcessTrusted()
    private var monitors: [Any] = []
    private var trustTimer: Timer?

    func start() {
        register()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { InputMonitor.shared.checkTrust() }
        }
    }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        NSLog("ClickLens: Accessibility trust is now \(trusted); re-registering monitors")
        unregister()
        register()
        NotificationCenter.default.post(name: Self.trustDidChange, object: nil)
    }

    private func register() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                           .otherMouseDown, .otherMouseUp, .keyDown, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { InputMonitor.shared.handle(event) }
        }) {
            monitors.append(global)
        }
        // Events aimed at ClickLens's own windows (Settings) skip the global monitor.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { InputMonitor.shared.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func unregister() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onMouseDown?(event.buttonNumber, event.clickCount, NSEvent.mouseLocation)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            onMouseUp?(event.buttonNumber)
        case .keyDown:
            guard !event.isARepeat || KeyNames.isSpecial(event.keyCode) else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let stroke = Keystroke(keyCode: event.keyCode, modifiers: Self.modifiers(flags),
                                   charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                   characters: event.characters)
            onKey?(stroke, flags)
        case .flagsChanged:
            onModifiers?(Self.modifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
        default:
            break
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        // Arrow and F-keys carry the function flag on every press; only count it for
        // keys where it was really held, which the caller cannot tell, so leave it out.
        return m
    }
}

/// Click sounds, synthesized once at launch.
@MainActor
final class ClickSounds {
    static let shared = ClickSounds()
    private let down = NSSound(data: ClickSoundSynth.wav(frequency: 1500))
    private let up = NSSound(data: ClickSoundSynth.wav(frequency: 2300, duration: 0.035))

    func play(down isDown: Bool) {
        guard let sound = isDown ? down : up else { return }
        sound.volume = Float(Preferences.shared.clickVolume)
        sound.stop()
        sound.play()
    }
}
