#!/bin/bash
# Builds "Agent Aquarium.app": one app with everything inside, so users need neither Node nor Xcode.
#   Contents/MacOS/AgentAquarium          settings window + setup (macos/AgentAquariumApp.swift)
#   Contents/MacOS/aquarium-node          Node single-executable app: the server, the hook and the
#                                         hook installer (server.js & co. bundled by macos/bundle.js)
#   Contents/Resources/app/               index.html, settings.html, google-client.json
#   Contents/Resources/Acknowledgements.txt   Node.js's license (macos/licenses/, per Node version)
#   Contents/Library/Screen Savers/       Agent Aquarium.saver (copied to ~/Library/Screen Savers)
#
# Usage: macos/build.sh [output-dir]           (default: build.noindex/ in the project folder; ".noindex" keeps
#                                              Spotlight from listing it next to the installed app)
#   ARCHS="arm64 x86_64"   universal build (default: arm64; x86_64 needs Rosetta and a universal node)
#   SIGN_ID="Developer ID Application: …"      sign for distribution (hardened runtime + timestamp);
#                                              default "-" signs ad hoc, which only runs on this Mac
#   NODE=/path/to/node     the Node whose runtime gets embedded (default: node on PATH; Node 24 or newer)
#   GOOGLE_CLIENT_JSON=…   a Google OAuth "Desktop app" client file to bundle (default: ./google-client.json if present).
#                          Without one the build works but has no Google Calendar sign-in (iCal links still work).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-$ROOT/build.noindex}"
APP="$OUT/Agent Aquarium.app"
ARCHS="${ARCHS:-arm64}"
SIGN_ID="${SIGN_ID:--}"
NODE="${NODE:-$(command -v node)}"
VERSION="${VERSION:-1.0.0}"
BUILD="$(date +%Y%m%d%H%M%S)" # CFBundleVersion: the app restarts the server and recopies the saver when it changes
BUNDLE_ID="com.danamsalem.agentaquarium"
POSTJECT="postject@1.0.0-alpha.6"
SEA_FUSE="NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Agent Aquarium $VERSION ($BUILD) for $ARCHS, Node $("$NODE" -v)"
SRC="$ROOT/src"
GOOGLE_CLIENT_JSON="${GOOGLE_CLIENT_JSON:-$ROOT/google-client.json}"
rm -rf "$APP"
C="$APP/Contents"
mkdir -p "$C/MacOS" "$C/Resources/app" "$C/Library/Screen Savers"

# Runs one command per architecture into $TMP/<name>-<arch>, then joins the slices into $2.
fat() {
  local name="$1" dest="$2"; shift 2
  local slices=()
  for arch in $ARCHS; do slices+=("$TMP/$name-$arch"); done
  if [[ ${#slices[@]} -eq 1 ]]; then cp "${slices[0]}" "$dest"; else lipo -create "${slices[@]}" -output "$dest"; fi
}

echo "1/5  Server: bundling the JS into a Node single-executable app"
"$NODE" "$HERE/bundle.js" "$SRC" "$TMP/aquarium.js" >/dev/null
for arch in $ARCHS; do
  cat > "$TMP/sea-$arch.json" <<EOF
{ "main": "$TMP/aquarium.js", "output": "$TMP/blob-$arch", "disableExperimentalSEAWarning": true, "useCodeCache": true }
EOF
  arch "-$arch" "$NODE" --experimental-sea-config "$TMP/sea-$arch.json" >/dev/null # the code cache is per architecture
  if lipo -archs "$NODE" | grep -qw "$arch" && [[ "$(lipo -archs "$NODE")" != "$arch" ]]; then
    lipo "$NODE" -thin "$arch" -output "$TMP/aquarium-node-$arch"
  else
    cp "$NODE" "$TMP/aquarium-node-$arch"
  fi
  chmod u+w "$TMP/aquarium-node-$arch"
  codesign --remove-signature "$TMP/aquarium-node-$arch"
  npx --yes "$POSTJECT" "$TMP/aquarium-node-$arch" NODE_SEA_BLOB "$TMP/blob-$arch" \
    --sentinel-fuse "$SEA_FUSE" --macho-segment-name NODE_SEA >/dev/null
done
fat aquarium-node "$C/MacOS/aquarium-node"
cp "$SRC/index.html" "$SRC/settings.html" "$C/Resources/app/"
# Node's license (which also covers the libraries Node includes) has to ship with every copy of the runtime we embed.
NODE_LICENSE="$HERE/licenses/node-$("$NODE" -v)-LICENSE.txt"
if [[ ! -f "$NODE_LICENSE" ]]; then
  echo "     fetching Node.js $("$NODE" -v)'s license for Acknowledgements.txt"
  curl -fsSL "https://raw.githubusercontent.com/nodejs/node/$("$NODE" -v)/LICENSE" -o "$NODE_LICENSE"
fi
{ printf 'Agent Aquarium includes Node.js %s (Contents/MacOS/aquarium-node), used under the license below.\n\n' "$("$NODE" -v)"; cat "$NODE_LICENSE"; } > "$C/Resources/Acknowledgements.txt"
if [[ -f "$GOOGLE_CLIENT_JSON" ]]; then
  cp "$GOOGLE_CLIENT_JSON" "$C/Resources/app/google-client.json"
else
  echo "     note: no google-client.json, so this build has no Google sign-in"
fi


echo "2/5  Settings app"
for arch in $ARCHS; do
  xcrun swiftc -swift-version 5 -O -target "$arch-apple-macos13" \
    -framework Cocoa -framework WebKit -framework ServiceManagement \
    -o "$TMP/AgentAquarium-$arch" "$HERE/AgentAquariumApp.swift"
done
fat AgentAquarium "$C/MacOS/AgentAquarium"

cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>AgentAquarium</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Agent Aquarium</string>
  <key>CFBundleDisplayName</key><string>Agent Aquarium</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
EOF

echo "3/5  Screensaver"
SAVER="$C/Library/Screen Savers/Agent Aquarium.saver"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
for arch in $ARCHS; do
  xcrun swiftc -swift-version 5 -O -emit-library -module-name AgentAquarium -target "$arch-apple-macos13" \
    -framework ScreenSaver -framework WebKit \
    -o "$TMP/AgentAquariumSaver-$arch" "$ROOT/screensaver/ClaudeLockscreenView.swift"
done
fat AgentAquariumSaver "$SAVER/Contents/MacOS/AgentAquarium"
cat > "$SAVER/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>AgentAquarium</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.saver</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Agent Aquarium</string>
  <key>CFBundleDisplayName</key><string>Agent Aquarium</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>ClaudeLockscreenView</string>
</dict>
</plist>
EOF
cp "$SRC/index.html" "$SAVER/Contents/Resources/index.html" # shown when the server isn't running

echo "4/5  Icon"
xcrun swift "$HERE/make-icon.swift" "$ROOT/brand/agent-aquarium-icon-1024.png" "$TMP/icon.png"
mkdir "$TMP/icon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/icon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/icon.iconset" -o "$C/Resources/AppIcon.icns"

echo "5/5  Signing ($([[ "$SIGN_ID" == "-" ]] && echo "ad hoc" || echo "$SIGN_ID"))"
SIGN=(codesign --force --sign "$SIGN_ID")
[[ "$SIGN_ID" != "-" ]] && SIGN+=(--options runtime --timestamp)
# Inside out: nested code first, the app last. Node's JIT needs its two entitlements under the hardened runtime.
"${SIGN[@]}" --identifier "$BUNDLE_ID.server" --entitlements "$HERE/node.entitlements" "$C/MacOS/aquarium-node"
"${SIGN[@]}" "$SAVER"
"${SIGN[@]}" "$APP"
codesign --verify --strict --deep "$APP"
touch "$APP"
echo "$APP"
