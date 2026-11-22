# Agent Aquarium: technical details

For developers, security reviewers and anyone curious about exactly what the app does on a Mac. For installing and using it, see the [README](../README.md).

- [How it works](#how-it-works): what it adds to Claude Code, the files it writes, the local server, and the network
- [Build from source](#build-from-source)

## How it works

Agent Aquarium has three parts: Claude Code **hooks** that record what each session is doing, a small **local server** that serves the lock screen page, and the **screensaver** (plus a menu bar app) that shows that page.

```
Claude Code ──hooks──► aquarium-node agent-aquarium-hook ──► ~/.claude/agent-aquarium/sessions/<id>.json
                                                                        │
Screensaver / settings window / menu bar ◄── http://127.0.0.1:4777 ◄── aquarium-node serve
```

### What it adds to Claude Code (`~/.claude/settings.json`)

Only after you click **Connect Claude Code** in the setup or the app menu.

- A backup is saved first, once, as `~/.claude/settings.json.bak-lockscreen`.
- **Hooks:** one command hook (`"…/Agent Aquarium.app/Contents/MacOS/aquarium-node" "agent-aquarium-hook"`, 5 s timeout) on each of these events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`, `PreCompact`, `Stop`, `SessionEnd`. The tool events use the matcher `*`. The hook reads the event, writes a small state file and exits 0. It never blocks Claude or prints anything.
- **Status line (only if you turn on plan usage):** `statusLine` is pointed at `aquarium-node agent-aquarium-statusline`, which saves your plan's usage numbers and then runs your own status line with the same input, so it looks the same. Your previous status line is saved in `statusline-chain.json`.
- Your other settings are left alone. **Uninstall** (or Disconnect) removes only these entries and puts your status line back.

### Files on your Mac

| Where | What |
|---|---|
| `~/.claude/agent-aquarium/sessions/` | One JSON file per Claude Code session: its state (working, needs you, done), its folder path and session name, the path to Claude Code's own transcript file, the current step ("Editing server.js"), the task list, and a short question Claude asked you, if any |
| `~/.claude/agent-aquarium/config.json` | Your settings: theme, away message, presets, iCal links (owner-only, `0600`) |
| `~/.claude/agent-aquarium/google.json` | Google Calendar sign-in tokens, if you connect Google (owner-only, `0600`) |
| `~/.claude/agent-aquarium/usage.json`, `statusline-chain.json` | Plan usage numbers and your previous status line (only with plan usage on) |
| `~/.claude/agent-aquarium/battery.json`, `server.log` | Battery samples for the Save battery switch, and the server's log |
| `~/Library/LaunchAgents/com.danamsalem.agentaquarium.server.plist` | Starts the local server at login |
| `~/Library/Screen Savers/Agent Aquarium.saver` | The screensaver, copied from inside the app |

The hook doesn't copy your code, your prompts or Claude's replies. It reads the end of Claude Code's transcript only to tell whether a turn ended on a question, and the server reads it to notice a stopped session.

### The local server

- Listens on **`127.0.0.1:4777` only** (loopback), so other machines on your network can't reach it.
- `GET /` (lock screen page), `GET /settings` (settings page), `GET /setup` (first-run setup), `GET /thumbnail.png` (the screen saver's tile), `GET /status` (sessions, config, calendar, usage as JSON).
- `POST /config`, `/calendars/add|remove|sync`, `/google/connect|calendars|disconnect`, `/update/open`. These accept only `Content-Type: application/json` bodies under 20 KB, so a web page in your browser can't send them without a CORS preflight, which the server doesn't allow.
- Requests whose Host header isn't 127.0.0.1 or localhost are refused, which blocks DNS-rebinding attacks.
- `GET /google/callback`: the end of the Google sign-in (loopback OAuth with PKCE).
- With **Keep Mac awake** on, it runs macOS's own `caffeinate -i` while an agent is working.

### Network

Nothing about your agents, code or sessions ever leaves your Mac. There's no account, analytics or telemetry, and no server of ours that receives your data. The only outgoing requests are:

- **Update check:** about once a day, a plain `GET https://agentaquarium.danamsalem.com/latest.json` (nothing is sent with it). Running the server straight from source (`node src/server.js`) skips it.
- **Google Calendar** (only if you connect it): read-only calls to Google's Calendar API with the scopes `calendar.calendarlist.readonly` and `calendar.events.readonly`.
- **iCal links** (only the ones you add): fetched from the address you pasted.
- **Google Fonts:** the lock screen and settings pages load a few typefaces (Press Start 2P, VT323, Space Grotesk, and Roboto for the Google button) from `fonts.googleapis.com`. Like any web font request, this shares your IP address with Google.

## Build from source

**You need:**

- A Mac with **Apple silicon** and **macOS 13 or later**
- **Xcode Command Line Tools** (`xcode-select --install`); full Xcode 15 or later also works. There's no Xcode project: the Swift files are compiled with `swiftc`.
- **Node.js 24** (`node -v` → `v24.x`; tested with 24.13.1). The build embeds this Node into the app, so people who install the app don't need Node.
- An internet connection for the first build (`npx` fetches `postject`, and the build downloads Node's license for your Node version).

```bash
git clone https://github.com/danamsalem/agent-aquarium.git
cd agent-aquarium
./install.sh
```

`./install.sh` builds the app, quits any running copy, installs it to `/Applications` and opens it. Then continue from step 4 of [Install](../README.md#install). A build made on your own Mac isn't quarantined, so there's no "Open Anyway" step.

To build without installing: `macos/build.sh` writes `build.noindex/Agent Aquarium.app`, signed ad hoc so it runs on the Mac that built it. Quit the installed copy before you open it (both use the same bundle id and port).

- **Google Calendar sign-in** needs a Google OAuth client ("Desktop app" type). Put its JSON at `./google-client.json` (gitignored) or set `GOOGLE_CLIENT_JSON=/path/to/file.json`. Without it, everything else works, including iCal calendar links.
- **Universal build (Intel too):** `ARCHS="arm64 x86_64" macos/build.sh` (needs a universal Node and Rosetta).
- **Release DMG + SHA-256:** `VERSION=1.2.3 macos/release.sh` writes `dist/Agent-Aquarium-1.2.3-arm64.dmg` and `.sha256`. It installs [`dmgbuild`](https://github.com/dmgbuild/dmgbuild) in a temporary Python environment, and the installer window lives in `macos/dmg/`.
- **Quick loop without building the app:** `node src/server.js`, then open http://127.0.0.1:4777 (lock screen) and http://127.0.0.1:4777/settings. Set `CLAUDE_LOCKSCREEN_DIR=/tmp/aquarium-dev` to keep test data away from your real install, and `CLAUDE_LOCKSCREEN_PORT=4778` to run next to it.
- **Checks:** `node check.js` (the same checks CI runs).

More: [CONTRIBUTING.md](../CONTRIBUTING.md) (project layout, adding a theme or an agent), [SIGNING-AND-NOTARIZATION.md](SIGNING-AND-NOTARIZATION.md), [TEST-ON-ANOTHER-MAC.md](TEST-ON-ANOTHER-MAC.md).
