import AppKit
import SwiftUI

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
app.run()

/// Launch, the menu bar item, the Dock menu, and reopening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let effects = Effects.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = AppPresence.mainMenu(appName: AppInfo.name, settingsTitle: "Settings…",
                                            target: self, settings: #selector(showSettings))
        // Right below About in the app menu.
        mainMenu.items.first?.submenu?.insertItem(item("Our other apps…", #selector(showOtherApps)), at: 1)
        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(item("\(AppInfo.name) Help", #selector(showHelp), key: "?"))
        helpItem.submenu = help
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = mainMenu
        AppAppearance.start()
        #if DEBUG
        // A test run shares the installed app's settings, so it checks Help and stops
        // before any effect, monitor or sync starts.
        if let snapshot = ProcessInfo.processInfo.environment["CLICKLENS_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: self)
            return
        }
        #endif
        effects.onChange = { [weak self] in self?.refreshIcon() }
        // Set at the end of the first launch, so its absence means a brand-new install.
        let newInstall = !UserDefaults.standard.bool(forKey: "askedForAccessibility")
        effects.start()
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()

        setUpStatusItem()
        // ToolHUD can take the menu into its own while it runs.
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem?.isVisible = MenuHub.shared.showsOwnIcon }
        }
        MenuHub.shared.onChange = { SettingsSync.shared.localDidChange() }
        MenuHub.shared.start(menu: { [weak self] in
            let menu = NSMenu()
            self?.menuNeedsUpdate(menu)
            return menu
        }, icon: { [weak self] in self?.statusItem?.button?.image })

        // The keystroke display needs Accessibility; ask once on first launch so the
        // feature works the first time it is switched on.
        if !UserDefaults.standard.bool(forKey: "askedForAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedForAccessibility")
            if !InputMonitor.shared.isTrusted { InputMonitor.shared.requestTrust() }
        }

        AutoUpdater.shared.start()
        if !AppPresence.showInMenuBar && !AppPresence.showInDock { showSettings() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(showSettings))
        menu.insertItem(.separator(), at: 0)
        for item in effectItems().reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    /// Opening the app again (from Applications, Spotlight, or the Dock tile) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `clicklens://` URLs (from ToolHUD, Shortcuts or a script) switch the effect they name,
    /// as its shortcut does.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "clicklens" {
            switch url.host {
            case "spotlight": effects.toggleSpotlight()
            case "clicks": effects.toggleClicks()
            case "keystrokes": effects.toggleKeystrokes()
            case "box": effects.toggleBox()
            case "arrow": effects.toggleArrow()
            default: showSettings()
            }
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = MenuHub.shared.showsOwnIcon
        statusItem = item
        refreshIcon()
    }

    private func refreshIcon() {
        let name = effects.anyOn ? "cursorarrow.rays" : "cursorarrow"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in effectItems() { menu.addItem(item) }

        if !InputMonitor.shared.isTrusted {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "Allow Keystroke Display…", action: #selector(allowAccessibility), keyEquivalent: "")
            warn.target = self
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let helpEntry = item("\(AppInfo.name) Help", #selector(showHelp))
        helpEntry.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(helpEntry)
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(item("About \(AppInfo.name)", #selector(showAbout)))
        menu.addItem(item("Our other apps…", #selector(showOtherApps)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit \(AppInfo.name)", #selector(quit), key: "q"))
    }

    private func effectItems() -> [NSMenuItem] {
        let prefs = Preferences.shared
        let entries: [(String, Selector, Bool, HotKey?)] = [
            ("Spotlight", #selector(toggleSpotlight), effects.spotlightOn, prefs.spotlightHotKey),
            ("Click Rings", #selector(toggleClicks), effects.clicksOn, prefs.clicksHotKey),
            ("Keystrokes", #selector(toggleKeystrokes), effects.keystrokesOn, prefs.keystrokesHotKey),
            ("Draw Box", #selector(toggleBox), effects.boxOn, prefs.boxHotKey),
            ("Draw Arrow", #selector(toggleArrow), effects.arrowOn, prefs.arrowHotKey),
        ]
        return entries.map { title, action, on, hotKey in
            let menuItem = item(title, action)
            menuItem.state = on ? .on : .off
            if let shortcut = hotKey?.menuKeyEquivalent {
                menuItem.keyEquivalent = shortcut.key
                menuItem.keyEquivalentModifierMask = shortcut.mask
            }
            return menuItem
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc func toggleSpotlight() { effects.toggleSpotlight() }
    @objc func toggleClicks() { effects.toggleClicks() }
    @objc func toggleKeystrokes() { effects.toggleKeystrokes() }
    @objc func toggleBox() { effects.toggleBox() }
    @objc func toggleArrow() { effects.toggleArrow() }
    @objc func showSettings() { SettingsWindow.shared.show() }
    @objc func showHelp() { HelpWindow.shared.show() }
    @objc func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc func installUpdateNow() { AutoUpdater.shared.installNow() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func allowAccessibility() {
        InputMonitor.shared.requestTrust()
        InputMonitor.openAccessibilitySettings()
    }

    /// The developer's site, which lists every app.
    @objc func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
