# ClickLens

ClickLens makes your pointer, clicks and keystrokes easy to follow when you present, demo or record your Mac screen. Press a shortcut and the screen dims around a spotlight that follows the pointer. Clicks draw coloured rings, and the keys you press appear on screen.

## Download

**[⬇ Download ClickLens.dmg](https://github.com/smanke-org/ClickLens/releases/latest/download/ClickLens.dmg)**

1. Open the disk image and drag ClickLens to Applications.
2. Open ClickLens. It lives in the menu bar.
3. To show keystrokes, allow ClickLens in System Settings › Privacy & Security › Accessibility. The spotlight and click rings work without it.

Requires macOS 26 or later.

## Features

- **Spotlight** (⌃⌥⌘L): dims every screen except a circle around the pointer. You can set the radius, the soft edge, the dim colour and strength, the zoom animation, and an automatic turn-off.
- **Click rings** (⌃⌥⌘C): a ring for each click, with separate colours for the left, right and other buttons, and double rings for double clicks. Rings can expand as they fade and play an optional click sound. They can show on their own or whenever the spotlight is on.
- **Keystrokes** (⌃⌥⌘K): keys shown at the bottom of the screen. Choose **Everything you type**, or **Key combinations only**, which shows only keys pressed with ⌘ ⌥ ⇧ or ⌃ (such as ⇧⌘K) and keeps ordinary typing private. Font size, background and fade time are adjustable, and you can pick which display it appears on.
- Every shortcut can be changed. An on-screen note can confirm each switch.
- Shows in the menu bar, the Dock, both, or neither. Can open at login and updates itself from GitHub releases.

## Building

```bash
./build_app.sh   # universal binary, Developer ID signed
./install.sh     # copies to /Applications in place and launches
swift test       # ClickLensKit unit tests
./release.sh 1.0.1
```
