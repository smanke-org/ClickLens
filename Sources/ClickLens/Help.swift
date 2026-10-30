import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. `{hotkey:spotlight}` (and clicks, keystrokes, box, arrow) shows the
/// user's own shortcut for that effect, so the text matches their settings.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    static func resolve(_ text: String) -> String {
        guard text.contains("{hotkey:") else { return text }
        let prefs = Preferences.shared
        let keys: [(String, HotKey?)] = [("spotlight", prefs.spotlightHotKey), ("clicks", prefs.clicksHotKey),
                                         ("keystrokes", prefs.keystrokesHotKey), ("box", prefs.boxHotKey),
                                         ("arrow", prefs.arrowHotKey)]
        var out = text
        for (name, key) in keys {
            out = out.replacingOccurrences(of: "{hotkey:\(name)}", with: key?.display ?? "(no shortcut set)")
        }
        return out
    }

    /// The topic each Settings tab's Help button opens.
    static func topic(forSettingsTab tab: String) -> String {
        switch tab {
        case "Spotlight": "spotlight"
        case "Clicks": "clicks"
        case "Keystrokes": "keystrokes"
        case "Box": "box"
        case "Arrow": "arrow"
        default: "getting-started"
        }
    }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("ClickLens helps people follow what you do on screen, for presentations, screen recordings, teaching and support calls. It runs from the menu bar (the pointer icon, which shows rays while an effect is on)."),
            .heading("Five effects"),
            .keys([
                ("{hotkey:spotlight}", "Spotlight: dim the screen except around the pointer"),
                ("{hotkey:clicks}", "Click rings: show a ring wherever you click"),
                ("{hotkey:keystrokes}", "Keystrokes: show the keys you press"),
                ("{hotkey:box}", "Draw a box around something"),
                ("{hotkey:arrow}", "Draw an arrow pointing at something"),
            ]),
            .text("Each shortcut turns its effect on, and pressing it again turns it off. The menu bar menu lists the same five, with a check beside those that are on."),
            .heading("Permission"),
            .text("Showing keystrokes needs Accessibility permission (macOS 27 calls it Device Control). Everything else works without it. If the menu bar menu shows \"Allow Keystroke Display…\", choose it."),
            .tip("Turn on \"Announce when an effect turns on or off\" in Settings › General to see a short notice each time, handy when you can't see the menu bar."),
            .tip("While ToolHUD is running, ClickLens's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings."),
            .tip("Quitting asks first, since the effects and their shortcuts stop while ClickLens is closed. Turn off \"Ask before quitting\" in Settings › General, or tick \"Don't ask again\" when it asks."),
        ]),

        HelpTopic(id: "spotlight", title: "Spotlight", symbol: "circle.dashed.inset.filled", blocks: [
            .text("Press {hotkey:spotlight} to dim everything except a circle around the pointer, so your audience looks where you're pointing. Press it again to turn it off."),
            .keys([
                ("Circle radius", "How big the lit circle is"),
                ("Soft edge", "A crisp or a feathered edge"),
                ("Dimming / Dim color", "How dark the rest of the screen gets, and its color"),
                ("Zoom in and out", "Animate the spotlight as it turns on and off"),
                ("Turn off automatically", "Switch the spotlight off after a number of seconds"),
            ]),
            .tip("The spotlight shows while you drag a slider in Settings, so you can see each change."),
            .tip("Settings › Clicks › \"Show rings whenever the spotlight is on\" adds click rings for as long as the spotlight shows."),
        ]),

        HelpTopic(id: "clicks", title: "Click Rings", symbol: "cursorarrow.click.2", blocks: [
            .text("Press {hotkey:clicks} and every click shows a colored ring that fades away, so viewers see each click. Left, right and other buttons each have their own color."),
            .keys([
                ("Radius / Fade time", "Ring size and how long it lasts"),
                ("Expand as they fade", "Rings grow as they disappear"),
                ("Play a click sound", "An audible click, with its own volume"),
            ]),
            .tip("While Settings › Clicks is open, every click shows a ring, to try your settings."),
        ]),

        HelpTopic(id: "keystrokes", title: "Keystrokes", symbol: "keyboard", blocks: [
            .text("Press {hotkey:keystrokes} to show the keys you press in a bubble near the bottom of the screen. It needs Accessibility permission."),
            .keys([
                ("Everything you type", "Every key, including letters"),
                ("Key combinations only", "Only keys pressed with ⌘, ⌥ or ⌃, such as ⌘C, which keeps passwords and private typing off screen"),
                ("Hide ClickLens's own shortcuts", "Don't show the keys that turn effects on and off"),
                ("Font size / Fade after / Background", "How the bubble looks and how long it stays"),
                ("Screen", "Which display shows the bubble: the one with the pointer, or a fixed one"),
            ]),
            .tip("Use \"Key combinations only\" whenever you might type a password during a presentation."),
        ]),

        HelpTopic(id: "box", title: "Drawing Boxes", symbol: "rectangle.dashed", blocks: [
            .text("Press {hotkey:box}, then click and drag around anything on screen to draw a box."),
            .keys([
                ("Click and drag", "Draw the box"),
                ("Esc", "Cancel before drawing, stop drawing, or clear boxes that wait for Esc"),
                ("{hotkey:box} again", "Stop drawing"),
            ]),
            .text("With \"Keep drawing until Esc\" on, you can draw several boxes in a row; clicks go to ClickLens until you press Esc or the shortcut. With it off, your Mac is back to normal as soon as you let go."),
            .heading("How long boxes stay"),
            .text("Fade out \"After a number of seconds\", \"When I press Esc\", or \"Whichever comes first\". While a box waits for Esc, ClickLens takes the Esc key, so the app in front doesn't see it."),
        ]),

        HelpTopic(id: "arrow", title: "Drawing Arrows", symbol: "arrow.up.right", blocks: [
            .text("Press {hotkey:arrow}, then click and drag to draw an arrow."),
            .keys([
                ("Where the arrow starts", "Click the start, drag to what you point at"),
                ("What the arrow points at", "Click the target and drag away; the arrowhead stays where you clicked"),
                ("Esc", "Cancel, stop drawing, or clear arrows that wait for Esc"),
                ("{hotkey:arrow} again", "Stop drawing"),
            ]),
            .text("Choose \"Your click marks\" in Settings › Arrow. Pick a shape (straight, open head, curved, double-headed and more), a color and a thickness. Keep drawing and fade-out work as they do for boxes."),
        ]),

        HelpTopic(id: "shortcuts", title: "Keyboard Shortcuts", symbol: "command", blocks: [
            .keys([
                ("{hotkey:spotlight}", "Spotlight on or off"),
                ("{hotkey:clicks}", "Click rings on or off"),
                ("{hotkey:keystrokes}", "Keystrokes on or off"),
                ("{hotkey:box}", "Draw a box"),
                ("{hotkey:arrow}", "Draw an arrow"),
                ("Esc", "Stop drawing, then clear marks waiting for Esc"),
                ("⌘,", "Settings (from the menu bar menu)"),
                ("⌘?", "This Help (from ClickLens's menus)"),
            ]),
            .text("Change any shortcut on its effect's Settings tab: click the shortcut, then press the new keys."),
        ]),

        HelpTopic(id: "sync", title: "Sync and Settings", symbol: "icloud", blocks: [
            .text("Turn on \"Sync settings with your other Macs\" in Settings › General to share shortcuts, colors, sizes and asking before quitting through iCloud Drive. Open at login and the keystroke screen stay separate on each Mac."),
            .text("Show in Dock and Show in menu bar choose where ClickLens appears. Reset to Defaults… puts shortcuts, colors and sizes back to how ClickLens started; where it appears and login stay as they are."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .keys([
                ("clicklens://spotlight", "Spotlight on or off"),
                ("clicklens://clicks", "Click rings on or off"),
                ("clicklens://keystrokes", "Keystrokes on or off"),
                ("clicklens://box", "Draw a box"),
                ("clicklens://arrow", "Draw an arrow"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's ClickLens buttons use them."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("Keystrokes don't appear"),
            .text("ClickLens needs Accessibility permission. Choose \"Allow Keystroke Display…\" in the menu bar menu, or switch ClickLens on in System Settings › Privacy & Security. If it's on but still not working, remove it and add it again."),
            .heading("A shortcut does nothing"),
            .text("Another app may use the same keys. Record a different one on the effect's Settings tab."),
            .heading("Esc doesn't reach my app"),
            .text("While a box or arrow waits for Esc, ClickLens takes the key. Press Esc once to clear the marks, or choose \"After a number of seconds\" so they fade on their own."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ClickLensHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
