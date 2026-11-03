import AppKit
import ClickLensKit

/// Everything an agent can do in ClickLens. Add a command here and the CLI, `help`, and the
/// MCP tools all get it. Each `run` is on the main actor and calls the same code as the menu
/// bar menu, the shortcuts, the clicklens:// actions and the Settings window.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the version, which effects are on (spotlight, click rings, keystrokes, drawing), the keystroke mode, whether Accessibility is allowed (keystrokes need it) and whether settings sync is on.",
                     example: "clicklens status --json", readOnly: true) { _ in
            let effects = Effects.shared
            var result: JSONObject = [
                "app": AppInfo.name, "version": AppInfo.version,
                "spotlight": effects.spotlightOn, "clicks": effects.clicksOn,
                "clickRingsShowing": effects.ringsVisible, "keystrokes": effects.keystrokesOn,
                "keystrokeMode": Preferences.shared.keystrokeFilter.rawValue,
                "drawing": effects.drawingTool.map(name) ?? "none",
                "marksWaitingForEsc": OverlayController.shared.waitingForEscape,
                "accessibilityAllowed": InputMonitor.shared.isTrusted,
                "syncOn": SettingsSync.shared.isEnabled,
            ]
            if AgentSocket.isTestRun { result["testRun"] = true }
            return result
        },

        // MARK: Effects

        AgentCommand(name: "effects list", summary: "List the effects with whether each is on and its shortcut. Returns `effects` (name, on, shortcut).",
                     example: "clicklens effects list --json", readOnly: true) { _ in
            let effects = Effects.shared, prefs = Preferences.shared
            let rows: [(String, Bool, HotKey?)] = [
                ("spotlight", effects.spotlightOn, prefs.spotlightHotKey),
                ("clicks", effects.clicksOn, prefs.clicksHotKey),
                ("keystrokes", effects.keystrokesOn, prefs.keystrokesHotKey),
                ("box", effects.boxOn, prefs.boxHotKey),
                ("arrow", effects.arrowOn, prefs.arrowHotKey),
            ]
            return ["effects": rows.map { ["name": $0.0, "on": $0.1, "shortcut": $0.2?.display ?? ""] as JSONObject }]
        },
        AgentCommand(name: "effects on", summary: "Turn an effect on, as its shortcut or menu item does: spotlight (dims the screen around the pointer), clicks (rings on clicks) or keystrokes (keys shown on screen). Already on reports changed: false.",
                     params: [effectParam],
                     example: "clicklens effects on spotlight --json") { args in
            try set(try effect(args), on: true)
        },
        AgentCommand(name: "effects off", summary: "Turn an effect off: spotlight, clicks, keystrokes, or all (every effect, and drawing too). Already off reports changed: false.",
                     params: [.init(name: "effect", required: true, positional: true, help: "spotlight, clicks, keystrokes or all")],
                     example: "clicklens effects off all --json") { args in
            if try args.required("effect").lowercased() == "all" {
                if let dryRun = dryRun(["wouldTurnOff": "all"]) { return dryRun }
                let effects = Effects.shared
                let changed = effects.anyOn
                if effects.spotlightOn { effects.setSpotlight(false) }
                if effects.clicksOn { effects.toggleClicks() }
                if effects.keystrokesOn { effects.toggleKeystrokes() }
                if effects.drawingTool != nil { effects.setDrawing(nil) }
                return ["effect": "all", "on": false, "changed": changed]
            }
            return try set(try effect(args), on: false)
        },
        AgentCommand(name: "effects toggle", summary: "Switch an effect to the other state, as clicklens://spotlight and the shortcuts do: spotlight, clicks or keystrokes.",
                     params: [effectParam],
                     example: "clicklens effects toggle clicks --json") { args in
            let effect = try effect(args)
            return try set(effect, on: !isOn(effect))
        },

        // MARK: Drawing

        AgentCommand(name: "drawing start", summary: "Start drawing a box or an arrow, as ⌃⌥⌘B and ⌃⌥⌘A do: the person then drags on screen to draw it. Ends after one mark unless \"Keep drawing until Esc\" is on.",
                     params: [.init(name: "tool", help: "box (default) or arrow")],
                     example: "clicklens drawing start --tool arrow --json") { args in
            let raw = (args.string("tool") ?? "box").lowercased()
            guard let tool: DrawTool = ["box": .box, "arrow": .arrow][raw] else {
                throw AgentError.usage("--tool must be box or arrow, not \"\(raw)\"")
            }
            if let dryRun = dryRun(["wouldStartDrawing": raw]) { return dryRun }
            let changed = Effects.shared.drawingTool != tool
            Effects.shared.setDrawing(tool)
            return ["drawing": raw, "changed": changed]
        },
        AgentCommand(name: "drawing stop", summary: "Stop drawing, as Esc does while drawing. Boxes and arrows already drawn stay until they fade.",
                     example: "clicklens drawing stop --json") { _ in
            if let dryRun = dryRun(["wouldStopDrawing": true]) { return dryRun }
            let changed = Effects.shared.drawingTool != nil
            Effects.shared.setDrawing(nil)
            return ["drawing": "none", "changed": changed]
        },
        AgentCommand(name: "drawing clear", summary: "Remove every box and arrow on screen at once, including ones waiting for Esc. Drawing mode stays as it is.",
                     example: "clicklens drawing clear --json") { _ in
            if let dryRun = dryRun(["wouldClearMarks": true]) { return dryRun }
            OverlayController.shared.clearMarks()
            return ["cleared": true]
        },

        // MARK: Keystrokes

        AgentCommand(name: "keystrokes mode", summary: "Choose which keys the keystroke display shows: all (everything typed) or combos (only keys pressed with ⌘ ⌥ ⇧ or ⌃, so ordinary typing stays private). `status` shows the current mode.",
                     params: [.init(name: "mode", required: true, positional: true, help: "all or combos")],
                     example: "clicklens keystrokes mode combos --json") { args in
            let raw = try args.required("mode").lowercased()
            guard let mode = KeystrokeFilter(rawValue: raw) else { throw AgentError.usage("the mode is all or combos, not \"\(raw)\"") }
            let prefs = Preferences.shared
            let changed = prefs.keystrokeFilter != mode
            prefs.keystrokeFilter = mode
            return ["keystrokeMode": mode.rawValue, "title": mode.title, "changed": changed]
        },

        // MARK: Settings

        AgentCommand(name: "settings list", summary: "List the settings an agent can change, as the Settings window shows them. Returns `settings` (key, tab, label, value, type, and range or choices). Colors are #RRGGBB or #RRGGBBAA.",
                     params: [.init(name: "tab", help: "only this Settings tab: General, Spotlight, Clicks, Keystrokes, Box or Arrow")],
                     example: "clicklens settings list --tab Spotlight --json", readOnly: true) { args in
            var list = settings
            if let tab = args.string("tab") {
                list = list.filter { $0.tab.caseInsensitiveCompare(tab) == .orderedSame }
                guard !list.isEmpty else { throw AgentError.notFound("no Settings tab \"\(tab)\". The tabs: \(tabs.joined(separator: ", "))") }
            }
            let prefs = Preferences.shared
            return ["settings": list.map { $0.describe(prefs) }]
        },
        AgentCommand(name: "settings set", summary: "Change one setting, as its control in Settings does. Numbers are checked against the slider's range; colors take #RRGGBB (keeps the opacity) or #RRGGBBAA.",
                     params: [.init(name: "key", required: true, positional: true, help: "the setting's key, from `clicklens settings list`"),
                              .init(name: "value", required: true, positional: true, help: "the new value: a number, true or false, one of the choices, or a color")],
                     example: "clicklens settings set spotlightRadius 200 --json") { args in
            let key = try args.required("key")
            guard let setting = settings.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw AgentError.notFound("no setting \"\(key)\". Run `clicklens settings list`")
            }
            let prefs = Preferences.shared
            let before = setting.describe(prefs)["value"].map { "\($0)" }
            try setting.apply(try args.required("value"), to: prefs)
            var result = setting.describe(prefs)
            result["changed"] = before != result["value"].map { "\($0)" }
            return result
        },
        AgentCommand(name: "settings reset", summary: "Put every setting back to how a new install starts, as Reset to Defaults… in Settings does: shortcuts, colors, sizes and modes. Where ClickLens appears, login and updates stay. Without --yes it only shows what it would do.",
                     example: "clicklens settings reset --yes --json", destructive: true) { args in
            guard args.confirmed else {
                return ["wouldReset": Preferences.keys.count,
                        "hint": "add --yes to reset every shortcut, color, size and mode to its default. With sync on, your other Macs get the defaults too"]
            }
            Preferences.shared.resetToDefaults()
            // As the Settings button does. A test copy registers no shortcuts.
            if !AgentSocket.isTestRun { HotKeyCenter.shared.apply() }
            return ["reset": true]
        },
        AgentCommand(name: "settings open", summary: "Show the Settings window in front, on a tab if one is given.",
                     params: [.init(name: "tab", help: "General, Spotlight, Clicks, Keystrokes, Box or Arrow")],
                     example: "clicklens settings open --tab Keystrokes --json") { args in
            var tab: String?
            if let raw = args.string("tab") {
                guard let match = tabs.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) else {
                    throw AgentError.notFound("no Settings tab \"\(raw)\". The tabs: \(tabs.joined(separator: ", "))")
                }
                tab = match
            }
            if let dryRun = dryRun(["wouldOpen": tab ?? "Settings"]) { return dryRun }
            if let tab { SettingsWindow.shared.show(tab: tab) } else { SettingsWindow.shared.show() }
            return ["opened": tab ?? "Settings"]
        },
    ]

    // MARK: - Effects

    private enum Effect: String { case spotlight, clicks, keystrokes }

    private static let effectParam = AgentCommand.Param(name: "effect", required: true, positional: true,
                                                        help: "spotlight, clicks or keystrokes")

    private static func effect(_ args: Args) throws -> Effect {
        let raw = try args.required("effect").lowercased()
        guard let effect = Effect(rawValue: raw) else {
            throw AgentError.usage("the effect is spotlight, clicks or keystrokes, not \"\(raw)\". Boxes and arrows: `clicklens drawing start`")
        }
        return effect
    }

    @MainActor private static func isOn(_ effect: Effect) -> Bool {
        let effects = Effects.shared
        switch effect {
        case .spotlight: return effects.spotlightOn
        case .clicks: return effects.clicksOn
        case .keystrokes: return effects.keystrokesOn
        }
    }

    /// Switches through the same calls as the shortcuts, so the announcement, the menu bar icon
    /// and ToolHUD's lights all follow.
    @MainActor private static func set(_ effect: Effect, on: Bool) throws -> JSONObject {
        if let dryRun = dryRun(["wouldTurn": on ? "on" : "off", "effect": effect.rawValue]) { return dryRun }
        let changed = isOn(effect) != on
        if changed {
            let effects = Effects.shared
            switch effect {
            case .spotlight: effects.setSpotlight(on)
            case .clicks: effects.toggleClicks()
            case .keystrokes: effects.toggleKeystrokes()
            }
        }
        var result: JSONObject = ["effect": effect.rawValue, "on": isOn(effect), "changed": changed]
        if effect == .keystrokes, on, !InputMonitor.shared.isTrusted {
            result["note"] = "keystrokes need Accessibility: ask the person to allow ClickLens in System Settings › Privacy & Security › Accessibility"
        }
        return result
    }

    private static func name(_ tool: DrawTool) -> String { tool == .box ? "box" : "arrow" }

    /// A Debug test copy (APP_STORE) never draws over the person's real screen, announces, or
    /// opens windows: commands that would only report what they would do.
    @MainActor private static func dryRun(_ would: JSONObject) -> JSONObject? {
        guard AgentSocket.isTestRun else { return nil }
        var result = would
        result["testRun"] = true
        result["changed"] = false
        return result
    }

    // MARK: - Settings

    private static let tabs = ["General", "Spotlight", "Clicks", "Keystrokes", "Box", "Arrow"]

    /// The settings the Settings window shows, with the same ranges as its sliders. Shortcuts,
    /// the keystroke screen, where the app appears, login, sync and updates are left to the window.
    @MainActor private static let settings: [AgentSetting] = [
        .init("announceToggles", "General", "Announce when an effect turns on or off", .bool(\.announceToggles)),
        .init("confirmQuit", "General", "Ask before quitting", .bool(\.confirmQuit)),

        .init("spotlightAutoOff", "Spotlight", "Turn off automatically", .bool(\.spotlightAutoOff)),
        .init("spotlightAutoOffSeconds", "Spotlight", "After (seconds)", .number(\.spotlightAutoOffSeconds, 2...120, step: 1)),
        .init("spotlightRadius", "Spotlight", "Circle radius (points)", .number(\.spotlightRadius, 40...500, step: 1)),
        .init("spotlightSoftness", "Spotlight", "Soft edge (0 to 0.9 of the radius)", .number(\.spotlightSoftness, 0...0.9, step: nil)),
        .init("spotlightDimming", "Spotlight", "Dimming (0.05 to 0.95)", .number(\.dimColor.alpha, 0.05...0.95, step: nil)),
        .init("dimColor", "Spotlight", "Dim color", .color(\.dimColor, opacity: false)),
        .init("spotlightAnimates", "Spotlight", "Zoom in and out", .bool(\.spotlightAnimates)),
        .init("spotlightAnimationDuration", "Spotlight", "Zoom duration (seconds)", .number(\.spotlightAnimationDuration, 0.1...1.5, step: nil)),

        .init("clicksWithSpotlight", "Clicks", "Show rings whenever the spotlight is on", .bool(\.clicksWithSpotlight)),
        .init("clickRadius", "Clicks", "Radius (points)", .number(\.clickRadius, 10...80, step: nil)),
        .init("clickExpands", "Clicks", "Expand as they fade", .bool(\.clickExpands)),
        .init("clickFadeDuration", "Clicks", "Fade time (seconds)", .number(\.clickFadeDuration, 0.1...1.5, step: nil)),
        .init("leftClickColor", "Clicks", "Left button", .color(\.leftClickColor, opacity: true)),
        .init("rightClickColor", "Clicks", "Right button", .color(\.rightClickColor, opacity: true)),
        .init("otherClickColor", "Clicks", "Other buttons", .color(\.otherClickColor, opacity: true)),
        .init("clickSound", "Clicks", "Play a click sound", .bool(\.clickSound)),
        .init("clickVolume", "Clicks", "Volume (0 to 1)", .number(\.clickVolume, 0...1, step: nil)),

        .init("keystrokeFilter", "Keystrokes", "Show", .choice(\.keystrokeFilter)),
        .init("ignoreOwnHotKeys", "Keystrokes", "Hide ClickLens's own shortcuts", .bool(\.ignoreOwnHotKeys)),
        .init("keystrokeFontSize", "Keystrokes", "Font size (points)", .number(\.keystrokeFontSize, 14...96, step: 1)),
        .init("keystrokeFadeSeconds", "Keystrokes", "Fade after (seconds)", .number(\.keystrokeFadeSeconds, 0.5...6, step: nil)),
        .init("keystrokeBackground", "Keystrokes", "Background", .color(\.keystrokeBackground, opacity: true)),

        .init("boxKeepDrawing", "Box", "Keep drawing until Esc", .bool(\.boxKeepDrawing)),
        .init("boxColor", "Box", "Line color", .color(\.boxColor, opacity: true)),
        .init("boxThickness", "Box", "Thickness (points)", .number(\.boxThickness, 1...20, step: 1)),
        .init("boxDismissal", "Box", "Fade out: afterTime, onEscape or both (whichever comes first)", .choice(\.boxDismissal)),
        .init("boxFadeAfter", "Box", "Fade after (seconds)", .number(\.boxFadeAfter, 0.5...30, step: 0.5)),

        .init("arrowClickIsTip", "Arrow", "Your click marks what the arrow points at (false: where it starts)", .bool(\.arrowClickIsTip)),
        .init("arrowKeepDrawing", "Arrow", "Keep drawing until Esc", .bool(\.arrowKeepDrawing)),
        .init("arrowShape", "Arrow", "Shape", .choice(\.arrowShape)),
        .init("arrowColor", "Arrow", "Color", .color(\.arrowColor, opacity: true)),
        .init("arrowThickness", "Arrow", "Thickness (points)", .number(\.arrowThickness, 1...20, step: 1)),
        .init("arrowDismissal", "Arrow", "Fade out: afterTime, onEscape or both (whichever comes first)", .choice(\.arrowDismissal)),
        .init("arrowFadeAfter", "Arrow", "Fade after (seconds)", .number(\.arrowFadeAfter, 0.5...30, step: 0.5)),
    ]
}

/// One setting from the Settings window: how to read it, check a new value, and write it
/// through Preferences (which saves it and tells settings sync).
@MainActor
struct AgentSetting {
    enum Kind {
        case bool(ReferenceWritableKeyPath<Preferences, Bool>)
        case number(ReferenceWritableKeyPath<Preferences, Double>, ClosedRange<Double>, step: Double?)
        case color(ReferenceWritableKeyPath<Preferences, RGBA>, opacity: Bool)
        case choice(get: (Preferences) -> String, set: (Preferences, String) -> Bool, options: [String])

        static func choice<E: RawRepresentable & CaseIterable>(_ path: ReferenceWritableKeyPath<Preferences, E>) -> Kind
            where E.RawValue == String {
            .choice(get: { $0[keyPath: path].rawValue },
                    set: { prefs, raw in
                        guard let value = E.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }) else { return false }
                        prefs[keyPath: path] = value
                        return true
                    },
                    options: E.allCases.map(\.rawValue))
        }
    }

    let key: String
    let tab: String
    let label: String
    let kind: Kind

    init(_ key: String, _ tab: String, _ label: String, _ kind: Kind) {
        self.key = key; self.tab = tab; self.label = label; self.kind = kind
    }

    func describe(_ prefs: Preferences) -> JSONObject {
        var result: JSONObject = ["key": key, "tab": tab, "label": label]
        switch kind {
        case .bool(let path):
            result["type"] = "boolean"
            result["value"] = prefs[keyPath: path]
        case .number(let path, let range, let step):
            result["type"] = "number"
            result["value"] = (prefs[keyPath: path] * 1000).rounded() / 1000
            result["min"] = range.lowerBound
            result["max"] = range.upperBound
            if let step { result["step"] = step }
        case .color(let path, let opacity):
            result["type"] = "color"
            result["value"] = Self.hex(prefs[keyPath: path], opacity: opacity)
        case .choice(let get, _, let options):
            result["type"] = "choice"
            result["value"] = get(prefs)
            result["choices"] = options
        }
        return result
    }

    func apply(_ raw: String, to prefs: Preferences) throws {
        switch kind {
        case .bool(let path):
            switch raw.lowercased() {
            case "true", "yes", "on", "1": prefs[keyPath: path] = true
            case "false", "no", "off", "0": prefs[keyPath: path] = false
            default: throw AgentError.usage("\(key) is true or false, not \"\(raw)\"")
            }
        case .number(let path, let range, let step):
            guard let number = Double(raw), number.isFinite else { throw AgentError.usage("\(key) is a number, not \"\(raw)\"") }
            guard range.contains(number) else {
                throw AgentError.invalid("\(key) goes from \(Self.format(range.lowerBound)) to \(Self.format(range.upperBound)), as in Settings; \(raw) is outside that")
            }
            // Rounded to the slider's step, as the slider does.
            prefs[keyPath: path] = step.map { (number / $0).rounded() * $0 } ?? number
        case .color(let path, let opacity):
            guard let color = Self.color(raw, keeping: prefs[keyPath: path], opacity: opacity) else {
                throw AgentError.usage("\(key) is a color like #FF3B30" + (opacity ? " or #FF3B30CC (with opacity)" : "") + ", not \"\(raw)\"")
            }
            prefs[keyPath: path] = color
        case .choice(_, let set, let options):
            guard set(prefs, raw) else { throw AgentError.usage("\(key) is one of \(options.joined(separator: ", ")), not \"\(raw)\"") }
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    static func hex(_ color: RGBA, opacity: Bool) -> String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + byte(color.red) + byte(color.green) + byte(color.blue) + (opacity ? byte(color.alpha) : "")
    }

    /// #RRGGBB keeps the current opacity; #RRGGBBAA sets it too, where the setting has one.
    static func color(_ raw: String, keeping current: RGBA, opacity: Bool) -> RGBA? {
        var digits = raw.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || (opacity && digits.count == 8), let value = UInt64(digits, radix: 16) else { return nil }
        let parts = digits.count == 8
            ? [(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
            : [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
        let unit = parts.map { Double($0) / 255 }
        return RGBA(unit[0], unit[1], unit[2], unit.count == 4 ? unit[3] : current.alpha)
    }
}
