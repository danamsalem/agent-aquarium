#!/usr/bin/env node
// Claude Code hook: records each session's live state for the lock screen.
// Wired to SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest,
// Notification, PreCompact, Stop and SessionEnd. Never blocks Claude: always exits 0, prints nothing.
const fs = require("fs");
const path = require("path");
const os = require("os");

const DIR = path.join(process.env.CLAUDE_LOCKSCREEN_DIR || path.join(os.homedir(), ".claude", "agent-aquarium-dev"), "sessions");

let raw = "";
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  try { handle(JSON.parse(raw)); } catch {}
  process.exit(0);
});

const base = (p) => (p ? path.basename(String(p)) : "");
const human = (s) => String(s).replace(/[_-]+/g, " ").replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase();
const cut = (s, n = 70) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

function describe(tool, input = {}) {
  switch (tool) {
    case "Bash": return input.description || `Running ${String(input.command || "").trim().split(/\s+/)[0] || "a command"}`;
    case "Read": return `Reading ${base(input.file_path)}`;
    case "Edit": case "MultiEdit": return `Editing ${base(input.file_path)}`;
    case "Write": return `Writing ${base(input.file_path)}`;
    case "NotebookEdit": return `Editing ${base(input.notebook_path)}`;
    case "Grep": return "Searching the code";
    case "Glob": return "Finding files";
    case "WebFetch": try { return `Reading ${new URL(input.url).hostname}`; } catch { return "Reading a web page"; }
    case "WebSearch": return "Searching the web";
    case "Task": case "Agent": return `Delegating: ${input.description || "subagent"}`;
    case "TodoWrite": return "Updating the plan";
    case "Skill": return `Using the ${input.skill} skill`;
  }
  if (tool.startsWith("mcp__")) {
    const [, server = "", name = ""] = tool.split("__");
    if (/browser|chrome/i.test(server)) return `Browsing: ${human(name)}`;
    if (/slack/i.test(name)) return "Working in Slack";
    if (/jira|confluence/i.test(name)) return `Atlassian: ${human(name)}`;
    return cut(`Using ${human(name || server)}`);
  }
  return `Using ${tool}`;
}

// Keeps s.plan in sync with Claude's task list: Claude Code's TodoWrite, or the desktop
// app's update_plan (full lists or advance/done/start deltas) and wrap_up (checks everything off).
// Returns true when the tool was a plan update.
function trackPlan(s, tool, input = {}) {
  const step = (text, status) => ({ text: cut(String(text || ""), 90), status: status || "pending" });
  if (tool === "TodoWrite" && Array.isArray(input.todos)) {
    s.plan = input.todos.map((t) => step(t.content, t.status));
    return true;
  }
  if (tool.endsWith("__update_plan")) {
    if (Array.isArray(input.items)) { s.plan = input.items.map((i) => step(i.content, i.status)); return true; }
    const plan = s.plan || [];
    if (input.advance) {
      const cur = plan.findIndex((p) => p.status === "in_progress");
      if (cur >= 0) plan[cur].status = "completed";
      const next = plan.findIndex((p, i) => i > cur && p.status === "pending");
      if (next >= 0) plan[next].status = "in_progress";
    }
    for (const n of input.done || []) if (plan[n - 1]) plan[n - 1].status = "completed";
    if (input.start && plan[input.start - 1]) {
      for (const p of plan) if (p.status === "in_progress") p.status = "pending";
      plan[input.start - 1].status = "in_progress";
    }
    return true;
  }
  if (tool.endsWith("__wrap_up") && s.plan) {
    for (const p of s.plan) p.status = "completed";
    return true;
  }
  return false;
}

// A turn that ends on a question to the user is "needs you", not "done": the desktop app's
// wrap_up box with an `ask`, or a final message ending in "?". The text comes from the Stop
// event's last_assistant_message, or else from the last assistant entry in the transcript.
function lastAssistantText(e) {
  if (typeof e.last_assistant_message === "string") return e.last_assistant_message;
  try {
    const fd = fs.openSync(e.transcript_path, "r");
    const size = fs.fstatSync(fd).size, len = Math.min(size, 262144), buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    fs.closeSync(fd);
    const lines = buf.toString("utf8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      let entry; try { entry = JSON.parse(lines[i]); } catch { continue; }
      if (entry.type !== "assistant") continue;
      const content = entry.message && entry.message.content;
      if (typeof content === "string") return content;
      return (content || []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
    }
  } catch {}
  return "";
}
// The session's name in the Claude desktop app (or from /rename): the transcript's latest "custom-title" entry,
// which Claude Code writes again every few turns, so the file's tail has it.
function sessionTitle(transcript) {
  try {
    const fd = fs.openSync(transcript, "r");
    const size = fs.fstatSync(fd).size, len = Math.min(size, 262144), buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    fs.closeSync(fd);
    const lines = buf.toString("utf8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].includes('"custom-title"')) continue;
      try { const t = JSON.parse(lines[i]).customTitle; if (typeof t === "string" && t.trim()) return t.trim(); } catch {}
    }
  } catch {}
  return "";
}

const endsWithQuestion =(text) => /[?？؟]$/.test(String(text || "").replace(/[\s*_`>)\]"'”’]+$/u, ""));

function handle(e) {
  const id = String(e.session_id || "unknown").replace(/[^\w-]/g, "");
  const file = path.join(DIR, `${id}.json`);
  const ev = e.hook_event_name;
  if (ev === "SessionEnd") { try { fs.unlinkSync(file); } catch {} return; }

  fs.mkdirSync(DIR, { recursive: true });
  let s;
  try { s = JSON.parse(fs.readFileSync(file, "utf8")); } catch { s = { id, state: "idle", action: "Ready" }; }
  const now = Date.now();
  if (e.cwd) s.cwd = e.cwd;
  if (e.transcript_path) s.transcript = e.transcript_path; // the server watches it for a stop (see server.js)
  s.project = base(s.cwd) || "claude";
  if (s.transcript && (ev === "SessionStart" || ev === "UserPromptSubmit" || ev === "Stop")) s.title = sessionTitle(s.transcript) || s.title;

  switch (ev) {
    case "SessionStart":
      if (e.source !== "compact") Object.assign(s, { state: "idle", action: "Ready" });
      break;
    case "UserPromptSubmit":
      Object.assign(s, { state: "thinking", action: "Thinking", task_started: now, done_at: null, tools: 0 });
      delete s.ask;
      if (s.plan && s.plan.every((p) => p.status === "completed")) delete s.plan;
      break;
    case "PreToolUse": {
      s.tools = (s.tools || 0) + 1;
      if (!s.task_started) s.task_started = now;
      const tool = e.tool_name || "";
      if (tool.endsWith("__wrap_up") && e.tool_input && e.tool_input.ask) s.ask = cut(String(e.tool_input.ask));
      else delete s.ask;
      if (tool === "AskUserQuestion") Object.assign(s, { state: "waiting", action: "Asking you a question" });
      else if (tool === "ExitPlanMode") Object.assign(s, { state: "waiting", action: "Waiting for plan approval" });
      else if (trackPlan(s, tool, e.tool_input)) {
        const cur = (s.plan || []).find((p) => p.status === "in_progress");
        Object.assign(s, { state: "working", action: cur ? cur.text : "Planning" });
      } else Object.assign(s, { state: "working", action: cut(describe(tool, e.tool_input)) });
      break;
    }
    case "PostToolUse":
    case "PostToolUseFailure":
      if (s.state !== "done") Object.assign(s, { state: "thinking", action: "Thinking" });
      break;
    case "PermissionRequest":
      Object.assign(s, { state: "waiting", action: cut(`Needs permission: ${describe(e.tool_name || "", e.tool_input)}`) });
      break;
    case "Notification": {
      const type = e.notification_type || "";
      const msg = String(e.message || "");
      // Claude has been waiting for input for a minute. Mid-turn that means you stopped it (Claude Code sends
      // no Stop event for an interrupt), so it isn't working any more.
      if (type === "idle_prompt") { if (s.state === "working" || s.state === "thinking") Object.assign(s, { state: "idle", action: "Stopped" }); break; }
      if (type === "auth_success") break;
      if (type === "permission_prompt" || type === "elicitation_dialog" || /permission|waiting for your input/i.test(msg)) {
        Object.assign(s, { state: "waiting", action: cut(msg || "Waiting for you") });
      }
      break;
    }
    case "PreCompact":
      s.action = "Compacting context";
      break;
    case "Stop":
      if (s.ask || endsWithQuestion(lastAssistantText(e))) Object.assign(s, { state: "waiting", action: s.ask || "Asking you a question", done_at: null });
      else Object.assign(s, { state: "done", action: "Finished", done_at: now });
      delete s.ask;
      break;
  }
  s.updated_at = now;

  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(s));
  fs.renameSync(tmp, file);
}
