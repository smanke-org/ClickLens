---
name: clicklens
description: Drive ClickLens, the presenter app on this Mac, from the shell with the `clicklens` command: see which effects are on, turn the spotlight, click rings and keystroke display on or off, start or clear on-screen boxes and arrows, choose the keystroke mode, and read or change its settings. Use when the user is presenting or recording and wants an effect switched, asks about ClickLens settings, or names ClickLens.
---

# ClickLens

`clicklens` runs commands in the ClickLens app, through the same code as its shortcuts and menus.
If the app is closed, the command opens it in the background. If `clicklens` isn't on PATH, use
`/Applications/ClickLens.app/Contents/MacOS/ClickLens` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- Effects draw over the person's whole screen (the spotlight dims everything else). Only switch
  one on when they asked, and turn it off again when they're done (`clicklens effects off all`).
- `drawing start` waits for the person to drag on screen; it doesn't draw anything by itself.
- Keystrokes need Accessibility. If a result has a `note` about it, tell the person; never try
  to change privacy settings yourself.
- `settings reset` only reports what it would do. Ask before you run it again with `--yes`:
  with sync on, it resets the person's other Macs too.
- Find setting keys with `clicklens settings list [--tab Spotlight]`. Colors are #RRGGBB or #RRGGBBAA.
- To try something without real settings, run a Debug build with `APP_STORE=/tmp/clicklens-test`
  in front. A test copy never draws: effect, drawing and window commands only say what they'd do.

## Main commands

| Command | Does |
| --- | --- |
| `clicklens status --json` | Version, which effects are on, keystroke mode, Accessibility, sync |
| `clicklens effects on\|off\|toggle <spotlight\|clicks\|keystrokes> --json` | Switch an effect (`effects off all` ends everything) |
| `clicklens drawing start [--tool box\|arrow] --json` / `drawing stop` / `drawing clear` | Boxes and arrows |
| `clicklens keystrokes mode <all\|combos> --json` | Show every key, or only key combinations |
| `clicklens settings list [--tab T] --json` / `settings set <key> <value> --json` | Read or change a setting |

Everything else: `clicklens help`, and `clicklens help <command>` for its options.
