# Testing Agent Aquarium.app on a second Mac

Goal: prove a stranger's Mac works with only the download. Use a Mac (or a fresh user account) that has never had
the script install, ideally **without Node and without Xcode command line tools**.

## Before you start
- [ ] Build: `macos/build.sh` → zip with `ditto -c -k --keepParent "build.noindex/Agent Aquarium.app" AgentAquarium.zip`.
- [ ] Confirm the target has no Node: `command -v node` prints nothing. `xcode-select -p` fails (or note that it doesn't).
- [ ] Note the macOS version and chip (Apple silicon vs Intel). The default build is **arm64 only**. For an Intel Mac, build with `ARCHS="arm64 x86_64"`.
- [ ] Transfer the zip the way users will get it (download from a browser, e.g. a private GitHub Release or AirDrop), so it gets the quarantine flag.
- [ ] Have Claude Code installed and signed in on the target.

## Install
- [ ] Unzip in Downloads and open it from there → expect the "Move Agent Aquarium to Applications" dialog (App Translocation). Quit.
- [ ] Drag to /Applications and open.
  - Ad hoc build (before notarization): expect "Apple could not verify…". System Settings → Privacy & Security → Open Anyway. Write down the exact steps and wording for the beta README.
  - Notarized build: expect only the normal "downloaded from the internet" prompt.
- [ ] A "Background item added: Agent Aquarium" notification appears. System Settings → General → Login Items shows Agent Aquarium under Allow in the Background, turned on.
- [ ] "Connect Claude Code?" dialog: the text is clear. Click Connect. `~/.claude/settings.json` has 9 hook entries pointing into /Applications/Agent Aquarium.app, plus `settings.json.bak-lockscreen` if a settings file existed.
- [ ] Screen saver dialog → Open Screen Saver Settings → "Agent Aquarium" is listed (under Other) with a live preview. Pick it.
- [ ] Settings window loads (not stuck on "Connecting…"). If it is stuck: `cat ~/.claude/agent-aquarium/server.log`.

## Works
- [ ] Restart a Claude Code session, send a prompt: the settings header shows "Claude is working · 1 session".
- [ ] Each theme in the settings window: Aquarium (the default), Warm (Apple's SF type), Retro pixel, Cosmic.
- [ ] Message: type one, Show, save as preset, pick a preset.
- [ ] Preview lock screen button opens a Lock Screen Preview window (not the screensaver) laid out like the full screen; Esc or the close button closes it. Pointing at it draws macOS's clock, your name and the password field over it (the page makes room as on the real lock screen); moving the pointer out hides them.
- [ ] Real lock: hot corner or `open -a ScreenSaverEngine` with "Require password immediately". Session state, task list and message show. Touch the trackpad: our clock hides while macOS's password field shows, then comes back.
- [ ] "Needs you" state: trigger a permission prompt in Claude Code while locked; the headline changes.
- [ ] Google: Sign in → browser opens → "Google Calendar connected" page → meetings show in settings and on the lock screen.
- [ ] iCal: add an Apple/Outlook link, it syncs.
- [ ] Offline: `launchctl bootout gui/$(id -u)/com.danamsalem.agentaquarium.server`, start the screensaver → the bundled offline page shows. Reopen the app → server is back, saver switches to live within ~10 s.
- [ ] Reboot → server is running after login without opening the app (`curl -s localhost:4777/status | head -c 100`).
- [ ] Move the app (e.g. to ~/Applications) and open it: hooks get rewritten to the new path, server still starts.
- [ ] Update: build again, replace the app, open it → server restarts on the new build (log line in server.log), saver is recopied.
- [ ] Plan usage: the app asks "Show your Claude plan usage on the lock screen?" (or it's in the Connect dialog on a fresh install). Afterwards `~/.claude/settings.json` → `statusLine.command` is the app's `agent-aquarium-statusline`, and `~/.claude/agent-aquarium/statusline-chain.json` holds the previous status line. Run `claude` in a terminal and send a message: the old status line looks the same, and the lock screen shows a Plan usage card under the calendar. In the Claude desktop app it doesn't update (expected); settings explains it.
- [ ] Menu → Show Plan Usage off: the old status line is back in settings.json.
- [ ] Right-to-left message: set "פגישה ב-Zoom עד 15:30 עם Design team 📅". Words read right to left, "Zoom", "15:30" and "Design team" read left to right, the emoji sits at the far left.
- [ ] Always-On Display: menu → Always-On Display → pick a display. Full screen there, no cursor, Esc closes. Unplug and replug an external display: it comes back.
- [ ] Aquarium theme: one robot fish per session; a permission prompt makes a fish swim up beside the starburst and tap; finished ones rest on the sand.
- [ ] Battery (laptops): unplug → settings → Usage & battery → "Right now" says On battery within ~5 s; run the screensaver for 3+ minutes → "While the lock screen shows" gets a number.
- [ ] Middle: the headline sits on the screen's center line, and doesn't move or resize when you touch the trackpad on the lock screen. The task list is a row of cards under it that slides to the next task.

## Remove
- [ ] Agent Aquarium → Uninstall… with "Also delete my settings…" ticked: hooks gone from settings.json, `~/Library/LaunchAgents/com.danamsalem.agentaquarium.server.plist` and its Login Items entry gone, `~/Library/Screen Savers/Agent Aquarium.saver` in Trash, `~/.claude/agent-aquarium` in Trash, Google access revoked (myaccount.google.com → Security → Third-party access).
- [ ] Drag the app to Trash. Nothing is left running (`pgrep -fl aquarium`).
- [ ] Reinstall from scratch works (no stale dialogs: the app's preferences were reset).

## Record
- macOS version / chip, ad hoc or notarized, every dialog's exact text, anything confusing, CPU and memory of `aquarium-node` and `legacyScreenSaver` after 10 minutes on the lock screen (Activity Monitor).
