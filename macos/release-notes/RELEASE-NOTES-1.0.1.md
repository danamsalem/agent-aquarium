Agent Aquarium is now open source under the MIT license. The source is in this repo; this build was made by GitHub Actions from this tag, and its SHA-256 is attached.

## What's new

- **Open source.** Read the code, build it yourself or contribute. See [how it works](https://github.com/danamsalem/agent-aquarium/blob/main/docs/TECHNICAL.md) and [CONTRIBUTING.md](https://github.com/danamsalem/agent-aquarium/blob/main/CONTRIBUTING.md).
- **Safer local server.** It now refuses requests that don't address it as `127.0.0.1` or `localhost`, which blocks DNS-rebinding attacks.
- **Safer update link.** "Update available" can only open this project's GitHub pages.

Your settings, sessions and Google sign-in stay as they are.

## Install

**You need:** a Mac with Apple silicon (M1 or later), macOS 13 or later, and [Claude Code](https://claude.com/claude-code).

1. Download **Agent-Aquarium-1.0.1-arm64.zip** below and double-click it to unzip.
2. Drag **Agent Aquarium** into your **Applications** folder (replace the old one if you're updating).
3. Open it. **The first time, macOS blocks it**, because the app isn't notarized by Apple yet. Click **Done**, open **System Settings → Privacy & Security**, click **Open Anyway** next to the message about Agent Aquarium, enter your password, then open the app again and click **Open**.
   Or, in Terminal: `xattr -dr com.apple.quarantine "/Applications/Agent Aquarium.app"`, then open the app.
4. Click **Connect Claude Code** when asked, then restart any Claude Code sessions that are already open.
5. Choose **Agent Aquarium** in **System Settings → Screen Saver** (under Other). To keep your Mac locked while it shows, set Lock Screen → "Require password after screen saver begins" to **Immediately**.

**Check the download (optional):** put the `.sha256` file next to the zip and run `shasum -a 256 -c Agent-Aquarium-1.0.1-arm64.zip.sha256`.
