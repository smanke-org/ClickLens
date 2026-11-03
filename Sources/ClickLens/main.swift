import AppKit
import SwiftUI

// `clicklens <command>` (the app binary under a short name): run it against the running app
// and exit, without starting a second copy. See Agent/AgentCLI.swift.
if let code = AgentCLI.runIfRequested() { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// An agent CLI test copy (Debug, APP_STORE) stays out of the Dock.
app.setActivationPolicy(AppPresence.showInDock && !AgentSocket.isTestRun ? .regular : .accessory)
app.run()

/// Quits ClickLens without asking: for quitting itself (installing an update, ending a test).
@MainActor
enum QuitConfirmation {
    private(set) static var confirmed = false

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
    }
}

/// Launch, the menu bar item, the Dock menu, and reopening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let effects = Effects.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = AppPresence.mainMenu(appName: AppInfo.name, settingsTitle: "Settings…",
                                            target: self, settings: #selector(showSettings))
        // Right below About in the app menu, where Mac apps keep it.
        mainMenu.items.first?.submenu?.insertItem(item("Check for Updates…", #selector(checkForUpdates)), at: 1)
        mainMenu.items.first?.submenu?.insertItem(item("Our other apps…", #selector(showOtherApps)), at: 2)
        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(item("\(AppInfo.name) Help", #selector(showHelp), key: "?"))
        helpItem.submenu = help
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = mainMenu
        #if DEBUG
        // A test run of the agent CLI (APP_STORE): its own settings and the agent socket.
        // Nothing else starts: no effects, overlays, input monitors, shortcuts, sync, menu bar
        // item, ToolHUD hub, ShortcutsLens report, updater or Accessibility prompt.
        if AgentSocket.isTestRun {
            _ = Preferences.shared
            AgentSocket.listen { AgentRouter.handle($0) }
            return
        }
        #endif
        AppAppearance.start()
        #if DEBUG
        // A test run shares the installed app's settings, so it checks Help and stops
        // before any effect, monitor or sync starts.
        if let snapshot = ProcessInfo.processInfo.environment["CLICKLENS_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: self)
            return
        }
        if let how = ProcessInfo.processInfo.environment["CLICKLENS_DEBUG_QUIT_TEST"] {
            DebugQuitTest.run(how)
            return
        }
        // The update prompt, What's New and Settings drawn to PNGs; also starts nothing else.
        if let folder = ProcessInfo.processInfo.environment["CLICKLENS_DEBUG_UPDATE_NOTES"] {
            DebugUpdateNotes.run(folder: folder)
            return
        }
        #endif
        effects.onChange = { [weak self] in
            self?.refreshIcon()
            ToolHUDFeatureStates.publish()
        }
        // Set at the end of the first launch, so its absence means a brand-new install.
        let newInstall = !UserDefaults.standard.bool(forKey: "askedForAccessibility")
        effects.start()
        // `clicklens` and the MCP server talk to the app through this.
        AgentSocket.listen { AgentRouter.handle($0) }
        // ToolHUD lights the buttons of the effects that are on.
        ToolHUDFeatureStates.start { [effects] in
            ["spotlight": effects.spotlightOn, "clicks": effects.clicksOn, "keystrokes": effects.keystrokesOn,
             "box": effects.boxOn, "arrow": effects.arrowOn]
        }
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

        AutoUpdater.shared.start(newInstall: newInstall)
        if !AppPresence.showInMenuBar && !AppPresence.showInDock { showSettings() }
    }

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when ClickLens quits itself to install an update.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard Preferences.shared.confirmQuit, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }

        // A menu bar app needs to be a regular one for the alert to come to the front; the
        // old policy goes back a runloop turn later, once the alert is gone (AppKit ignores
        // it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit \(AppInfo.name)?"
        alert.informativeText = "Effects and their shortcuts stop working until you open \(AppInfo.name) again."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { Preferences.shared.confirmQuit = false }
        return .terminateNow
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
        for item in effectItems(icons: true) { menu.addItem(item) }

        if !InputMonitor.shared.isTrusted {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "Allow Keystroke Display…", action: #selector(allowAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn.showIcon("exclamationmark.triangle"))
        }

        menu.addItem(.separator())
        let helpEntry = item("\(AppInfo.name) Help", #selector(showHelp))
        helpEntry.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(helpEntry)
        menu.addItem(item("Settings…", #selector(showSettings), key: ",").showIcon("gearshape"))
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)).showIcon("arrow.down.circle"))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)).showIcon("arrow.down.circle"))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)).showIcon("arrow.down.circle"))
        }
        menu.addItem(item("About \(AppInfo.name)", #selector(showAbout)))
        menu.addItem(item("Our other apps…", #selector(showOtherApps)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit \(AppInfo.name)", #selector(quit), key: "q"))
    }

    /// The effect toggles; with `icons`, the three main effects get one (the status menu, not the Dock menu).
    private func effectItems(icons: Bool = false) -> [NSMenuItem] {
        let prefs = Preferences.shared
        let entries: [(String, Selector, Bool, HotKey?, String?)] = [
            ("Spotlight", #selector(toggleSpotlight), effects.spotlightOn, prefs.spotlightHotKey, "circle.dashed.inset.filled"),
            ("Click Rings", #selector(toggleClicks), effects.clicksOn, prefs.clicksHotKey, "cursorarrow.click.2"),
            ("Keystrokes", #selector(toggleKeystrokes), effects.keystrokesOn, prefs.keystrokesHotKey, "keyboard"),
            ("Draw Box", #selector(toggleBox), effects.boxOn, prefs.boxHotKey, nil),
            ("Draw Arrow", #selector(toggleArrow), effects.arrowOn, prefs.arrowHotKey, nil),
        ]
        return entries.map { title, action, on, hotKey, symbol in
            let menuItem = item(title, action)
            menuItem.state = on ? .on : .off
            if let shortcut = hotKey?.menuKeyEquivalent {
                menuItem.keyEquivalent = shortcut.key
                menuItem.keyEquivalentModifierMask = shortcut.mask
            }
            if icons, let symbol { menuItem.showIcon(symbol) }
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
