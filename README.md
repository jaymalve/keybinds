<div align="center">
  <img src="assets/icon.svg" alt="Keybinds" width="88" />
  <h1>Keybinds</h1>
  <p><strong>Everything on your Mac. A keystroke away.</strong></p>
  <p>A command palette for your whole Mac.<br />Jump to any app, window, tab or file, and click any button, all without the mouse.</p>
  <p><a href="https://keybinds.app">keybinds.app</a> · <a href="https://github.com/jaymalve/keybinds/releases/latest/download/Keybinds.dmg">Download for macOS</a></p>
</div>

## Why Keybinds

- **One key to everything.** Tap ⌥ and search open apps, windows, browser and Terminal tabs, and files. Apps that aren't running launch from the same search.
- **Tabs, not just windows.** Jumps straight to a tab in Chrome, Brave, Edge, Vivaldi, Safari or Terminal, and folds duplicate copies of a page into one row.
- **Click without the mouse.** Hold ⌥ and type part of a button's name. Let go to click the best match, or press its number.
- **Tidy up from the keyboard.** Close a tab or window, close every duplicate tab, or quit an app without leaving the palette.
- **Local and private.** No account and no analytics. It only goes online to fetch tab icons from the sites themselves.

## Install

Download [Keybinds.dmg](https://github.com/jaymalve/keybinds/releases/latest/download/Keybinds.dmg) and drag Keybinds into Applications.

This beta isn't notarized yet, so macOS blocks it the first time you open it. Go to **System Settings → Privacy & Security**, click **Open Anyway** next to the Keybinds message, then open it again. Grant **Accessibility** access when asked: Keybinds needs it to see windows and keys.

Requires a Mac with Apple silicon on macOS 14 or later.

## Use

**Tap ⌥** to open or close the palette, then type.

| Key | Does |
| --- | --- |
| `↩` | Open the selected item |
| `⌘↩` | Show a file in Finder |
| `⌘⌫` | Close the tab or window, or move a file to the Trash |
| `⌘⇧⌫` | Close every duplicate tab, keeping the newest copy |
| `⌘Q` | Quit the app |
| `t` `w` `a` `f` then space | Search only tabs, windows, apps or files |
| `⇥` | Switch to click mode |

**Hold ⌥** in any app for click mode. Type to narrow the matches, then let go of ⌥ or press `↩` to click the ringed one, or press its number. `⇥` moves the ring. Space with nothing typed puts a letter label on everything. Add `⌘` for a ⌘-click or `⇧` for a right-click.

Shortcuts, the hold key and tab sources can be changed in Settings, from the menu bar icon.

## Build from source

Needs Apple's Command Line Tools with Swift 6.2. Xcode isn't required.

```sh
scripts/make-dev-cert.sh          # once: a local signing identity, so Accessibility access survives rebuilds
scripts/bundle.sh --run           # build build/Keybinds.app and launch it (add `release` for an optimized build)
swift run KeybindsCoreTests       # tests
```

The landing page lives in `site/`, a Next.js app: `cd site && pnpm install && pnpm dev`.
