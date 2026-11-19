# Next step: Developer ID signing and notarization

Today the build is signed **ad hoc** (`codesign -s -`). It runs on the Mac that built it. On any other Mac, Gatekeeper
blocks it until the user clicks Privacy & Security → Open Anyway, which is too much friction for a public beta. To
remove that friction:

## 1. Get a Developer ID (maintainer, one time)
- Join the Apple Developer Program as an individual ($99/year).
- Xcode → Settings → Accounts → Manage Certificates → + → **Developer ID Application**. Check it's there:
  `security find-identity -v -p codesigning` shows `Developer ID Application: <Name> (<TEAMID>)`.
- Create an app-specific password at appleid.apple.com, then store it for notarytool:
  `xcrun notarytool store-credentials agent-aquarium --apple-id <your Apple ID> --team-id <TEAMID>`

## 2. Build signed
```
SIGN_ID="Developer ID Application: <Name> (<TEAMID>)" ARCHS="arm64 x86_64" macos/build.sh build.noindex
```
`macos/build.sh` already handles the signing details when `SIGN_ID` is set:
- inside-out order (aquarium-node → saver → app);
- `--options runtime` (hardened runtime) and `--timestamp` on all three;
- `macos/node.entitlements` (allow-jit, allow-unsigned-executable-memory) **only** on aquarium-node, which V8 needs.
  Tested ad hoc with the hardened runtime: it crashes without them and runs with them.
- `--identifier com.danamsalem.agentaquarium.server` on aquarium-node.

Check: `codesign -dv --verbose=4 "build.noindex/Agent Aquarium.app"` (Authority = Developer ID, flags include runtime),
`codesign --verify --strict --deep`, and `spctl -a -vv "build.noindex/Agent Aquarium.app"` (fails until notarized).

## 3. Notarize and staple
```
ditto -c -k --keepParent "build.noindex/Agent Aquarium.app" AgentAquarium.zip
xcrun notarytool submit AgentAquarium.zip --keychain-profile agent-aquarium --wait
xcrun stapler staple "build.noindex/Agent Aquarium.app"
ditto -c -k --keepParent "build.noindex/Agent Aquarium.app" "Agent-Aquarium-0.9.0.zip"   # the file for GitHub Releases
spctl -a -vv "build.noindex/Agent Aquarium.app"   # → accepted, source=Notarized Developer ID
```
If it's rejected: `xcrun notarytool log <submission-id> --keychain-profile agent-aquarium`. Likely causes:
- a binary missing the hardened runtime or a timestamp (each nested executable must have both);
- `get-task-allow` showing up (it shouldn't: we don't use Xcode debug signing).

Worth knowing:
- The Node binary gets re-signed with the maintainer's identity. Postject edits it, so Node.js's original signature is removed first; that's expected.
- Could be a .dmg instead of a zip (drag-to-Applications window). Not needed for the beta; a zip is fine.
- Consider a script `macos/release.sh` that runs steps 2–3 once the credentials exist.

## 4. Check what changes once signed
- **Login item name:** with Developer ID, Login Items → Allow in the Background lists the server under the developer's name. Check it reads well.
- **SMAppService:** the app writes its own launch agent today, because SMAppService pins ad hoc builds to their exact hash and then won't start an updated server. With Developer ID the pin is the team, so switching back to `SMAppService.agent` (plist in Contents/Library/LaunchAgents with BundleProgram) becomes an option; test an update on top of an install if you do.
- **The screensaver** is copied by the app into ~/Library/Screen Savers. It keeps the Developer ID signature. Test on the
  second Mac that legacyScreenSaver loads it from a downloaded (quarantined) build.
- **Bundle ids are final now** (`com.danamsalem.agentaquarium*`). Don't change them after the beta: preferences, the
  launch agent label and the Login Items entry are keyed on them.
- **Versioning:** set `VERSION=0.9.1 macos/build.sh` for each release. CFBundleVersion is a build timestamp, and the app
  uses it to restart the server and recopy the saver after an update.
- **Updates:** users re-download for now. Sparkle (signed appcast on GitHub Releases) is the usual next step and needs the same Developer ID.

## 5. Before the beta is public (not signing, but on the same path)
- Intel support: ship the universal build (~84 MB zipped) or say "Apple silicon only".
- Google sign-in shows the "unverified app" warning (and a 100-user cap) until Google verification passes (see roadmap).
- `google-client.json` is inside the app by design (desktop OAuth). Keep it out of the public repo and the website.
