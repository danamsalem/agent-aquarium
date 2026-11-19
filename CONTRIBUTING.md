# Contributing to Agent Aquarium

Thanks for helping! Agent Aquarium is a small app: a few JavaScript files, two HTML pages and two Swift files. You can read all of it in an afternoon.

**Looking for a first big contribution?** [#6: Support for Codex and Cursor](https://github.com/danamsalem/agent-aquarium/issues/6) is the most-wanted feature. See [Add a new agent](#add-a-new-agent) below. Comment on the issue before you start, so two people don't build the same thing.

## Project layout

```
src/                      Everything the app runs, in plain JS and HTML (no framework, no npm dependencies)
  index.html              The lock screen: themes, the crab, session cards, task carousel, message, calendar, usage
  settings.html           The settings page shown in the app's window
  server.js               Local server on 127.0.0.1:4777: serves the pages, /status, /config, calendars
  hook.js                 Claude Code hook: turns hook events into one state file per session
  setup-hooks.js          Adds/removes the hooks and the status line wrapper in ~/.claude/settings.json
  statusline.js           Status line wrapper that saves plan usage, then runs the user's own status line
  calendar.js, google.js  iCal feeds, and Google Calendar sign-in (loopback OAuth + PKCE, read-only scopes)
  battery.js              On-battery state for the Save battery switch
macos/
  AgentAquariumApp.swift  The app: settings window, menu bar fish, launch agent, hook consent, uninstall
  build.sh                Builds "Agent Aquarium.app" (Node single-executable + Swift app + screensaver)
  bundle.js               Bundles src/*.js into one script for the embedded Node
  release.sh              Builds the release zip and its .sha256
install.sh                Builds from source and installs to /Applications
screensaver/
  ClaudeLockscreenView.swift   The .saver: a WKWebView showing http://127.0.0.1:4777/?screensaver=1
brand/                    App icon source
docs/                     Signing/notarization notes and a manual test checklist
check.js                  The checks CI runs
```

## Build and run

You need a Mac with Apple silicon, macOS 13+, the Xcode Command Line Tools (`xcode-select --install`) and Node.js 24.

**Fast loop (most changes):** run the server from source and use your browser.

```bash
CLAUDE_LOCKSCREEN_DIR=/tmp/aquarium-dev CLAUDE_LOCKSCREEN_PORT=4778 node src/server.js
```

- Lock screen: http://127.0.0.1:4778/ (add `?screensaver=1` to see it as the screensaver does)
- Settings: http://127.0.0.1:4778/settings
- `CLAUDE_LOCKSCREEN_DIR` keeps test data out of your real `~/.claude/agent-aquarium`, and the other port lets it run next to an installed copy.
- Edits to `index.html` / `settings.html` show on reload; restart the server after editing a `.js` file.

**Fake a session** without running Claude Code, by piping a hook event into the hook:

```bash
echo '{"session_id":"demo1","hook_event_name":"PreToolUse","cwd":"/tmp/my-project","tool_name":"Edit","tool_input":{"file_path":"/tmp/my-project/app.js"}}' \
  | CLAUDE_LOCKSCREEN_DIR=/tmp/aquarium-dev node src/hook.js
```

Swap in `"hook_event_name":"PermissionRequest"` for "needs you", or `"Stop"` for "done". `SessionEnd` removes it.

**Full app:** `./install.sh` builds it and installs it to /Applications (replacing the installed copy). Or `macos/build.sh` to only build `build.noindex/Agent Aquarium.app`; quit any installed Agent Aquarium before opening it, since both use the same bundle id and port. After you install a new screensaver build, run `killall legacyScreenSaver` so macOS loads it.

**Checks:** `node check.js` (syntax of every script and page, the server serves its pages, no `google-client.json` committed). CI runs it on every push and pull request.

## Add a theme

A theme is a scene drawn on a `<canvas>` in `src/index.html`, plus a few lists that name it. Use an existing theme (`cosmic` is a good template) and search for its id:

1. **`src/index.html`**
   - `ALL_THEMES` and `THEME_NAMES`: add the id and display name.
   - `:root[data-theme="<id>"] { … }` CSS: colors, fonts and the message note's colors.
   - `PAL.<id>`: accent, warn ("needs you"), ok ("done"), crab and text colors.
   - `THEME_IMPL.<id>`: `init()` sets up the scene, and the draw function runs each frame. Read the session list and state from the shared variables the other themes use; keep the crab, starburst and the "claude is working / needs you / done" headline.
   - `CONFETTI`, `BRAND` and `SWATCH` (the swatch on the theme picker button).
2. **`src/settings.html`**: add `{ id, name, desc }` to the theme list.
3. **`src/server.js`**: add the id to `THEMES`, or the server won't save it.
4. Add it to the Theme dropdown in `.github/ISSUE_TEMPLATE/bug_report.yml`.

Keep it light: the lock screen can run for hours, on battery too. Draw slow layers once to an offscreen canvas, avoid per-frame blur/`shadowBlur`, and check the Save battery path (30 fps, 1x canvas). Include a screenshot or short recording in your PR.

## Add a new agent

Today only Claude Code reports to the lock screen. The display side doesn't care which agent a session comes from: the server shows every JSON file in `~/.claude/agent-aquarium/sessions/`. So adding an agent (Codex, Cursor, …) means writing those files from that agent's events.

**The session file** (`sessions/<id>.json`, written atomically: write a `.tmp` file, then rename):

```json
{
  "id": "codex-7f3a",
  "state": "working",
  "action": "Editing server.js",
  "cwd": "/Users/me/code/my-app",
  "project": "my-app",
  "title": "Fix the login bug",
  "task_started": 1763560000000,
  "done_at": null,
  "updated_at": 1763560123000,
  "plan": [{ "text": "Write the fix", "status": "in_progress" }]
}
```

- `state`: `idle`, `thinking`, `working`, `waiting` (needs you) or `done`.
- `action`: one short line for the card (keep it under ~70 characters).
- `project` labels the session (the folder name); `title` is used instead when the agent has a session name.
- `plan` (optional) fills the task carousel; `status` is `pending`, `in_progress` or `completed`.
- `updated_at` (ms) is required; files untouched for a day are deleted. Delete the file when the session ends.
- Prefix ids with the agent's name (`codex-…`) so they never collide with Claude Code's.

**Steps:**

1. Find the agent's hook or event mechanism (for example Codex's `notify` command in `~/.codex/config.toml`, or Cursor's hooks), and which events mean started / working / needs approval / finished.
2. Write `src/hooks/<agent>.js` (or extend `hook.js` with a mode) that maps those events to the file above. Reuse `describe()` in `hook.js` for tool names where it fits.
3. Add a mode to `macos/bundle.js` (like `agent-aquarium-hook`) so the app's `aquarium-node` can run it, and add the file to its `MODULES` list.
4. Install and uninstall it like `setup-hooks.js` does for Claude Code: back up the agent's config first, make re-running idempotent, remove only your own entries on uninstall, and **ask before changing it** (the app shows a consent dialog for Claude Code; do the same).
5. Update the README's "How it works / what it touches" section with exactly what your change writes, and the privacy notes if anything new is stored.
6. Add a fake-event example to this file so others can test it without the agent.

Note: the server watches Claude Code transcripts for "stopped" sessions (`wasStopped` in `server.js`); other agents won't have that, so make sure your adapter moves a stopped session out of `working`.

## Pull requests

- One change per PR, and say what you tested (the PR template has a checklist).
- Don't change how existing themes look unless the PR is about that; include before/after screenshots when you do.
- No new runtime dependencies without discussing it first: the app ships as one Node binary with no `node_modules`.
- Nothing may leave the user's Mac beyond what the README lists. New network calls need a good reason and a README update.
- Run `node check.js` before you push.

## Reporting bugs and security issues

Bugs and ideas: [open an issue](https://github.com/danamsalem/agent-aquarium/issues/new/choose). Security problems: please report them privately, see [SECURITY.md](SECURITY.md).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
