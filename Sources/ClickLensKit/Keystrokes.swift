import Foundation

/// The modifier keys ClickLens shows, independent of AppKit so the formatting rules
/// can be tested on their own.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    /// The modifiers that turn a key press into a shortcut rather than typing.
    public static let shortcut: KeyModifiers = [.control, .option, .command]

    /// In the order macOS menus print them: ⌃⌥⇧⌘.
    public var symbols: String {
        var s = ""
        if contains(.function) { s += "fn " }
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// Which keystrokes appear on screen.
public enum KeystrokeFilter: String, CaseIterable, Sendable {
    /// Everything, including ordinary typing, collected into a running line.
    case all
    /// Only keys pressed together with ⌘, ⌥, ⇧ or ⌃, each shown as its own combination.
    case combos

    /// Reads a stored value, including the two filters earlier versions offered, which
    /// both showed only keys with modifiers.
    public init(stored: String?) {
        switch stored {
        case "all": self = .all
        case "combos", "withModifiers", "shortcutsOnly": self = .combos
        default: self = .all
        }
    }

    public var title: String {
        switch self {
        case .all: "Everything you type"
        case .combos: "Key combinations only"
        }
    }

    public var detail: String {
        switch self {
        case .all: "Every key appears, with typing collected into one line."
        case .combos: "Only keys pressed with ⌘ ⌥ ⇧ or ⌃ appear, such as ⌘C or ⇧⌘K. Ordinary typing stays private."
        }
    }

    /// The modifiers that make a key press a combination.
    public static let comboModifiers: KeyModifiers = [.control, .option, .shift, .command]

    public func shows(_ modifiers: KeyModifiers) -> Bool {
        switch self {
        case .all: return true
        case .combos: return !modifiers.intersection(Self.comboModifiers).isEmpty
        }
    }
}

/// Turns a key press into the glyphs shown on screen.
public enum KeyNames {
    // Virtual key codes from Carbon's Events.h, spelled out so this target needs no Carbon.
    static let special: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 114: "Help",
        57: "⇪",
    ]
    static let functionKeys: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    /// Whether the key has a name of its own (Return, arrows, F-keys) rather than
    /// a character.
    public static func isSpecial(_ keyCode: UInt16) -> Bool {
        special[keyCode] != nil || functionKeys[keyCode] != nil
    }

    /// - Parameters:
    ///   - characters: what the key types with no modifiers but Shift
    ///     (`NSEvent.charactersIgnoringModifiers`).
    public static func name(keyCode: UInt16, characters: String?) -> String {
        if let glyph = special[keyCode] { return glyph }
        if let f = functionKeys[keyCode] { return "F\(f)" }
        guard let characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return "?" }
        return characters.uppercased()
    }
}

/// One key press as ClickLens sees it.
public struct Keystroke: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// What the key types with no modifiers but Shift.
    public var charactersIgnoringModifiers: String?
    /// What the key actually typed.
    public var characters: String?

    public init(keyCode: UInt16, modifiers: KeyModifiers, charactersIgnoringModifiers: String?, characters: String?) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.characters = characters
    }

    /// Typing rather than a shortcut: no ⌘ ⌃ ⌥ held.
    public var isTyping: Bool { modifiers.intersection(.shortcut).isEmpty }

    /// How it reads on its own: "⌘⇧K", "↩", "F5".
    public var label: String {
        modifiers.symbols + KeyNames.name(keyCode: keyCode, characters: charactersIgnoringModifiers)
    }

    /// How it reads inside a run of typing: the character itself ("A", "!", " "),
    /// or the key's glyph for keys that type nothing visible.
    public var typedText: String {
        if keyCode == 49 { return "␣" }
        if KeyNames.isSpecial(keyCode) { return KeyNames.name(keyCode: keyCode, characters: nil) }
        if let characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return characters
        }
        return label
    }
}

/// The line of keystrokes on screen. Consecutive typing collects into one run, the way
/// it reads; each shortcut stands on its own.
public struct KeystrokeLine: Equatable, Sendable {
    public private(set) var entries: [String] = []
    private var lastWasTyping = false

    /// The longest line shown; older characters scroll off the front.
    public var maxLength: Int

    public init(maxLength: Int = 36) {
        self.maxLength = maxLength
    }

    public var text: String { entries.joined(separator: "  ") }
    public var isEmpty: Bool { entries.isEmpty }

    /// - Parameter asCombo: show the key with all its modifiers, Shift included, as its
    ///   own entry, rather than letting it join a run of typing.
    public mutating func add(_ stroke: Keystroke, asCombo: Bool = false) {
        if asCombo {
            entries.append(stroke.label)
            lastWasTyping = false
        } else if stroke.isTyping {
            if lastWasTyping, let last = entries.last {
                entries[entries.count - 1] = last + stroke.typedText
            } else {
                entries.append(stroke.typedText)
            }
            lastWasTyping = true
        } else {
            entries.append(stroke.label)
            lastWasTyping = false
        }
        trim()
    }

    public mutating func clear() {
        entries.removeAll()
        lastWasTyping = false
    }

    private mutating func trim() {
        while text.count > maxLength {
            if entries.count > 1 {
                entries.removeFirst()
            } else if var only = entries.first {
                only.removeFirst(only.count - maxLength + 1)
                entries[0] = "…" + only
                break
            }
        }
    }
}
