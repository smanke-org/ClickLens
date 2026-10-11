import AppKit
import ClickLensKit

/// A rounded label floating above everything, which clicks pass through.
@MainActor
final class HUDPanel {
    private let panel: OverlayPanel
    private let background = NSView()
    private let label = NSTextField(labelWithString: "")
    private var fadeTimer: Timer?
    private var onFaded: (() -> Void)?
    private var generation = 0

    init() {
        panel = OverlayPanel(screen: NSScreen.main ?? NSScreen.screens[0])
        let content = NSView()
        content.wantsLayer = true
        panel.contentView = content
        background.wantsLayer = true
        background.layer?.cornerCurve = .continuous
        content.addSubview(background)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingHead
        label.textColor = .white
        background.addSubview(label)
    }

    /// Shows `text` on `screen`, a fixed distance above the bottom of its usable area,
    /// then fades it out after `fadeAfter` seconds unless shown again first.
    func show(_ text: String, symbol: String? = nil, fontSize: Double, background color: RGBA,
              on screen: NSScreen, bottomOffset: Double, fadeAfter: Double, onFaded: (() -> Void)? = nil) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let string = NSMutableAttributedString()
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: fontSize, weight: .semibold)) {
            let attachment = NSTextAttachment()
            attachment.image = image
            string.append(NSAttributedString(attachment: attachment))
            string.append(NSAttributedString(string: "  "))
        }
        string.append(NSAttributedString(string: text))
        string.addAttributes([.font: font, .foregroundColor: NSColor.white],
                             range: NSRange(location: 0, length: string.length))
        label.attributedStringValue = string

        let textSize = label.intrinsicContentSize
        let padX = fontSize * 0.7, padY = fontSize * 0.35
        let maxWidth = screen.visibleFrame.width - 80
        let size = NSSize(width: min(textSize.width + padX * 2, maxWidth), height: textSize.height + padY * 2)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + bottomOffset)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        background.frame = NSRect(origin: .zero, size: size)
        background.layer?.backgroundColor = color.cgColor
        background.layer?.cornerRadius = min(size.height / 2, fontSize * 0.55)
        label.frame = NSRect(x: padX, y: padY, width: size.width - padX * 2, height: textSize.height)

        generation += 1
        let shown = generation
        self.onFaded = onFaded
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: fadeAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    self.panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        // Shown again while fading: leave the new text alone.
                        guard self.generation == shown else { return }
                        self.panel.orderOut(nil)
                        self.onFaded?()
                    }
                })
            }
        }
    }

    func hide() {
        fadeTimer?.invalidate()
        generation += 1
        panel.orderOut(nil)
    }
}

/// The on-screen keystroke display.
@MainActor
final class KeystrokeDisplay {
    static let shared = KeystrokeDisplay()

    private let hud = HUDPanel()
    private var line = KeystrokeLine()
    /// Modifiers held with no key yet, shown provisionally after the line.
    private var pendingModifiers = ""
    private let prefs = Preferences.shared

    func add(_ stroke: Keystroke) {
        guard prefs.keystrokeFilter.shows(stroke.modifiers) else { return }
        pendingModifiers = ""
        line.add(stroke)
        refresh()
    }

    /// Modifier keys going down or up on their own.
    func modifiersChanged(_ modifiers: KeyModifiers) {
        let shown = modifiers.subtracting(.function)
        let symbols = (shown.isEmpty || !prefs.keystrokeFilter.shows(shown)) ? "" : shown.symbols
        guard symbols != pendingModifiers else { return }
        pendingModifiers = symbols
        if !line.isEmpty || !pendingModifiers.isEmpty { refresh() }
    }

    func showSample() {
        line.clear()
        line.add(Keystroke(keyCode: 40, modifiers: [.command, .shift], charactersIgnoringModifiers: "k", characters: "K"))
        for c in "Hello" {
            line.add(Keystroke(keyCode: 0, modifiers: [], charactersIgnoringModifiers: String(c), characters: String(c)))
        }
        refresh()
    }

    func clear() {
        line.clear()
        pendingModifiers = ""
        hud.hide()
    }

    private func refresh() {
        let text = [line.text, pendingModifiers].filter { !$0.isEmpty }.joined(separator: "  ")
        guard !text.isEmpty else { return }
        hud.show(text, fontSize: prefs.keystrokeFontSize, background: prefs.keystrokeBackground,
                 on: targetScreen, bottomOffset: 70, fadeAfter: prefs.keystrokeFadeSeconds) { [weak self] in
            self?.line.clear()
            self?.pendingModifiers = ""
        }
    }

    private var targetScreen: NSScreen {
        let screens = NSScreen.screens
        if prefs.keystrokeScreen != 0, let chosen = screens.first(where: { $0.displayID == prefs.keystrokeScreen }) {
            return chosen
        }
        let pointer = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? screens[0]
    }
}

/// A brief note when an effect is switched on or off.
@MainActor
final class ToggleAnnouncer {
    static let shared = ToggleAnnouncer()
    private let hud = HUDPanel()

    func announce(_ title: String, symbol: String) {
        guard Preferences.shared.announceToggles else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        hud.show(title, symbol: symbol, fontSize: 20, background: RGBA(0.1, 0.1, 0.11, 0.85),
                 on: screen, bottomOffset: screen.visibleFrame.height * 0.22, fadeAfter: 1.1)
    }
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
