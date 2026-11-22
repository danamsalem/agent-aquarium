#!/bin/bash
# Builds the download for a release:
#   dist/Agent-Aquarium-<version>-<arch>.zip          the app, zipped with ditto (keeps the bundle intact)
#   dist/Agent-Aquarium-<version>-<arch>.zip.sha256   its SHA-256, in `shasum -a 256` format
# The GitHub Action in .github/workflows/release.yml runs this and puts both files in a draft release.
# Usage: VERSION=1.0.0 macos/release.sh             (ARCHS="arm64 x86_64" for a universal build)
#   REQUIRE_GOOGLE=1   fail if no google-client.json is bundled (official releases have Google Calendar sign-in)
# Builds are signed ad hoc unless SIGN_ID is set; see docs/SIGNING-AND-NOTARIZATION.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERSION="${VERSION:?Set VERSION, e.g. VERSION=1.0.0 macos/release.sh}"
ARCHS="${ARCHS:-arm64}"
OUT="$ROOT/dist"
NAME="Agent-Aquarium-$VERSION-$([[ "$ARCHS" == *" "* ]] && echo universal || echo "$ARCHS").zip"

mkdir -p "$OUT"
APP="$(VERSION="$VERSION" ARCHS="$ARCHS" "$HERE/build.sh" "$OUT" | tail -1)"
if [[ ! -f "$APP/Contents/Resources/app/google-client.json" && "${REQUIRE_GOOGLE:-0}" == 1 ]]; then
  echo "No google-client.json in the build, so Google sign-in would be missing." >&2
  exit 1
fi
rm -f "$OUT/$NAME" "$OUT/$NAME.sha256"
ditto -c -k --keepParent "$APP" "$OUT/$NAME"
rm -rf "$APP" # keep only the zip, so Spotlight doesn't list a second copy of the app
( cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256" && cat "$NAME.sha256" )
echo "$OUT/$NAME"
