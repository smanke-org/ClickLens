import AppKit
import ClickLensKit
import SwiftUI

/// Settings in an AppKit window, so the Dock menu and the menu bar item can open it
/// (SwiftUI's Settings scene can't be opened from AppKit).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    var makeContent: (() -> AnyView)?
    private var window: NSWindow?

    func show() {
        if window == nil, let makeContent {
            let hosting = NSHostingController(rootView: makeContent())
            // Without this a grouped Form has no natural height and opens as a sliver.
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "ClickLens Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Effects.shared.previewingClicks = false
        Effects.shared.previewingSpotlight = false
    }
}

enum SettingsTab: Hashable { case spotlight, clicks, keystrokes, general }

struct SettingsView: View {
    @State private var tab = SettingsTab.spotlight

    var body: some View {
        TabView(selection: $tab) {
            SpotlightSettings().tabItem { Label("Spotlight", systemImage: "circle.dashed.inset.filled") }.tag(SettingsTab.spotlight)
            ClickSettings().tabItem { Label("Clicks", systemImage: "cursorarrow.click.2") }.tag(SettingsTab.clicks)
            KeystrokeSettings().tabItem { Label("Keystrokes", systemImage: "keyboard") }.tag(SettingsTab.keystrokes)
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        .frame(width: 520)
        .onChange(of: tab, initial: true) { _, tab in
            // On the Clicks tab every click shows a ring, so the settings can be judged live.
            Effects.shared.previewingClicks = tab == .clicks
        }
    }
}

/// A slider with its label and current value. While it is being dragged, `onEditing`
/// can turn on a live preview.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    var onEditing: (Bool) -> Void = { _ in }

    var body: some View {
        LabeledContent(title) {
            HStack {
                if let step {
                    Slider(value: $value, in: range, step: step, onEditingChanged: onEditing)
                } else {
                    Slider(value: $value, in: range, onEditingChanged: onEditing)
                }
                Text(format(value)).monospacedDigit().frame(width: 58, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}

private func seconds(_ v: Double) -> String { String(format: "%.1f s", v) }
private func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }
private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// MARK: - Spotlight

struct SpotlightSettings: View {
    @State private var prefs = Preferences.shared
    @State private var effects = Effects.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") { ShortcutRecorder(hotKey: $prefs.spotlightHotKey) }
                LabeledContent("Spotlight") {
                    Button(effects.spotlightOn ? "Turn Off" : "Turn On") { effects.toggleSpotlight() }
                }
                Toggle("Turn off automatically", isOn: $prefs.spotlightAutoOff)
                if prefs.spotlightAutoOff {
                    ValueSlider(title: "After", value: $prefs.spotlightAutoOffSeconds, range: 2...120, step: 1,
                                format: { "\(Int($0)) s" })
                }
            }
            Section {
                ValueSlider(title: "Circle radius", value: $prefs.spotlightRadius, range: 40...500,
                            format: points, onEditing: preview)
                ValueSlider(title: "Soft edge", value: $prefs.spotlightSoftness, range: 0...0.9,
                            format: percent, onEditing: preview)
                ValueSlider(title: "Dimming", value: $prefs.dimColor.alpha, range: 0.05...0.95,
                            format: percent, onEditing: preview)
                ColorPicker("Dim colour", selection: $prefs.dimColor.colorKeepingAlpha, supportsOpacity: false)
            } header: {
                Text("Look")
            } footer: {
                Text("The spotlight shows while you drag a slider.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Animation") {
                Toggle("Zoom in and out", isOn: $prefs.spotlightAnimates)
                if prefs.spotlightAnimates {
                    ValueSlider(title: "Duration", value: $prefs.spotlightAnimationDuration, range: 0.1...1.5,
                                format: seconds)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func preview(_ editing: Bool) {
        effects.previewingSpotlight = editing
    }
}

private extension Binding where Value == RGBA {
    /// Edits only the colour, keeping the stored opacity.
    var colorKeepingAlpha: Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: wrappedValue.with(alpha: 1).nsColor) },
            set: { wrappedValue = RGBA(NSColor($0)).with(alpha: wrappedValue.alpha) }
        )
    }
}

// MARK: - Clicks

struct ClickSettings: View {
    @State private var prefs = Preferences.shared
    @State private var effects = Effects.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show rings whenever the spotlight is on", isOn: $prefs.clicksWithSpotlight)
                LabeledContent("Rings on their own") {
                    HStack {
                        ShortcutRecorder(hotKey: $prefs.clicksHotKey)
                        Button(effects.clicksOn ? "Turn Off" : "Turn On") { effects.toggleClicks() }
                    }
                }
            } footer: {
                Text("While this tab is open, every click shows a ring so you can try your settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Look") {
                ValueSlider(title: "Radius", value: $prefs.clickRadius, range: 10...80, format: points)
                Toggle("Expand as they fade", isOn: $prefs.clickExpands)
                ValueSlider(title: "Fade time", value: $prefs.clickFadeDuration, range: 0.1...1.5, format: seconds)
                ColorPicker("Left button", selection: $prefs.leftClickColor.color, supportsOpacity: true)
                ColorPicker("Right button", selection: $prefs.rightClickColor.color, supportsOpacity: true)
                ColorPicker("Other buttons", selection: $prefs.otherClickColor.color, supportsOpacity: true)
            }
            Section("Sound") {
                Toggle("Play a click sound", isOn: $prefs.clickSound)
                ValueSlider(title: "Volume", value: $prefs.clickVolume, range: 0...1, format: percent) { editing in
                    if !editing { ClickSounds.shared.play(down: true) }
                }
                .disabled(!prefs.clickSound)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keystrokes

struct KeystrokeSettings: View {
    @State private var prefs = Preferences.shared
    @State private var effects = Effects.shared
    @State private var trusted = InputMonitor.shared.isTrusted

    var body: some View {
        Form {
            if !trusted {
                Section {
                    Label("ClickLens needs Accessibility access to see keystrokes. Clicks and the spotlight work without it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Privacy Settings") {
                        InputMonitor.shared.requestTrust()
                        InputMonitor.openAccessibilitySettings()
                    }
                }
            }
            Section {
                LabeledContent("Shortcut") {
                    HStack {
                        ShortcutRecorder(hotKey: $prefs.keystrokesHotKey)
                        Button(effects.keystrokesOn ? "Turn Off" : "Turn On") { effects.toggleKeystrokes() }
                    }
                }
                Picker("Show", selection: $prefs.keystrokeFilter) {
                    ForEach(KeystrokeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Hide ClickLens's own shortcuts", isOn: $prefs.ignoreOwnHotKeys)
            }
            Section {
                ValueSlider(title: "Font size", value: $prefs.keystrokeFontSize, range: 14...96, step: 1,
                            format: points) { editing in if !editing { KeystrokeDisplay.shared.showSample() } }
                ValueSlider(title: "Fade after", value: $prefs.keystrokeFadeSeconds, range: 0.5...6, format: seconds)
                ColorPicker("Background", selection: $prefs.keystrokeBackground.color, supportsOpacity: true)
                LabeledContent("Preview") {
                    Button("Show Sample") { KeystrokeDisplay.shared.showSample() }
                }
            } header: {
                Text("Look")
            }
            Section("Show on") {
                ScreenPicker(selection: $prefs.keystrokeScreen)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: InputMonitor.trustDidChange)) { _ in
            trusted = InputMonitor.shared.isTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = InputMonitor.shared.isTrusted
        }
    }
}

/// The display arrangement in miniature: click a screen to put keystrokes there.
struct ScreenPicker: View {
    @Binding var selection: UInt32
    @State private var screens = ScreenPicker.currentScreens()

    struct ScreenInfo: Identifiable {
        let id: UInt32
        let name: String
        let frame: CGRect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Screen", selection: $selection) {
                Text("The screen with the pointer").tag(UInt32(0))
                ForEach(screens) { Text($0.name).tag($0.id) }
            }
            arrangement.frame(height: 110)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = Self.currentScreens()
        }
    }

    private var arrangement: some View {
        GeometryReader { geo in
            let bounds = screens.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = bounds.isNull ? 1 : min(geo.size.width / bounds.width, geo.size.height / bounds.height) * 0.92
            let offsetX = (geo.size.width - bounds.width * scale) / 2
            let offsetY = (geo.size.height - bounds.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(screens) { screen in
                    let selected = selection == screen.id
                    let rect = CGRect(x: offsetX + (screen.frame.minX - bounds.minX) * scale,
                                      // Cocoa screens grow upward; the drawing grows downward.
                                      y: offsetY + (bounds.maxY - screen.frame.maxY) * scale,
                                      width: screen.frame.width * scale, height: screen.frame.height * scale)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: selected ? 2 : 1))
                        .overlay(Text(screen.name).font(.caption2).lineLimit(1).padding(4))
                        .frame(width: rect.width - 3, height: rect.height - 3)
                        .offset(x: rect.minX, y: rect.minY)
                        .onTapGesture { selection = screen.id }
                }
            }
        }
    }

    static func currentScreens() -> [ScreenInfo] {
        NSScreen.screens.map { ScreenInfo(id: $0.displayID, name: $0.localizedName, frame: $0.frame) }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var prefs = Preferences.shared
    @State private var presence = PresenceSettings.shared
    @State private var login = LaunchAtLogin.shared
    @State private var confirmReset = false
    @AppStorage("checkForUpdatesAutomatically") private var checkAutomatically = true

    var body: some View {
        Form {
            Section("Where ClickLens appears") {
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                if !presence.showInDock && !presence.showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "ClickLens", settingsName: "Settings"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Open ClickLens at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval {
                    Button("Allow in Login Items…") { login.openLoginItemsSettings() }
                }
                if let error = login.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Toggle("Announce when an effect turns on or off", isOn: $prefs.announceToggles)
            }
            Section("Updates") {
                Toggle("Check for updates when ClickLens opens", isOn: $checkAutomatically)
                LabeledContent("Version \(AppInfo.displayVersion)") {
                    Button("Check Now") { UpdateController.checkForUpdates() }
                }
            }
            Section {
                LabeledContent("Effects settings") {
                    Button("Reset to Defaults…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
        .confirmationDialog("Reset the spotlight, click and keystroke settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                prefs.resetToDefaults()
                HotKeyCenter.shared.apply()
            }
        } message: {
            Text("Shortcuts, colours and sizes go back to how ClickLens started. Where it appears and login stay as they are.")
        }
    }
}

/// `AppPresence` values as observable state for Settings.
@Observable
@MainActor
final class PresenceSettings {
    static let shared = PresenceSettings()

    var showInDock = AppPresence.showInDock {
        didSet {
            AppPresence.showInDock = showInDock
            AppPresence.applyDock(keepInFront: NSApp.keyWindow)
        }
    }

    var showInMenuBar = AppPresence.showInMenuBar {
        didSet { AppPresence.showInMenuBar = showInMenuBar }
    }
}
