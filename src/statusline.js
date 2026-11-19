#!/usr/bin/env node
// Claude Code status line wrapper: saves the plan usage Claude Code reports (rate_limits: the 5-hour
// and weekly windows of claude.ai subscription plans) for the lock screen, then runs the status line the user had
// before (saved by setup-hooks.js) with the same input, so their status line looks exactly as it did.
// Never fails Claude Code: usage errors are ignored, and the user's command's output and exit code pass through.
const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawn } = require("child_process");

const DATA = process.env.CLAUDE_LOCKSCREEN_DIR || path.join(os.homedir(), ".claude", "lockscreen");
const USAGE = path.join(DATA, "usage.json");
const CHAIN = path.join(DATA, "statusline-chain.json");

function window(w) {
  const pct = Number(w && w.used_percentage), at = Number(w && w.resets_at);
  return Number.isFinite(pct) && Number.isFinite(at) ? { used: Math.max(0, Math.min(100, pct)), resets_at: at * 1000 } : null;
}

function saveUsage(input) {
  const r = input && input.rate_limits;
  const five = window(r && r.five_hour), week = window(r && r.seven_day);
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(USAGE, "utf8")); } catch {}
  // seen_at says the status line runs at all; reported_at says Claude Code shares plan usage for this account
  // (subscription plans; API-key billing has no such limits). Settings uses them to explain a missing card.
  const now = Date.now(), got = !!(five || week);
  if (!got && prev.seen_at && now - prev.seen_at < 60e3) return; // nothing new: skip the write
  // Claude Code leaves out a window once it has reset; keep the last value we saw, the page knows it's expired.
  const out = { five_hour: five || prev.five_hour || null, seven_day: week || prev.seven_day || null,
    updated_at: got ? now : prev.updated_at || 0, seen_at: now, reported_at: got ? now : prev.reported_at || 0 };
  fs.mkdirSync(DATA, { recursive: true });
  const tmp = `${USAGE}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(out));
  fs.renameSync(tmp, USAGE);
}

let raw = "";
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  try { saveUsage(JSON.parse(raw)); } catch {}
  let command = "";
  try { command = String(JSON.parse(fs.readFileSync(CHAIN, "utf8")).command || ""); } catch {}
  // Never run ourselves (a chain file pointing back at this wrapper would loop forever).
  if (!command || process.env.AGENT_AQUARIUM_STATUSLINE || /agent-aquarium-statusline|\/lockscreen\/app\/statusline\.js/.test(command)) process.exit(0);
  const env = { ...process.env, AGENT_AQUARIUM_STATUSLINE: "1" };
  const child = spawn("/bin/sh", ["-c", command], { stdio: ["pipe", "inherit", "inherit"], env });
  child.on("error", () => process.exit(0));
  child.on("exit", (code) => process.exit(code ?? 0));
  child.stdin.on("error", () => {});
  child.stdin.end(raw);
});
