import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A keyboard shortcut: a key code plus Carbon modifier flags, and how to show it.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// Builds one from a key press, if it has at least one of ⌘ ⌥ ⌃ — a bare key would
    /// steal ordinary typing from every app. F-keys may stand alone.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty || Self.isFunctionKey(Int(event.keyCode)) else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbon(flags)
        display = Self.symbols(flags) + Self.name(for: event)
    }

    /// Builds one from a key code and Carbon modifiers (ShortcutsLens's Change Shortcut), named
    /// the way a key press would be in the current keyboard layout. Nil without ⌘ ⌥ or ⌃,
    /// unless it's an F-key.
    init?(keyCode: Int, carbonModifiers: Int) {
        let mods = UInt32(carbonModifiers) & UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard (0...127).contains(keyCode), mods & UInt32(controlKey | optionKey | cmdKey) != 0 || Self.isFunctionKey(keyCode) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if mods & UInt32(controlKey) != 0 { flags.insert(.control) }
        if mods & UInt32(optionKey) != 0 { flags.insert(.option) }
        if mods & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if mods & UInt32(cmdKey) != 0 { flags.insert(.command) }
        self.keyCode = UInt32(keyCode)
        modifiers = mods
        display = Self.symbols(flags) + Self.name(keyCode: keyCode, characters: Self.layoutCharacter(keyCode))
    }

    /// Whether a key press is this shortcut.
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        UInt32(keyCode) == self.keyCode
            && Self.carbon(flags.intersection([.command, .option, .control, .shift])) == modifiers
    }

    /// For showing the shortcut beside a menu item.
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        let key = display.drop(while: { "⌃⌥⇧⌘".contains($0) }).lowercased()
        return (key.count == 1 ? key : "", mask)
    }

    /// F1–F20 may stand alone: no app types with them.
    static func isFunctionKey(_ code: Int) -> Bool { fKeys[code] != nil }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private static func name(for event: NSEvent) -> String {
        name(keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers)
    }

    static func name(keyCode code: Int, characters: String?) -> String {
        if let f = fKeys[code] { return "F\(f)" }
        switch code {
        case kVK_Return: return "↩"
        case kVK_Space: return "Space"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return (characters ?? "?").uppercased()
        }
    }

    /// What the key types with no modifiers in the current layout ("c" for kVK_ANSI_C on QWERTY).
    static func layoutCharacter(_ keyCode: Int, shift: Bool = false) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), shift ? UInt32(shiftKey >> 8) & 0xFF : 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// Key code → F-key number. A table, not a range: the codes are scattered (F1 is 122,
    /// F20 is 90).
    static let fKeys: [Int: Int] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { ($1, $0 + 1) })
    }()
}

/// System-wide shortcuts through Carbon's RegisterEventHotKey: works from a menu bar app
/// and needs no permission.
@MainActor
final class HotKeyCenter {
    enum Action: UInt32, CaseIterable {
        case spotlight = 1
        case clicks = 2
        case keystrokes = 3
        case box = 4
        case arrow = 5

        @MainActor var hotKey: HotKey? {
            let prefs = Preferences.shared
            switch self {
            case .spotlight: return prefs.spotlightHotKey
            case .clicks: return prefs.clicksHotKey
            case .keystrokes: return prefs.keystrokesHotKey
            case .box: return prefs.boxHotKey
            case .arrow: return prefs.arrowHotKey
            }
        }

        /// As the menu bar menu names it.
        var title: String {
            switch self {
            case .spotlight: return "Spotlight"
            case .clicks: return "Click Rings"
            case .keystrokes: return "Keystrokes"
            case .box: return "Draw Box"
            case .arrow: return "Draw Arrow"
            }
        }
    }

    static let shared = HotKeyCenter()
    var perform: ((Action) -> Void)?
    /// Bare Esc, caught only while `catchesEscape` is on.
    var onEscape: (() -> Void)?
    private var refs: [Action: EventHotKeyRef] = [:]
    private var escapeRef: EventHotKeyRef?
    private var installed = false
    private static let escapeID: UInt32 = 99

    /// Takes Esc for ClickLens while marks wait for it. Registered as a hot key, it needs
    /// no Accessibility permission, and the app in front never sees the Esc (so a Keynote
    /// slideshow stays up). Every other time Esc is left alone.
    var catchesEscape = false {
        didSet { if catchesEscape != oldValue { updateEscape() } }
    }

    /// Registers the shortcuts in Preferences, replacing earlier registrations.
    func apply() {
        #if DEBUG
        // A test copy (APP_STORE) never takes the installed app's keys or its ShortcutsLens report.
        if AgentSocket.isTestRun { return }
        #endif
        installHandlerOnce()
        unregisterAll()
        updateEscape()
        for action in Action.allCases {
            guard let key = action.hotKey else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x434C_4E53), id: action.rawValue) // "CLNS"
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                NSLog("ClickLens: shortcut \(key.display) for \(action) not registered (\(status)), probably taken by another app")
            }
        }
        ShortcutsLensReport.publish()
    }

    /// For ShortcutsLens: the shortcuts that registered. Esc is left out: it's held only
    /// while marks wait for it.
    var reportedShortcuts: [ShortcutsLensReport.Shortcut] {
        Action.allCases.compactMap { action in
            guard refs[action] != nil, let key = action.hotKey else { return nil }
            return .init(id: "\(action)", title: action.title, keyCode: Int(key.keyCode), carbonModifiers: Int(key.modifiers))
        }
    }

    /// ShortcutsLens's Change Shortcut: saves the keys as the Settings shortcut editor does (so Settings
    /// shows them and sync carries them) and registers again. Nil when done, or why not.
    func change(id: String, keyCode: Int, carbonModifiers: Int) -> String? {
        guard let action = Action.allCases.first(where: { "\($0)" == id }) else { return "ClickLens has no shortcut called \(id)." }
        guard let key = HotKey(keyCode: keyCode, carbonModifiers: carbonModifiers) else {
            return "ClickLens shortcuts need ⌘, ⌥ or ⌃ (F-keys may stand alone)."
        }
        if let other = Action.allCases.first(where: { $0 != action && $0.hotKey?.keyCode == key.keyCode && $0.hotKey?.modifiers == key.modifiers }) {
            return "ClickLens already uses \(key.display) for \(other.title)."
        }
        let previous = action.hotKey
        save(key, for: action)
        apply()
        guard refs[action] == nil else { return nil }
        // Taken by another app: keep the old keys rather than leave the shortcut dead.
        save(previous, for: action)
        apply()
        return "\(key.display) is taken by another app, so ClickLens kept \(previous?.display ?? "no shortcut")."
    }

    /// Writes the same settings the Settings shortcut editor does.
    func save(_ key: HotKey?, for action: Action) {
        let prefs = Preferences.shared
        switch action {
        case .spotlight: prefs.spotlightHotKey = key
        case .clicks: prefs.clicksHotKey = key
        case .keystrokes: prefs.keystrokesHotKey = key
        case .box: prefs.boxHotKey = key
        case .arrow: prefs.arrowHotKey = key
        }
    }

    /// The other shortcuts that use these keys.
    func others(using key: HotKey, except action: Action?) -> [Action] {
        Action.allCases.filter { $0 != action && $0.hotKey?.keyCode == key.keyCode && $0.hotKey?.modifiers == key.modifiers }
    }

    /// Whether a key press is one of ClickLens's own shortcuts.
    func isOwnHotKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        Action.allCases.contains { $0.hotKey?.matches(keyCode: keyCode, flags: flags) == true }
    }

    /// While a shortcut is being recorded, the current ones must not fire.
    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        // The shortcut editor uses Esc to cancel.
        if let escapeRef { UnregisterEventHotKey(escapeRef) }
        escapeRef = nil
    }

    private func updateEscape() {
        installHandlerOnce()
        if catchesEscape, escapeRef == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x434C_4E53), id: Self.escapeID)
            let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr { escapeRef = ref } else { NSLog("ClickLens: Esc not registered (\(status))") }
        } else if !catchesEscape, let escapeRef {
            UnregisterEventHotKey(escapeRef)
            self.escapeRef = nil
        }
    }

    private func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }

    fileprivate func fire(_ id: UInt32) {
        if id == Self.escapeID { onEscape?(); return }
        guard let action = Action(rawValue: id) else { return }
        perform?(action)
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let value = id.id
    // Carbon delivers hot keys on the main thread's event loop.
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(value) }
    return noErr
}
