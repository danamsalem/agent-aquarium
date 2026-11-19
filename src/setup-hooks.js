#!/usr/bin/env node
// Adds (or with --uninstall removes) the lock screen hook in ~/.claude/settings.json, plus the status
// line wrapper (statusline.js) that saves Claude's plan usage. The user's own status line keeps working:
// it's saved in statusline-chain.json and the wrapper runs it; uninstalling puts it back.
// Usage: node setup-hooks.js <node-binary> <hook.js path> [--no-usage]   |   node setup-hooks.js --uninstall
// The app runs it as: aquarium-node setup-hooks <aquarium-node path> agent-aquarium-hook
const fs = require("fs");
const path = require("path");
const os = require("os");

const SETTINGS = path.join(os.homedir(), ".claude", "settings.json");
const DATA = process.env.CLAUDE_LOCKSCREEN_DIR || path.join(os.homedir(), ".claude", "lockscreen");
const CHAIN = path.join(DATA, "statusline-chain.json");
// The app's status line mode, and statusline.js from the script install (~/.claude/lockscreen/app). Only
// these: plenty of people call their own script statusline.js, and that one must never count as ours.
const STATUSLINE_MARKERS = ["agent-aquarium-statusline", "/lockscreen/app/statusline.js"];
const isOurs = (sl) => !!sl && STATUSLINE_MARKERS.some((m) => String(sl.command || "").includes(m));
// Hooks from the script install (node + hook.js), the app while it was called Agent Fishtank
// (fishtank-node agent-fishtank-hook) and the app now (aquarium-node agent-aquarium-hook).
const MARKERS = ["lockscreen/app/hook.js", "agent-fishtank-hook", "agent-aquarium-hook"];
const EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "PreCompact", "Stop", "SessionEnd"];
const WITH_MATCHER = new Set(["PreToolUse", "PostToolUse", "PermissionRequest"]);

const settings = fs.existsSync(SETTINGS) ? JSON.parse(fs.readFileSync(SETTINGS, "utf8")) : {};
if (fs.existsSync(SETTINGS) && !fs.existsSync(`${SETTINGS}.bak-lockscreen`)) fs.copyFileSync(SETTINGS, `${SETTINGS}.bak-lockscreen`);
const hooks = settings.hooks || {};

// Drop any previous lock screen entries so re-running is idempotent.
for (const ev of Object.keys(hooks)) {
  hooks[ev] = hooks[ev]
    .map((group) => ({ ...group, hooks: (group.hooks || []).filter((h) => !MARKERS.some((m) => String(h.command || "").includes(m))) }))
    .filter((group) => group.hooks.length);
  if (!hooks[ev].length) delete hooks[ev];
}

// Takes our status line out, putting back the one it wraps (if any).
function removeStatusLine() {
  if (!isOurs(settings.statusLine)) return;
  let chained = null;
  try { chained = JSON.parse(fs.readFileSync(CHAIN, "utf8")).statusLine || null; } catch {}
  if (chained && chained.command) settings.statusLine = chained; else delete settings.statusLine;
  try { fs.unlinkSync(CHAIN); } catch {}
}

const [first, ...rest] = process.argv.slice(2);
const usage = !rest.includes("--no-usage");
if (first === "--uninstall") removeStatusLine();
else {
  const [node, hookPath] = [first, rest[0]];
  const command = `"${node}" "${hookPath}"`;
  for (const ev of EVENTS) {
    const group = { hooks: [{ type: "command", command, timeout: 5 }] };
    if (WITH_MATCHER.has(ev)) group.matcher = "*";
    (hooks[ev] = hooks[ev] || []).push(group);
  }
  if (!usage) removeStatusLine();
  else {
    // The app's binary has a status line mode; the script install has statusline.js next to hook.js.
    const wrapper = hookPath === "agent-aquarium-hook" ? `"${node}" "agent-aquarium-statusline"` : `"${node}" "${path.join(path.dirname(hookPath), "statusline.js")}"`;
    const prev = settings.statusLine;
    if (!isOurs(prev)) {
      fs.mkdirSync(DATA, { recursive: true });
      fs.writeFileSync(CHAIN, JSON.stringify({ statusLine: prev && prev.command ? prev : null, command: (prev && prev.command) || "" }, null, 2) + "\n");
    }
    // Keep the user's other status line options (padding, refreshInterval); only the command is ours.
    settings.statusLine = { ...(prev || {}), type: "command", command: wrapper };
  }
}

if (Object.keys(hooks).length) settings.hooks = hooks; else delete settings.hooks;
fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + "\n");
console.log(first === "--uninstall" ? "Removed lock screen hooks and status line." : `Added lock screen hooks for ${EVENTS.length} events${usage ? " and the plan usage status line" : ""}.`);
console.log(`Backup: ${SETTINGS}.bak-lockscreen`);
