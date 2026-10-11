import AppKit
import ClickLensKit
import Observation
import SwiftUI

/// A colour with its opacity, stored as plain numbers so it round-trips through
/// UserDefaults without archiving an NSColor.
struct RGBA: Codable, Equatable {
    var red: Double, green: Double, blue: Double, alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { nsColor.cgColor }
    func with(alpha: Double) -> RGBA { RGBA(red, green, blue, alpha) }
}

/// Every setting, persisted to UserDefaults as it changes.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()

    // MARK: Spotlight
    var spotlightRadius: Double = Defaults.spotlightRadius { didSet { save(spotlightRadius, "spotlightRadius") } }
    /// Width of the soft edge, as a fraction of the radius.
    var spotlightSoftness: Double = Defaults.spotlightSoftness { didSet { save(spotlightSoftness, "spotlightSoftness") } }
    var dimColor: RGBA = Defaults.dimColor { didSet { saveCodable(dimColor, "dimColor") } }
    var spotlightAnimates: Bool = true { didSet { save(spotlightAnimates, "spotlightAnimates") } }
    var spotlightAnimationDuration: Double = Defaults.animationDuration { didSet { save(spotlightAnimationDuration, "spotlightAnimationDuration") } }
    var spotlightAutoOff: Bool = false { didSet { save(spotlightAutoOff, "spotlightAutoOff") } }
    var spotlightAutoOffSeconds: Double = Defaults.autoOffSeconds { didSet { save(spotlightAutoOffSeconds, "spotlightAutoOffSeconds") } }
    var spotlightHotKey: HotKey? = Defaults.spotlightHotKey { didSet { saveCodable(spotlightHotKey, "spotlightHotKey") } }

    // MARK: Clicks
    /// Rings appear whenever the spotlight is on, without turning them on separately.
    var clicksWithSpotlight: Bool = true { didSet { save(clicksWithSpotlight, "clicksWithSpotlight") } }
    var clickRadius: Double = Defaults.clickRadius { didSet { save(clickRadius, "clickRadius") } }
    var clickExpands: Bool = true { didSet { save(clickExpands, "clickExpands") } }
    var clickFadeDuration: Double = Defaults.clickFadeDuration { didSet { save(clickFadeDuration, "clickFadeDuration") } }
    var leftClickColor: RGBA = Defaults.leftClickColor { didSet { saveCodable(leftClickColor, "leftClickColor") } }
    var rightClickColor: RGBA = Defaults.rightClickColor { didSet { saveCodable(rightClickColor, "rightClickColor") } }
    var otherClickColor: RGBA = Defaults.otherClickColor { didSet { saveCodable(otherClickColor, "otherClickColor") } }
    var clickSound: Bool = false { didSet { save(clickSound, "clickSound") } }
    var clickVolume: Double = Defaults.clickVolume { didSet { save(clickVolume, "clickVolume") } }
    var clicksHotKey: HotKey? = Defaults.clicksHotKey { didSet { saveCodable(clicksHotKey, "clicksHotKey") } }

    // MARK: Keystrokes
    var keystrokesHotKey: HotKey? = Defaults.keystrokesHotKey { didSet { saveCodable(keystrokesHotKey, "keystrokesHotKey") } }
    var keystrokeFilter: KeystrokeFilter = .all { didSet { save(keystrokeFilter.rawValue, "keystrokeFilter") } }
    var keystrokeFontSize: Double = Defaults.keystrokeFontSize { didSet { save(keystrokeFontSize, "keystrokeFontSize") } }
    var keystrokeBackground: RGBA = Defaults.keystrokeBackground { didSet { saveCodable(keystrokeBackground, "keystrokeBackground") } }
    var keystrokeFadeSeconds: Double = Defaults.keystrokeFadeSeconds { didSet { save(keystrokeFadeSeconds, "keystrokeFadeSeconds") } }
    /// A CGDirectDisplayID, or 0 for whichever screen the pointer is on.
    var keystrokeScreen: UInt32 = 0 { didSet { save(Int(keystrokeScreen), "keystrokeScreen") } }
    var ignoreOwnHotKeys: Bool = true { didSet { save(ignoreOwnHotKeys, "ignoreOwnHotKeys") } }

    // MARK: General
    /// Show a short on-screen note when an effect is switched on or off.
    var announceToggles: Bool = true { didSet { save(announceToggles, "announceToggles") } }

    enum Defaults {
        static let spotlightRadius = 140.0
        static let spotlightSoftness = 0.15
        static let dimColor = RGBA(0, 0, 0, 0.55)
        static let animationDuration = 0.35
        static let autoOffSeconds = 10.0
        static let clickRadius = 26.0
        static let clickFadeDuration = 0.4
        static let leftClickColor = RGBA(0.95, 0.20, 0.18, 0.9)
        static let rightClickColor = RGBA(0.20, 0.45, 1.0, 0.9)
        static let otherClickColor = RGBA(0.20, 0.80, 0.35, 0.9)
        static let clickVolume = 0.5
        static let keystrokeFontSize = 34.0
        static let keystrokeBackground = RGBA(0.08, 0.08, 0.09, 0.78)
        static let keystrokeFadeSeconds = 1.6
        // ⌃⌥⌘L, ⌃⌥⌘C, ⌃⌥⌘K: three-modifier chords nothing else claims by default.
        static let spotlightHotKey: HotKey? = HotKey(keyCode: 37, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘L")
        static let clicksHotKey: HotKey? = HotKey(keyCode: 8, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘C")
        static let keystrokesHotKey: HotKey? = HotKey(keyCode: 40, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘K")
    }

    /// Every key this class writes, so a reset can clear them all.
    private static let keys = [
        "spotlightRadius", "spotlightSoftness", "dimColor", "spotlightAnimates", "spotlightAnimationDuration",
        "spotlightAutoOff", "spotlightAutoOffSeconds", "spotlightHotKey", "clicksWithSpotlight", "clickRadius",
        "clickExpands", "clickFadeDuration", "leftClickColor", "rightClickColor", "otherClickColor", "clickSound",
        "clickVolume", "clicksHotKey", "keystrokesHotKey", "keystrokeFilter", "keystrokeFontSize",
        "keystrokeBackground", "keystrokeFadeSeconds", "keystrokeScreen", "ignoreOwnHotKeys", "announceToggles",
    ]

    @ObservationIgnored private var loading = false

    private init() { load() }

    /// Puts every setting back to how a new install starts. Where the app appears,
    /// open-at-login and update checks are left alone.
    func resetToDefaults() {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        load()
    }

    private func load() {
        loading = true
        defer { loading = false }
        let d = UserDefaults.standard
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func codable<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = d.data(forKey: key) else { return fallback }
            return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
        }

        spotlightRadius = double("spotlightRadius", Defaults.spotlightRadius)
        spotlightSoftness = double("spotlightSoftness", Defaults.spotlightSoftness)
        dimColor = codable("dimColor", Defaults.dimColor)
        spotlightAnimates = bool("spotlightAnimates", true)
        spotlightAnimationDuration = double("spotlightAnimationDuration", Defaults.animationDuration)
        spotlightAutoOff = bool("spotlightAutoOff", false)
        spotlightAutoOffSeconds = double("spotlightAutoOffSeconds", Defaults.autoOffSeconds)
        spotlightHotKey = codable("spotlightHotKey", Defaults.spotlightHotKey)

        clicksWithSpotlight = bool("clicksWithSpotlight", true)
        clickRadius = double("clickRadius", Defaults.clickRadius)
        clickExpands = bool("clickExpands", true)
        clickFadeDuration = double("clickFadeDuration", Defaults.clickFadeDuration)
        leftClickColor = codable("leftClickColor", Defaults.leftClickColor)
        rightClickColor = codable("rightClickColor", Defaults.rightClickColor)
        otherClickColor = codable("otherClickColor", Defaults.otherClickColor)
        clickSound = bool("clickSound", false)
        clickVolume = double("clickVolume", Defaults.clickVolume)
        clicksHotKey = codable("clicksHotKey", Defaults.clicksHotKey)

        keystrokesHotKey = codable("keystrokesHotKey", Defaults.keystrokesHotKey)
        keystrokeFilter = KeystrokeFilter(rawValue: d.string(forKey: "keystrokeFilter") ?? "") ?? .all
        keystrokeFontSize = double("keystrokeFontSize", Defaults.keystrokeFontSize)
        keystrokeBackground = codable("keystrokeBackground", Defaults.keystrokeBackground)
        keystrokeFadeSeconds = double("keystrokeFadeSeconds", Defaults.keystrokeFadeSeconds)
        keystrokeScreen = UInt32(d.integer(forKey: "keystrokeScreen"))
        ignoreOwnHotKeys = bool("ignoreOwnHotKeys", true)
        announceToggles = bool("announceToggles", true)
    }

    private func save(_ value: Any, _ key: String) {
        guard !loading else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        guard !loading else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

extension Binding where Value == RGBA {
    /// For SwiftUI's ColorPicker.
    var color: Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: wrappedValue.nsColor) },
            set: { wrappedValue = RGBA(NSColor($0)) }
        )
    }
}
