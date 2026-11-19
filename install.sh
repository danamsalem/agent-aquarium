#!/bin/bash
# Builds Agent Aquarium from source and installs it to /Applications, then opens it.
# A build made on this Mac isn't quarantined, so macOS doesn't ask you to "Open Anyway".
# Usage: ./install.sh        (same environment variables as macos/build.sh, e.g. GOOGLE_CLIENT_JSON=…)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="/Applications/Agent Aquarium.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APP="$("$ROOT/macos/build.sh" "$TMP" | tail -1)"
osascript -e 'quit app id "com.danamsalem.agentaquarium"' 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed $DEST"
open "$DEST"
