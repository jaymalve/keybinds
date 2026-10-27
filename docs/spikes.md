# M0 — Spike results

Throwaway code lives in `spikes/`. Each section below records what we measured and what it changes in [PLAN.md](PLAN.md).

| # | Spike | Status |
|---|---|---|
| 1a | Browser tab enumeration latency | ✅ Done |
| 1b | Read Chromium `Favicons` DB while Chrome runs | ✅ Done |
| 2 | AX windows across Spaces / fullscreen / minimized | ✅ Done: plain AX misses other Spaces; remote tokens fix it. Needs a hidden-window filter |
| 3 | Tab activation in a background window on another Space | ⏳ Interactive, do together |
| 4a | Terminal tab label (process + cwd) from tty | ✅ Done |
| 4b | Terminal tab enumeration via AppleScript; closing one tab | ✅ Enumeration done; closing a tab still open |
| 5 | Stable self-signed cert keeps TCC grants across rebuilds | ✅ Done (in M1) |
| 6a | Double-Shift detector logic | ✅ Done (synthetic tests) |
| 6b | Double-Shift on real typing | ✅ 4/4 detected, 0 false triggers; defaults 200 ms hold / 300 ms gap |

---

## 1a / 4b. Tab enumeration via AppleScript — ✅ (steady state)
`spikes/tabs_latency.swift`: one batched Apple Event per app, compiled `NSAppleScript`, 5 runs each.

| App | Windows | Tabs | First call | Median | Max after first |
|---|---|---|---|---|---|
| Chrome | 5 | 24 | 92 ms | **33 ms** | — |
| Safari | 1 | 13 | 42 ms | **3 ms** | — |
| Terminal | 5 | 5 | 21 ms | **25 ms** | 44 ms |
| Brave | — | — | not running, skipped (never launched) | | |

- Steady state is far under the 150 ms target, so batching works.
- Cold first calls are 21–92 ms. A first run that also showed the Automation prompts took 1.7–1.9 s, which was the prompts, not a real startup cost.
- Only 24 Chrome tabs were open; the 100+ tab case is still unmeasured. Batching should keep it sublinear; re-check once we have the real app.

## 2. Windows across Spaces — ✅ (with one follow-up)
`spikes/ax_windows.swift` (plain AX), `spikes/ax_all_spaces.swift` (plain AX + remote-token brute force).

**Plain `kAXWindowsAttribute` only returns windows on the current Space.** Chrome returned 0 windows although AppleScript saw them; Claude, ChatGPT and Spotify also returned 0. Minimized windows *are* returned (`MINIMIZED`).

**Remote tokens fix it.** `_AXUIElementCreateWithRemoteToken`, AltTab's technique (token = pid | 0 | `'coco'` | element id, ids 0…1000, 100 ms budget per app), found **26 windows vs 15**:

| App | Plain AX | All Spaces | Time (all Spaces) |
|---|---|---|---|
| Google Chrome | 0 | **3** | 33 ms |
| Claude | 0 | **2** | 23 ms |
| ChatGPT | 0 | **1** | 33 ms |
| Spotify | 0 | **1** | 40 ms |
| Wispr Flow | 1 | 5 ⚠️ | 17 ms |
| Docker Desktop | 0 (252 ms) | 0 (**1,502 ms**) ⚠️ | — |
| Most other apps | = | = | 17–66 ms |

Findings and plan changes:
- **Adopt remote-token discovery** for the Windows provider, isolated in `System/` next to `_AXUIElementGetWindow`. No extra permission is needed, so **Screen Recording stays unnecessary**.
- **False positives:** 4 of Wispr Flow's 5 "windows" (`Context Menu`, `Scratchpad`, `Meeting Recorder`, …) are hidden or ordered-out panels, not real windows.
  → Filter: keep a window only if the window server assigns it to a Space (private `CGSCopySpacesForWindows`, as AltTab does) or it's minimized. To verify in M2.
- **Unresponsive apps:** Docker Desktop blocked 252 ms on plain AX and 1.5 s on the brute force. A messaging timeout on the app element doesn't apply to elements created from tokens.
  → Set `AXUIElementSetMessagingTimeout` on **every** element, scan apps **in parallel** off the main thread, and back off from an app that times out (skip it for a while and keep its last cached windows).
- **Total serial time was 2.6 s**, dominated by Docker. Run in parallel with backoff, a full scan should take roughly as long as the slowest healthy app (~70 ms). It runs in the background only and is kept fresh by AX observers on the discovered windows.
- **Chrome:** the brute force found 3 windows; AppleScript reported 5 earlier (windows may have changed between runs). Not critical, because Chrome *tabs* come from AppleScript, which sees every Space. Activation still needs the window's AX element, so re-check in spike 3.
- **Fullscreen:** untested. Nothing was fullscreen during the run. Covered in spike 3.

## 6b. Double-Shift on real typing — ✅
`spikes/shift_recorder.swift` (now prints detections live; Ctrl-C still prints the analysis).

Run: ~90 s, 255 key presses, 4 deliberate double-Shifts, Shift also used for capitals.

| Thresholds (hold / gap) | Fired at | False triggers |
|---|---|---|
| 150 ms / 250 ms | 6.5 s, 8.8 s, 30.6 s, 59.4 s | 0 |
| 200 ms / 300 ms | same | 0 |
| 250 ms / 400 ms | same | 0 |

- **All three settings give the same result:** every deliberate tap is caught, and nothing else fires, even at the loosest setting.
- **Deliberate taps are quick:** median Shift hold **88 ms**, and the gap between taps is ~**67 ms** (10th percentile of all gaps). That leaves 2–4× headroom under 200 ms / 300 ms.
- Shift used for capitals is held much longer (90th percentile 1.4 s) and always has a letter pressed during the hold, so it's rejected by the pure-tap rule, not by timing.
- **Decision:** keep the defaults at **hold ≤ 200 ms, gap ≤ 300 ms**, configurable in settings.
- Caveat: a small sample (255 keys). M1 logs each trigger in debug builds so a false trigger in real use can be spotted and the thresholds revisited.

## 5. Stable signing identity — ✅
`scripts/make-dev-cert.sh`, `scripts/bundle.sh`

- A self-signed "Keybinds Dev" code-signing cert, made with openssl and imported into the login keychain with `-T /usr/bin/codesign`. **It doesn't need to be trusted**: codesign uses it without prompting, even though `find-identity -v` lists it as not valid.
- Designated requirement: `identifier "com.jaymalve.keybinds" and certificate leaf = H"011a51c2…"`. It depends only on the bundle ID and the cert, not on the binary.
- Verified: after granting Accessibility once, two rebuilds with real code changes launched with `accessibility granted: true`, with no re-prompt.
- Gotcha: in zsh, `log` is a shell builtin. Use `/usr/bin/log show --predicate 'subsystem == "com.jaymalve.keybinds"'`.

## 1b. Chromium favicons — ✅
`spikes/favicons_db.swift`

- Opening `…/Google/Chrome/Default/Favicons` with `?immutable=1` works **while Chrome is running**. No copy is needed and no permission prompt appears.
- The `icon_mapping → favicon_bitmaps` join works: 1,033 mappings, query **~12 ms**, 32px bitmaps available.
- **New finding:** this machine has **8 Chrome profiles** (`Default`, `Profile 1`…`Profile 7`). AppleScript doesn't say which profile a window belongs to.
  → **Plan change:** the favicon store builds one `host → icon` map across all profiles of all Chromium browsers, newest bitmap wins. Lookup is by page URL first, then by host.

## 4a. Terminal labels from tty — ✅
`spikes/tty_label.swift`

- With libproc only (`proc_listallpids`, `PROC_PIDTBSDINFO`, `PROC_PIDVNODEPATHINFO`), we group processes by controlling tty, pick the foreground process (`pgid == tpgid`), and read its cwd. **No permissions needed.**
- Sample output: `ttys043: opencode — ~/Desktop/diffling`, `ttys060: ssh — ~/clipmunk/examples/vite-app`. These labels are useful.
- Full scan of 763 pids: **~54 ms**. That's fine for a background refresh but too slow to run on every palette open.
- The scan also sees ttys that don't belong to Terminal.app (other apps' ptys).
  → **Plan change:** the Terminal provider gets the tty list from AppleScript first and only resolves those ttys, with results cached per tty and invalidated on refresh.

## 6a. Double-Shift detector — ✅
`spikes/DoubleTapDetector.swift`, `spikes/detector_tests.swift`

All 11 synthetic cases pass: a clean double tap fires; `Hello World` and fast `I'M` don't fire; a gap that's too long, a hold that's too long, a key between taps, and `⌘⇧` combos don't fire; a triple tap fires once and four taps fire twice.

- Note for M1: the real monitor gets `flagsChanged` with full flag state. Shift going down while ⌘/⌥/⌃ is already held must count as `otherModifierDown`; the recorder already does this.
- The detector moves into `KeybindsCore/Input/` almost unchanged, and these cases become unit tests.

---

## Pending: run from Terminal.app
The coding session has no Automation, Accessibility or Input Monitoring permissions, so these tests have to be run by you. Run them from Terminal; macOS will prompt the first time, granting the permission to Terminal.

```sh
cd ~/.t3/projects/keybinds/spikes

./tabs_latency        # 1a + 4b. Prompts for Automation: Chrome, Safari, Terminal. Click OK.
./ax_windows          # 2. Put a few windows on another Space, one fullscreen app, one minimized window first.
./shift_recorder 180  # 6b. Needs Input Monitoring for Terminal (restart Terminal after granting).
                      #     Type normally for 3 minutes, plus ~5 deliberate double-Shift taps. Note roughly when.
```
Paste the outputs back into the session. The binaries are git-ignored; rebuild with `swiftc -O <name>.swift -o <name>`. `shift_recorder` has top-level code plus a second file, so build it with `cp shift_recorder.swift /tmp/main.swift && swiftc -O DoubleTapDetector.swift /tmp/main.swift -o shift_recorder`.

Privacy: `shift_recorder` records only event *timings* and whether a key was Shift, another modifier, or a regular key. No characters or key codes are recorded, and nothing is written to disk.
