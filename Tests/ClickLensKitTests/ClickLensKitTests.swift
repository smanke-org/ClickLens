import Foundation
import Testing
@testable import ClickLensKit

private func key(_ code: UInt16, _ chars: String, _ mods: KeyModifiers = []) -> Keystroke {
    Keystroke(keyCode: code, modifiers: mods, charactersIgnoringModifiers: chars.lowercased(), characters: chars)
}

@Test func shortcutLabelsUseMenuOrder() {
    let k = key(40, "k", [.command, .shift, .control])
    #expect(k.label == "⌃⇧⌘K")
    #expect(!k.isTyping)
}

@Test func specialKeysHaveGlyphs() {
    #expect(key(36, "\r").label == "↩")
    #expect(key(122, "").label == "F1")
    #expect(key(90, "").label == "F20")
    #expect(key(123, "", [.command]).label == "⌘←")
}

@Test func filtersMatchTheirDescriptions() {
    #expect(KeystrokeFilter.all.shows([]))
    #expect(!KeystrokeFilter.combos.shows([]))
    #expect(!KeystrokeFilter.combos.shows([.function]))
    for m: KeyModifiers in [.shift, .option, .control, .command] { #expect(KeystrokeFilter.combos.shows(m)) }
}

@Test func olderStoredFiltersBecomeCombos() {
    #expect(KeystrokeFilter(stored: "withModifiers") == .combos)
    #expect(KeystrokeFilter(stored: "shortcutsOnly") == .combos)
    #expect(KeystrokeFilter(stored: nil) == .all)
}

@Test func combosKeepShiftAndStandAlone() {
    var line = KeystrokeLine()
    line.add(key(0, "A", [.shift]), asCombo: true)
    line.add(key(8, "c", [.command]), asCombo: true)
    #expect(line.entries == ["⇧A", "⌘C"])
}

@Test func typingCollectsIntoOneRunAndShortcutsStandAlone() {
    var line = KeystrokeLine()
    line.add(key(4, "h"))
    line.add(key(34, "I", [.shift]))
    line.add(key(1, "s", [.command]))
    line.add(key(49, " "))
    line.add(key(36, "\r"))
    #expect(line.entries == ["hI", "⌘S", "␣↩"])
}

@Test func longLinesKeepTheNewestText() {
    var line = KeystrokeLine(maxLength: 10)
    for c in "abcdefghijklmnop" { line.add(key(0, String(c))) }
    #expect(line.text.count <= 10)
    #expect(line.text.hasSuffix("mnop"))
    #expect(line.text.hasPrefix("…"))

    var mixed = KeystrokeLine(maxLength: 10)
    for _ in 0..<6 { mixed.add(key(1, "s", [.command])) }
    #expect(mixed.text.count <= 10)
}

@Test func spotlightZoomsFromTheScreenToTheCircle() {
    let off = SpotlightFrame.at(level: 0, radius: 100, screenDiagonal: 3000, zoom: true)
    let on = SpotlightFrame.at(level: 1, radius: 100, screenDiagonal: 3000, zoom: true)
    #expect(off.radius == 3000 && off.dimFraction == 0)
    #expect(on.radius == 100 && on.dimFraction == 1)
    #expect(SpotlightFrame.at(level: 0.3, radius: 100, screenDiagonal: 3000, zoom: false).radius == 100)
}

@Test func clickRingsHoldThenFade() {
    #expect(ClickRingFrame.at(sinceRelease: nil, radius: 20, duration: 0.3, expand: true).opacity == 1)
    let done = ClickRingFrame.at(sinceRelease: 0.3, radius: 20, duration: 0.3, expand: true)
    #expect(done.opacity == 0 && done.radius > 20)
    #expect(ClickRingFrame.at(sinceRelease: 0.3, radius: 20, duration: 0.3, expand: false).radius == 20)
}

@Test func synthesizedClickIsAValidWav() {
    let data = ClickSoundSynth.wav(frequency: 1800)
    #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
    #expect(data.count == 44 + Int(44_100 * 0.045) * 2)
}

@Test func everyArrowShapeEndsAtItsTip() {
    let tail = CGPoint(x: 0, y: 0), tip = CGPoint(x: 300, y: 120)
    for shape in ArrowShape.allCases {
        let arrow = ArrowGeometry.path(from: tail, to: tip, shape: shape, thickness: 6)
        let box = arrow.path.boundingBoxOfPath
        // The tip is the furthest point toward the arrow's direction, inside the outline.
        #expect(box.insetBy(dx: -1, dy: -1).contains(tip), "\(shape)")
        #expect(abs(box.maxX - tip.x) < 1, "\(shape) overshoots its tip")
    }
}

@Test func shortArrowsStillDraw() {
    for shape in ArrowShape.allCases {
        let arrow = ArrowGeometry.path(from: .zero, to: CGPoint(x: 12, y: 0), shape: shape, thickness: 10)
        #expect(!arrow.path.isEmpty)
        // The head shrinks with the arrow rather than dwarfing it.
        #expect(arrow.path.boundingBoxOfPath.width < 40, "\(shape)")
    }
}

@Test func marksFadeAfterTimeEscapeOrBoth() {
    #expect(MarkDismissal.afterTime.fadeStart(finished: 10, fadeAfter: 3, escaped: 11) == 13)
    #expect(MarkDismissal.onEscape.fadeStart(finished: 10, fadeAfter: 3, escaped: nil) == nil)
    #expect(MarkDismissal.onEscape.fadeStart(finished: 10, fadeAfter: 3, escaped: 50) == 50)
    #expect(MarkDismissal.both.fadeStart(finished: 10, fadeAfter: 3, escaped: 11) == 11)
    #expect(MarkDismissal.both.fadeStart(finished: 10, fadeAfter: 3, escaped: nil) == 13)
    #expect(MarkDismissal.both.fadeStart(finished: nil, fadeAfter: 3, escaped: 11) == nil)
    #expect(MarkDismissal(stored: nil) == .afterTime)
    #expect(MarkDismissal(stored: "both") == .both)
}
