#if DEBUG
import AppKit
import Carbon.HIToolbox

/// `CLICKLENS_DEBUG_SHORTCUT_EDITOR=<png path>` on an agent CLI test copy (APP_STORE, so its own
/// settings): opens the Spotlight shortcut's editor in a hidden Settings window, checks typing "+"
/// (⇧ + "="), a bare letter, an F-key alone, then presses Click Rings' keys there and sets them, so
/// they move. Saves a picture of the editor to the path and the results to <path>.txt, puts the
/// test copy's shortcuts back to their defaults, and quits.
@MainActor
enum DebugShortcutEditorTest {
    static func run(shot: String) {
        Task { @MainActor in
            let result = await test(shot: shot)
            try? result.write(toFile: shot + ".txt", atomically: true, encoding: .utf8)
            let prefs = Preferences.shared
            prefs.spotlightHotKey = Preferences.Defaults.spotlightHotKey
            prefs.clicksHotKey = Preferences.Defaults.clicksHotKey
            QuitConfirmation.quitNow()
        }
    }

    private static func recorders(in view: NSView) -> [ShortcutRecorder.RecorderButton] {
        ((view as? ShortcutRecorder.RecorderButton).map { [$0] } ?? []) + view.subviews.flatMap(recorders)
    }

    private static func press(_ key: HotKey, into model: ShortcutEditorModel, window: NSWindow) {
        var flags: NSEvent.ModifierFlags = []
        if key.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if key.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if key.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if key.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(key.keyCode)) {
            _ = model.handle(event)
        }
    }

    private static func test(shot: String) async -> String {
        let prefs = Preferences.shared
        var out: [String] = []
        out.append("start: spotlight \(prefs.spotlightHotKey?.display ?? "none"), clicks \(prefs.clicksHotKey?.display ?? "none")")
        SettingsWindow.shared.debugShowHidden(tab: "Spotlight")
        try? await Task.sleep(for: .milliseconds(600))
        guard let window = SettingsWindow.shared.debugWindow, let content = window.contentView,
              let button = recorders(in: content).first(where: { $0.action_ == .spotlight })
        else { return "no Spotlight shortcut box in Settings" }
        button.performClick(nil)
        try? await Task.sleep(for: .milliseconds(400))
        guard let model = button.debugModel else { return "editor did not open" }
        out.append("open: \(button.debugPopoverShown) title \(button.debugTitle), combo \(model.combo?.display ?? "-")")

        model.typed("+")
        out.append("plus→key \(model.keyText) shift \(model.shift) combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
        model.control = false; model.option = false; model.shift = false; model.command = false
        model.typed("k")
        out.append("bare k: combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
        model.choose(Int(kVK_F6))
        model.typed(model.keyText)  // the key field echoing the menu's choice
        out.append("F6 alone: key \(model.keyText) combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
        model.choose(Int(kVK_Space))
        model.typed(model.keyText)
        out.append("Space from menu: key \(model.keyText) code \(model.keyCode.map(String.init) ?? "-")")
        model.choose(Int(kVK_F6))
        model.command = true
        model.typed("q")
        out.append("⌘Q system: \(model.systemUse ?? "-")")

        guard let clicks = prefs.clicksHotKey else { return out.joined(separator: "\n") + "\nno Click Rings key" }
        press(clicks, into: model, window: window)
        out.append("pressed \(model.combo?.display ?? "-") moves from \(model.movesFrom)")
        try? await Task.sleep(for: .milliseconds(300))
        if !shot.isEmpty, let view = button.debugPopoverView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
        }
        model.finish?(.set(model.combo))
        try? await Task.sleep(for: .milliseconds(400))
        out.append("after set: spotlight \(prefs.spotlightHotKey?.display ?? "none"), clicks \(prefs.clicksHotKey?.display ?? "none"), title \(button.debugTitle), editor open \(button.debugModel != nil) \(button.debugPopoverShown)")

        // Esc cancels without changing anything.
        button.performClick(nil)
        try? await Task.sleep(for: .milliseconds(400))
        if let model = button.debugModel {
                // Modifiers down and up with no key between: another app took the keys.
            for flags in [NSEvent.ModifierFlags([.control, .option, .command]), []] {
                if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: "",
                                                charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Command)) {
                    _ = model.handle(event)
                }
            }
            out.append("hint after modifiers alone: \(model.showHint)")
            try? await Task.sleep(for: .milliseconds(300))
            if !shot.isEmpty, let view = button.debugPopoverView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-hint.png")))
            }
            model.typed("z")
            press(HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, display: "⎋"), into: model, window: window)
            try? await Task.sleep(for: .milliseconds(400))
            out.append("after Esc: spotlight \(prefs.spotlightHotKey?.display ?? "none"), editor open \(button.debugModel != nil), title \(button.debugTitle)")
        }

        // Clear.
        button.performClick(nil)
        try? await Task.sleep(for: .milliseconds(400))
        guard let again = button.debugModel else { return out.joined(separator: "\n") + "\neditor did not reopen" }
        again.finish?(.set(nil))
        try? await Task.sleep(for: .milliseconds(400))
        out.append("after clear: spotlight \(prefs.spotlightHotKey?.display ?? "none"), title \(button.debugTitle)")
        return out.joined(separator: "\n")
    }
}

#endif
