# M0 — Spike results

Throwaway code lives in `spikes/`. Each section below records what we measured and what it changes in [PLAN.md](PLAN.md).

| # | Spike | Status |
|---|---|---|
| 1a | Browser tab enumeration latency | ⏳ Needs Automation permission (run from Terminal) |
| 1b | Read Chromium `Favicons` DB while Chrome runs | ✅ Done |
| 2 | AX windows across Spaces / fullscreen / minimized | ⏳ Needs Accessibility permission (run from Terminal) |
| 3 | Tab activation in a background window on another Space | ⏳ Interactive, do together |
| 4a | Terminal tab label (process + cwd) from tty | ✅ Done |
| 4b | Terminal tab enumeration via AppleScript; closing one tab | ⏳ Needs Automation permission |
| 5 | Stable self-signed cert keeps TCC grants across rebuilds | ⏳ Interactive (Keychain), do together |
| 6a | Double-Shift detector logic | ✅ Done (synthetic tests) |
| 6b | Double-Shift on real typing | ⏳ Needs Input Monitoring (run from Terminal) |

---

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
