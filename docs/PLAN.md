# Keybinds — Plan

A keyboard-driven switcher for macOS that jumps to **any app, any window, any browser tab, any terminal tab**. Think Cmd+K for the entire Mac, at the granularity of individual tabs.

Status: planning. No code yet.

---

## 1. Goals & scope

### Decisions so far
| Topic | Decision |
|---|---|
| Interaction | **Both** a search palette and direct bindings. **Palette is the MVP**; bindings come right after. |
| Coverage | Every Mac app and window is jumpable. Deep (sub-window) support focuses on **browser tabs** and **terminal tabs/windows**. |
| Audience | Personal tool now, open source later. Optimize for speed of iteration, but keep code clean enough to publish. |
| Stack | Native Swift (AppKit + SwiftUI). |
| Palette hotkey | **Double-tap Shift** by default. `⌘K` (with per-app exclusions) or any recorded combo is available as an alternative; see §3.6. |
| Empty query | Shows **recent targets** (frecency). |
| Favicons | **Yes**, sourced locally first (see §3.8). |
| Close/quit from palette | **Yes** (see §2 Actions). |

### Target apps (from what's installed on this machine)
- Browsers: **Google Chrome**, **Brave**, **Safari**
- Terminal: **Terminal.app**
- Everything else (Cursor, Codex, T3 Code, …) gets **window-level** support through the Accessibility API.

### Non-goals (for MVP)
- App Store distribution (impossible anyway: Accessibility needs a non-sandboxed app).
- Firefox, Arc, iTerm, Ghostty, and deep links like Slack channels or Notion pages. These come later as providers.
- Tab management beyond close/quit (moving, deduping, grouping).
- Launching apps that aren't running. Nice to have; see M4.

### Success criteria
- Hotkey → palette visible in **< 50 ms**, every time.
- Typing → results update in **< 16 ms** (one frame) for ~1,000 targets.
- Enter → the target is frontmost and focused in **< 300 ms**, including tabs in background windows.
- The palette never launches an app as a side effect and never blocks on a hung app.

---

## 2. User experience

### Palette (MVP)
1. Double-tap Shift (or the configured alternative hotkey). Double-tapping Shift again while the palette is open closes it.
2. A floating panel appears centered on the active screen, with the search field focused.
3. With an empty query it shows **recent targets** (frecency-ranked), which makes it double as a smart Cmd+Tab.
4. Typing fuzzy-matches across all targets.
5. `↑/↓` or `⌃N/⌃P` move the selection, `Enter` jumps to the target, `Esc` closes the panel.

Row layout: `[favicon or app icon] Title ............ [kind badge]`, with a secondary line for the URL host, the app name, or the terminal's process/cwd.

Optional scope prefixes (cheap to add, keeps power use fast):
- `t ` → tabs only, `w ` → windows only, `a ` → apps only. These can be revisited.

The panel is an `NSPanel` with `.nonactivatingPanel`, so it takes key focus without deactivating the frontmost app. That makes closing it with `Esc` feel instant and lossless.

### Actions on the selected row (M5)
| Key | Tab | Window | App |
|---|---|---|---|
| `Enter` | Jump | Jump | Activate |
| `⌘W` | Close tab | Close window | Close the frontmost window |
| `⌘Q` | — | — | Quit app |
| `⌘Enter` | Bind to shortcut | Bind to shortcut | Bind to shortcut |

After an action the palette **stays open**, the row disappears, and the selection moves to the next row. That lets you close several tabs in a row quickly. Implementation:
- Chrome/Brave: `close tab id X of window id Y`. Safari: `close tab i of window id w` (re-verify the URL first).
- Windows: press the AX close button (`kAXCloseButtonAttribute`).
- Apps: `NSRunningApplication.terminate()`.
- Terminal tabs: the scripting dictionary has no close-tab command. Plan: select the tab and close it through the AX close button / menu item. If a process is still running, Terminal shows its own confirmation, which is fine. Checked in spike M0.4.

### Direct bindings (M5)
- In the palette, `⌘Enter` on a row → "Bind to shortcut…" → record a key combo.
- A binding stores a **rule**, not a raw ID (tab IDs don't survive restarts). Example:
  `⌥1 → tab where host == "mail.google.com" in Chrome; if none, open https://mail.google.com`
- Pressing the shortcut runs the rule against the live index. Exactly one match → jump. Several matches → most recent wins, and pressing again cycles. No match → run the fallback (open the URL or launch the app).
- Bindings are also editable in Settings.

### Menu bar
- A menu-bar icon (no Dock icon, `LSUIElement`) with: Open palette, Settings…, Permissions status, Quit.

---

## 3. Technical design

### 3.1 Module layout (SwiftPM)
```
Package.swift
Sources/
  KeybindsCore/          # pure logic, unit-testable, no UI
    Model/               # Target, TargetKind, Locator, Binding, Rule
    Providers/           # AppsProvider, WindowsProvider, ChromiumTabsProvider,
                         # SafariTabsProvider, TerminalProvider
    Index/               # TargetIndex (cache + merge + change events)
    Search/              # FuzzyMatcher, Ranker (frecency)
    Activation/          # Activator (dispatches to provider)
    Input/               # DoubleTapDetector (pure state machine, no AppKit)
    System/              # AX helpers, AppleScript runner, permissions
    Persistence/         # JSON store (history, bindings, settings)
  KeybindsApp/           # AppKit/SwiftUI shell
    AppDelegate, MenuBar, PalettePanel, PaletteView,
    SettingsView, Onboarding, HotkeyManager
Tests/
  KeybindsCoreTests/     # matcher, ranker, rule matching, AppleScript output parsing
scripts/
  bundle.sh              # swift build → Keybinds.app (Info.plist, icon, codesign)
```
**Build tooling note:** this machine has only the Command Line Tools (Swift 6.2), not Xcode. The plan uses **SwiftPM plus a small `bundle.sh`** that assembles the `.app`, which works without Xcode. Installing Xcode later only adds SwiftUI previews and Instruments, which are nice but not required.

### 3.2 Core model
```swift
enum TargetKind { case app, window, browserTab, terminalTab }

struct Target: Identifiable, Hashable {
    let id: TargetID            // stable within a session (see below)
    let kind: TargetKind
    let title: String
    let subtitle: String?       // URL host, app name, cwd…
    let url: URL?               // browser tabs
    let bundleID: String
    let pid: pid_t
    let locator: Locator        // everything needed to activate it
}

enum Locator {
    case app(pid: pid_t)
    case window(pid: pid_t, windowNumber: CGWindowID?, axTitle: String, axIndex: Int)
    case chromiumTab(bundleID: String, windowID: Int, tabID: Int)      // Chrome/Brave have stable ids
    case safariTab(windowID: Int, tabIndex: Int, url: URL?)            // no tab ids → index + URL check
    case terminalTab(windowID: Int, tabIndex: Int, tty: String)        // tty is stable for the tab's life
}
```

### 3.3 Providers
```swift
protocol TargetProvider: Sendable {
    var name: String { get }
    func snapshot() async throws -> [Target]          // must be fast, cancellable
    func activate(_ locator: Locator) async throws
    var changeSignals: AsyncStream<Void> { get }      // hints that a refresh is worthwhile
}
```

| Provider | Enumerate | Activate | Notes |
|---|---|---|---|
| **Apps** | `NSWorkspace.runningApplications` (regular activation policy only) | `NSRunningApplication.activate()` | Trivial. |
| **Windows** | AX: `kAXWindowsAttribute` per app, read title, minimized, main. Map to `CGWindowID` with `_AXUIElementGetWindow` (private but widely used). | Unminimize if needed → `AXRaise` → set `kAXMainAttribute` → activate the app | Needs Accessibility only. **No Screen Recording** needed because titles come from AX, not `CGWindowList`. |
| **Chromium tabs** (Chrome, Brave) | One AppleScript per browser: `{id, title, URL}` of every tab of every window, returned in **one** batched Apple Event | `set active tab index` → `set index of window to 1` → activate → AX-raise the matching window | Chrome and Brave share the same scripting dictionary, so one provider is parameterized by bundle ID. |
| **Safari tabs** | One AppleScript: `{name, URL}` of tabs of windows | `set current tab of window w to tab i` → raise the window | Safari tabs have no IDs. Verify that the URL still matches before activating, and re-scan once if it doesn't. |
| **Terminal tabs** | AppleScript: for each window/tab get `tty`, `custom title`, `processes`, `selected` | `set selected of tab i of window w to true` → `set index of window w to 1` → activate | Label: custom title, else the foreground process + cwd. Derive cwd from the tty's foreground PID with `proc_pidinfo` (libproc). Needs a spike. |

When a target is covered by a deeper provider, its window-level entries are suppressed. For example, a Chrome window isn't listed separately; its tabs are. A window that has only one tab can collapse into a single row.

**Critical gotcha:** `tell application "X"` **launches X** if it isn't running. The AppleScript runner must check `NSRunningApplication` first and skip apps that aren't running.

### 3.4 Index & freshness
Opening the palette must not wait on AppleScript, so we use **stale-while-revalidate**:

- `TargetIndex` (an actor) holds the last snapshot from each provider.
- **Opening the palette** shows the cached index immediately, then fires a refresh of every provider in parallel. Each provider has its own timeout (~500 ms). Results merge into the list live, and the selection stays stable.
- **Background refresh** is triggered by `NSWorkspace` notifications (app launched/terminated/activated) and by AX observers (`kAXWindowCreated`, `kAXUIElementDestroyed`, `kAXTitleChanged`, `kAXFocusedWindowChanged`). Changes are debounced at ~250 ms.
- **Browsers and Terminal can't push changes**, so they refresh on palette open and when their app deactivates. That is the moment the user is most likely to have just changed tabs.
- AppleScript calls run on a **per-app serial queue**, so a hung app never blocks other providers.

### 3.5 Search & ranking
- **Fuzzy matcher:** fzf-style subsequence scoring with bonuses for word starts, camelCase, consecutive runs and prefix matches. It searches `title`, URL host/path and app name with field weights (title > host > app). We write it ourselves (~200 lines) with heavy unit tests.
- **Frecency:** record every activation as `(rule-ish key, timestamp)`. The key is the tab URL, terminal tty+title, or window title+bundle ID, so history survives ID churn. Score = Σ exp-decay(age). The final rank blends match score and frecency.
- Empty query → frecency only, with the target you're currently on pushed to the bottom, so `Enter` behaves like "go back" (same as Cmd+Tab).

### 3.6 Hotkeys
Two mechanisms, both owned by `HotkeyManager`:

**A. Double-tap Shift (default palette trigger)**
- Carbon hotkeys can't express "modifier tapped twice", so we use a **listen-only** `NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown])`. It needs Accessibility, which we already require, and it never blocks or swallows events.
- A matching `addLocalMonitorForEvents` handles the double tap while the palette is key, which closes the palette.
- **Detector** (a small pure state machine in `KeybindsCore`, unit-tested with synthetic event sequences). A double tap fires only when all of these hold:
  - Each tap is a **pure Shift**: Shift down → Shift up with no `keyDown` and no other modifier in between.
  - Each hold is **< ~200 ms**.
  - The gap between the first release and the second press is **< ~300 ms**, with no keys pressed in between.
  - Left or right Shift both count, and the two taps can mix sides.
- Typing capitals ("Hello", "I'M", "THE") never qualifies, because a letter is pressed while Shift is held.
- Thresholds live in settings and get tuned during spike M0.6.
- Known limitation: macOS hides key events from other apps while secure input is on (password fields), so the double tap doesn't fire there. That's acceptable.

**B. Key combos (alternative palette hotkey + all direct bindings)**
- Use **[sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)** (MIT, SwiftPM). It wraps Carbon `RegisterEventHotKey` and includes a recorder UI. It needs no special permission and handles conflicts.
- Binding hotkeys are registered dynamically from `bindings.json`.
- Settings offers the palette trigger as **"Double Shift" (preset)**, **a recorded combo**, or both.
- **If you pick `⌘K`:** a global combo takes `⌘K` away from *every* app. Apps that use it include Terminal (clear scrollback), Cursor/VS Code (chord prefix and inline edit), Chrome (search from the address bar), and Slack/Notion/Linear. Mitigation: a **per-app exclusion list**. While an excluded app is frontmost, the combo is **unregistered** (driven by the `didActivateApplication` notification), so `⌘K` reaches that app normally.

### 3.7 Persistence
JSON files in `~/Library/Application Support/Keybinds/`: `settings.json`, `bindings.json`, `history.json` (history capped at ~2k entries). The data is small, so SQLite isn't needed.

### 3.8 Favicons
Browsers' scripting interfaces don't expose favicons, so we source them ourselves. Rules: **local-first, and no third-party favicon services** (e.g. Google s2), so browsing hosts never leave the machine.

1. **Chrome/Brave (local):** read each profile's `Favicons` SQLite DB (e.g. `~/Library/Application Support/Google/Chrome/<Profile>/Favicons`). Join `icon_mapping` (page URL) → `favicon_bitmaps`. The browser holds a lock on the file, so open it read-only with `?immutable=1` or work on a copy. Use the system `SQLite3` module; no dependency is needed. This also covers intranet and logged-in pages.
2. **Safari:** its favicon cache lives behind Full Disk Access, which we don't want to require. Use fallback 3.
3. **Fallback (network, direct to the site):** fetch `https://<host>/`, parse `<link rel="icon">`, otherwise try `/favicon.ico`. This only contacts hosts the user already has open. Uses a short timeout and no cookies.
4. **Cache:** `~/Library/Application Support/Keybinds/favicons/<host>.png` stores 32px PNGs, refreshed weekly. Rows show the browser icon until the favicon is ready, then swap it in without changing the layout.

Scheduled in M4; a quick check of the Chromium DB schema is part of spike M0.1.

### 3.9 Permissions & signing
| Permission | Why | How |
|---|---|---|
| Accessibility | Enumerating and raising windows; AX observers | `AXIsProcessTrustedWithOptions` with the prompt; poll until granted |
| Automation (per app) | AppleScript for Chrome, Brave, Safari, Terminal | `NSAppleEventsUsageDescription` in Info.plist; check with `AEDeterminePermissionToAutomateTarget`; prompt lazily the first time each app is seen |
| Screen Recording | **Not needed** (avoided by design) | — |

- The app is **not sandboxed** and has no hardened-runtime restrictions on Apple Events beyond the `com.apple.security.automation.apple-events` entitlement.
- **Dev gotcha:** macOS ties TCC grants to the code signature. An ad-hoc signed rebuild **loses Accessibility permission on every build**. Fix: create a stable self-signed "Keybinds Dev" code-signing certificate in Keychain and sign every build with it from `bundle.sh`.
- Onboarding is a small window listing each permission with a live status and a "Grant" button. The palette still works partially without the permissions; apps are always available.

---

## 4. Milestones

### M0 — Feasibility spikes (do first, throwaway code)
Each spike answers one question with numbers:
1. **AppleScript latency:** time to enumerate Chrome, Brave and Safari with 100+ tabs across 5+ windows (batched vs. per-tab). Target < 150 ms per browser. Also confirm we can read the Chromium `Favicons` DB while the browser is running.
2. **Windows across Spaces / fullscreen / minimized:** what AX returns for each case, and whether `AXRaise` + activate switches to the right Space.
3. **Tab activation in a background window on another Space:** does the correct window come forward in Chrome and Safari?
4. **Terminal tabs:** can we get a useful label (process + cwd) from the tty quickly? Can we close a specific tab?
5. **Signing:** confirm the self-signed cert keeps TCC grants across rebuilds.
6. **Double-tap Shift:** log real `flagsChanged`/`keyDown` streams while typing normally for a few minutes, then replay them through the detector. Target: **zero false triggers**, and deliberate double taps detected reliably. Tune the hold and gap thresholds from this data. Also measure the hotkey-to-panel latency through the global monitor.

Exit: a short write-up in `docs/spikes.md`, plus any design changes reflected here.

### M1 — Skeleton
SwiftPM package, `bundle.sh`, menu-bar agent, double-Shift detector (with tests) and the combo hotkey, empty panel that shows and hides correctly on the active screen, permission onboarding.

### M2 — Apps + windows
Apps and Windows providers, `TargetIndex`, fuzzy matcher (with tests), activation, keyboard navigation in the palette.

### M3 — Tabs
Chromium (Chrome and Brave), Safari and Terminal providers, window de-duplication, stale-while-revalidate refresh, per-app timeouts.

### M4 — Ranking & polish → **MVP**
Frecency history, empty-query "recents", scope prefixes, favicons (§3.8), settings window (palette trigger, double-tap thresholds, combo exclusion list, enabled providers), launching apps that aren't running from `/Applications`.

### M5 — Actions + direct bindings
Close/quit actions (`⌘W`, `⌘Q`) with the palette staying open. Rule model, `⌘Enter` to bind, recorder UI, fallback actions (open URL / launch app), cycling between multiple matches, bindings editor in Settings.

### M6 — Open-source readiness
Developer ID signing + notarization, Sparkle updates, lower deployment target (macOS 14), README/screenshots, license, CI build. More providers: Arc, iTerm, Ghostty, Firefox (WebExtension + native messaging), editor workspaces.

---

## 5. Risks
| Risk | Impact | Mitigation |
|---|---|---|
| AX can't see windows on other Spaces for some apps | Missing windows in results | Spike M0.2. Fall back to the private CGS/remote-token approach AltTab uses, or accept and document the limitation |
| AppleScript is slow with hundreds of tabs | Stale tab lists | Batched queries, caching, refresh on deactivate, per-app timeouts |
| Automation prompts feel intrusive | Onboarding friction | Prompt lazily per app; each provider can be disabled |
| Private APIs (`_AXUIElementGetWindow`) | Could break on OS updates | Keep them isolated in `System/`, with a graceful fallback to title matching |
| Double Shift triggers by accident while typing | Palette pops up unexpectedly | Strict "pure tap" rules, tuned on recorded typing (M0.6); thresholds configurable; a combo fallback is available |
| Double Shift unavailable without Accessibility permission | No palette trigger before onboarding finishes | Onboarding asks for Accessibility first; the menu-bar "Open palette" item always works |
| Global combo (e.g. `⌘K`) shadows in-app shortcuts | Lost app functionality | Only an issue if the user picks one; per-app exclusion list (§3.6) |
| Chromium `Favicons` DB schema changes | Missing favicons | Fall back to network fetch; never fatal |
| Accidental close/quit from the palette | Lost tab or app state | Actions need an explicit modifier (`⌘W`/`⌘Q`); apps still show their own unsaved-changes prompts |

## 6. Open questions
None right now. New questions will come from the M0 spike results.
