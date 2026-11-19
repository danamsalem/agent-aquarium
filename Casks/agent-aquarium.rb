# Homebrew cask for the personal tap danamsalem/homebrew-tap.
# Copy this file to Casks/agent-aquarium.rb in that repo. On each release, update `version` and `sha256`
# (the sha256 is in the release's Agent-Aquarium-<version>-arm64.zip.sha256 file).
#   brew install --cask danamsalem/tap/agent-aquarium
cask "agent-aquarium" do
  version "1.0.0"
  sha256 "7c4be70236e447b06150a06dc8f78ed2c1607bf2f75fa421323a65a5d46fbbb2"

  url "https://github.com/danamsalem/agent-aquarium/releases/download/v#{version}/Agent-Aquarium-#{version}-arm64.zip"
  name "Agent Aquarium"
  desc "Lock screen that shows what your AI coding agents are doing"
  homepage "https://agentaquarium.danamsalem.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Agent Aquarium.app"

  # The app removes its Claude Code hooks, launch agent and screensaver itself (menu → Uninstall Agent Aquarium…).
  # These clean up if the app was deleted without that.
  uninstall launchctl: "com.danamsalem.agentaquarium.server",
            quit:      "com.danamsalem.agentaquarium",
            delete:    "~/Library/Screen Savers/Agent Aquarium.saver"

  zap trash: [
    "~/.claude/agent-aquarium",
    "~/Library/LaunchAgents/com.danamsalem.agentaquarium.server.plist",
    "~/Library/Preferences/com.danamsalem.agentaquarium.plist",
  ]

  caveats <<~EOS
    Open Agent Aquarium once and click Connect Claude Code, then pick it in
    System Settings → Screen Saver. The app isn't notarized yet: if macOS blocks it, use
    System Settings → Privacy & Security → Open Anyway.
    Before `brew uninstall`, use the app's menu → Uninstall Agent Aquarium… so it removes
    its hooks from ~/.claude/settings.json.
  EOS
end
