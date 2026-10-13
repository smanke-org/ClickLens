import AppKit
import ClickLensKit
import SwiftUI

/// Settings in an AppKit window with the standard toolbar tabs (an icon above each
/// label), so the Dock menu and the menu bar item can open it (SwiftUI's Settings
/// scene can't be opened from AppKit).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let tabs = SettingsTabs()
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
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

/// One toolbar item per pane; the window resizes to fit each pane and takes its name
/// as the title, the way macOS's own Settings windows behave.
@MainActor
final class SettingsTabs: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        add("Spotlight", "circle.dashed.inset.filled", SpotlightSettings())
        add("Clicks", "cursorarrow.click.2", ClickSettings())
        add("Keystrokes", "keyboard", KeystrokeSettings())
        add("Box", "rectangle.dashed", BoxSettings())
        add("Arrow", "arrow.up.right", ArrowSettings())
        add("General", "gearshape", GeneralSettings())
    }

    required init?(coder: NSCoder) { fatalError() }

    private func add(_ title: String, _ symbol: String, _ view: some View) {
        let pane = VStack(spacing: 0) {
            view
            Text("\(AppInfo.name) \(AppInfo.displayVersion)")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .frame(width: 520)
        // Each pane gets its natural height, capped to the screen, with the Form scrolling
        // inside. Letting SwiftUI size the window to the Form's full height crashed once
        // a pane grew taller than the screen: AppKit clamped the window, SwiftUI asked to
        // grow again, and AppKit aborted the update-constraints loop.
        let hosting = NSHostingController(rootView: pane.frame(maxHeight: .infinity))
        hosting.sizingOptions = []
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
        naturalHeight[item] = { NSHostingView(rootView: pane).fittingSize.height }
        fit(item)
    }

    /// Measures a pane on a throwaway hosting view, so the window never follows SwiftUI.
    private var naturalHeight: [NSTabViewItem: () -> CGFloat] = [:]

    /// Sizes a pane before it's shown (re-measured each time, as panes change), no taller
    /// than the screen.
    private func fit(_ item: NSTabViewItem) {
        guard let height = naturalHeight[item]?() else { return }
        let screen = (isViewLoaded ? view.window?.screen : nil) ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 120
        item.viewController?.preferredContentSize = NSSize(width: 520, height: min(height, available))
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if let tabViewItem { fit(tabViewItem) }
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        selectionChanged()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        selectionChanged()
    }

    private func selectionChanged() {
        let item = tabViewItems[selectedTabViewItemIndex]
        view.window?.title = item.label
        // On the Clicks tab every click shows a ring, so the settings can be judged live.
        Effects.shared.previewingClicks = item.label == "Clicks"
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
                // Rounded here rather than with Slider's `step`, which draws a tick
                // mark for every step.
                Slider(value: Binding(get: { value }, set: { new in
                    value = step.map { (new / $0).rounded() * $0 } ?? new
                }), in: range, onEditingChanged: onEditing)
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
                ColorPicker("Dim color", selection: $prefs.dimColor.colorKeepingAlpha, supportsOpacity: false)
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
    /// Edits only the color, keeping the stored opacity.
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
                .pickerStyle(.radioGroup)
                Text(prefs.keystrokeFilter.detail).font(.callout).foregroundStyle(.secondary)
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

// MARK: - Box

struct BoxSettings: View {
    @State private var prefs = Preferences.shared
    @State private var effects = Effects.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    HStack {
                        ShortcutRecorder(hotKey: $prefs.boxHotKey)
                        Button(effects.boxOn ? "Stop Drawing" : "Start Drawing") { effects.toggleBox() }
                    }
                }
                Toggle("Keep drawing until Esc", isOn: $prefs.boxKeepDrawing)
            } footer: {
                Text(prefs.boxKeepDrawing
                     ? "Press the shortcut, then click and drag to draw boxes around anything on screen. While drawing, clicks go to ClickLens; press Esc or the shortcut again to go back to using your Mac."
                     : "Press the shortcut, then click and drag to draw a box around anything on screen. When you let go, your Mac is back to normal. Press Esc to cancel before drawing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Look") {
                ColorPicker("Line color", selection: $prefs.boxColor.color, supportsOpacity: true)
                ValueSlider(title: "Thickness", value: $prefs.boxThickness, range: 1...20, step: 1, format: points)
                ValueSlider(title: "Fade after", value: $prefs.boxFadeAfter, range: 0.5...30, step: 0.5, format: seconds)
                LabeledContent("Preview") {
                    Button("Show Sample") { OverlayController.shared.showSample(.box) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Arrow

struct ArrowSettings: View {
    @State private var prefs = Preferences.shared
    @State private var effects = Effects.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    HStack {
                        ShortcutRecorder(hotKey: $prefs.arrowHotKey)
                        Button(effects.arrowOn ? "Stop Drawing" : "Start Drawing") { effects.toggleArrow() }
                    }
                }
                Picker("Your click marks", selection: $prefs.arrowClickIsTip) {
                    Text("Where the arrow starts").tag(false)
                    Text("What the arrow points at").tag(true)
                }
                .pickerStyle(.radioGroup)
                Toggle("Keep drawing until Esc", isOn: $prefs.arrowKeepDrawing)
            } footer: {
                Text(prefs.arrowClickIsTip
                     ? "Press the shortcut, click the thing you want to point at, and drag away from it. The arrowhead stays where you clicked."
                     : "Press the shortcut, click where the arrow should start, and drag to what it should point at.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shape") {
                HStack(spacing: 10) {
                    ForEach(ArrowShape.allCases, id: \.self) { shape in
                        ArrowShapeTile(shape: shape, color: prefs.arrowColor, selected: prefs.arrowShape == shape)
                            .onTapGesture { prefs.arrowShape = shape }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Section("Look") {
                ColorPicker("Color", selection: $prefs.arrowColor.color, supportsOpacity: true)
                ValueSlider(title: "Thickness", value: $prefs.arrowThickness, range: 1...20, step: 1, format: points)
                ValueSlider(title: "Fade after", value: $prefs.arrowFadeAfter, range: 0.5...30, step: 0.5, format: seconds)
                LabeledContent("Preview") {
                    Button("Show Sample") { OverlayController.shared.showSample(.arrow) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A small drawing of one arrow shape, for choosing it.
struct ArrowShapeTile: View {
    let shape: ArrowShape
    let color: RGBA
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                // Drawn at a real on-screen size and scaled down, so the head keeps the
                // proportions it has on screen instead of swamping a tiny line.
                let scale: CGFloat = 0.32
                context.scaleBy(x: scale, y: scale)
                let w = size.width / scale, h = size.height / scale
                let tail = CGPoint(x: 24, y: h - 24)
                let tip = CGPoint(x: w - 24, y: 30)
                let arrow = ArrowGeometry.path(from: tail, to: tip, shape: shape, thickness: 6)
                let c = Color(nsColor: color.with(alpha: 1).nsColor)
                let style = StrokeStyle(lineWidth: arrow.lineWidth, lineCap: .round, lineJoin: .round)
                context.stroke(Path(arrow.line), with: .color(c), style: style)
                context.fill(Path(arrow.head), with: .color(c))
                context.stroke(Path(arrow.head), with: .color(c), style: style)
            }
            .frame(width: 64, height: 44)
            Text(shape.title).font(.caption)
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shape.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var prefs = Preferences.shared
    @State private var presence = PresenceSettings.shared
    @State private var login = LaunchAtLogin.shared
    @State private var confirmReset = false
    @State private var sync = SettingsSync.shared
    @State private var updater = AutoUpdater.shared

    private var updateFooter: String {
        switch updater.policy {
        case .automatic:
            "ClickLens checks every 30 minutes. A new version installs itself when no ClickLens effect has been on for 30 minutes, no app is presenting or keeping the screen awake, and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            "ClickLens checks every 30 minutes and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            "ClickLens won't look for updates on its own. Use Check Now whenever you like."
        }
    }

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
            Section {
                Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
                if sync.isEnabled {
                    LabeledContent {
                        Button("Sync Now") { sync.syncNow() }
                    } label: {
                        if let error = sync.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if let date = sync.lastSynced {
                            Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == SettingsSync.deviceName ? "" : " from \($0)" } ?? "")")
                        } else {
                            Text("Waiting for iCloud Drive…")
                        }
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Shortcuts, colors, sizes and other settings follow you to every Mac signed in to the same iCloud account with sync turned on. Open at login and the keystroke screen stay separate on each Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("When an update is available", selection: $updater.policy) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if let staged = updater.staged {
                    LabeledContent("Version \(staged.version) is ready") {
                        Button("Install Now") { updater.installNow() }
                    }
                }
                LabeledContent("Version \(AppInfo.displayVersion)") {
                    Button("Check Now") { UpdateController.checkForUpdates() }
                }
                if let error = updater.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if updater.policy != .off && !updater.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    } label: {
                        Label("Notifications are off for ClickLens, so update news only shows in the menu.",
                              systemImage: "bell.slash").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updateFooter).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Effects settings") {
                    Button("Reset to Defaults…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh(); updater.refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updater.refreshNotificationStatus()
        }
        .confirmationDialog("Reset the spotlight, click and keystroke settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                prefs.resetToDefaults()
                HotKeyCenter.shared.apply()
            }
        } message: {
            Text("Shortcuts, colors and sizes go back to how ClickLens started. Where it appears and login stay as they are.")
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

    /// Follows choices that arrived from another Mac.
    func reload() {
        if showInDock != AppPresence.showInDock { showInDock = AppPresence.showInDock }
        if showInMenuBar != AppPresence.showInMenuBar { showInMenuBar = AppPresence.showInMenuBar }
        // The status item follows the notification, which the setter only posts on a change.
        NotificationCenter.default.post(name: AppPresence.menuBarDidChange, object: nil)
    }
}
