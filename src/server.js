#!/usr/bin/env node
// Serves the lock screen page and the live state written by hook.js.
const http = require("http");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFile, spawn } = require("child_process");
const crypto = require("crypto");
const calendar = require("./calendar");
const google = require("./google");
const battery = require("./battery");

const PORT = Number(process.env.CLAUDE_LOCKSCREEN_PORT) || 4777;
const DATA = process.env.CLAUDE_LOCKSCREEN_DIR || path.join(os.homedir(), ".claude", "agent-aquarium-dev");
const SESSIONS = path.join(DATA, "sessions");
const CONFIG = path.join(DATA, "config.json");
const USAGE = path.join(DATA, "usage.json"); // written by statusline.js
const CLAUDE_SETTINGS = path.join(os.homedir(), ".claude", "settings.json");
const PAGE = path.join(__dirname, "index.html");
const SETTINGS_PAGE = path.join(__dirname, "settings.html");
const THEMES = ["aquarium", "warm", "pixel", "cosmic"]; // in the order settings lists them; the first is the default
function themes() {
  const list = THEMES.slice();
  return list;
}
const DAY = 24 * 3600e3;
const MAX_PRESETS = 24;
const MAX_CALENDARS = 8;
// Starter presets until the user saves their own list.
const DEFAULT_PRESETS = ["Back in 10 min, grabbing coffee ☕", "In a meeting 📅", "Lunch break 🥗", "Deep work. My agents are on it 🦀", "Gone for the day, see you tomorrow 👋"];

fs.mkdirSync(SESSIONS, { recursive: true });

function readConfig() {
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(CONFIG, "utf8")); } catch {}
  if (!Array.isArray(cfg.presets)) cfg.presets = DEFAULT_PRESETS;
  if (!Array.isArray(cfg.calendars)) cfg.calendars = [];
  return cfg;
}
function writeConfig(cfg) {
  fs.writeFileSync(CONFIG, JSON.stringify(cfg, null, 2), { mode: 0o600 }); // holds secret calendar addresses
  fs.chmodSync(CONFIG, 0o600);
}
// Config as pages see it: calendar addresses are secrets and stay on the server.
function publicConfig() {
  const { calendars, ...cfg } = readConfig();
  const available = themes();
  // No saved theme, or one that isn't on the list any more, uses the default (a saved one comes back if it returns).
  return { ...cfg, theme: available.includes(cfg.theme) ? cfg.theme : THEMES[0], themes: available };
}

function cleanPresets(list) {
  const seen = new Set();
  return list
    .filter((p) => typeof p === "string")
    .map((p) => p.trim().slice(0, 140))
    .filter((p) => p && !seen.has(p) && seen.add(p))
    .slice(0, MAX_PRESETS);
}

// Every page polls /status each second, so a session file is read again only when it changed (hook.js replaces the
// whole file, so its modification time and size tell).
const sessionText = new Map(); // file -> { mtimeMs, size, text }
function readSessions() {
  const now = Date.now();
  const out = [];
  const files = fs.readdirSync(SESSIONS).filter((f) => f.endsWith(".json")).map((f) => path.join(SESSIONS, f));
  for (const file of sessionText.keys()) if (!files.includes(file)) sessionText.delete(file);
  for (const file of files) {
    try {
      const st = fs.statSync(file);
      let c = sessionText.get(file);
      if (!c || c.mtimeMs !== st.mtimeMs || c.size !== st.size) sessionText.set(file, (c = { mtimeMs: st.mtimeMs, size: st.size, text: fs.readFileSync(file, "utf8") }));
      const s = JSON.parse(c.text);
      if (now - (s.updated_at || 0) > DAY) { fs.unlinkSync(file); continue; }
      if (wasStopped(s, now)) {
        Object.assign(s, { state: "idle", action: "Stopped", updated_at: now });
        const tmp = `${file}.${process.pid}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(s));
        fs.renameSync(tmp, file);
      }
      out.push(s);
    } catch {}
  }
  return out;
}

// Stopping Claude mid-turn (Esc, or the stop button) sends no hook event, so a stopped session would look busy
// until it went stale. Claude Code does write "[Request interrupted by user]" to the session's transcript: for a
// session that says it's working, look at the transcript's last message whenever the file changes.
const transcriptSeen = new Map(); // transcript path -> size last checked
function wasStopped(s, now) {
  if ((s.state !== "working" && s.state !== "thinking") || !s.transcript || now - (s.updated_at || 0) < 1500) return false;
  try {
    if (transcriptSeen.get(s.transcript) === fs.statSync(s.transcript).size) return false; // unchanged: not even opened
    const fd = fs.openSync(s.transcript, "r");
    try {
      const size = fs.fstatSync(fd).size;
      if (transcriptSeen.get(s.transcript) === size) return false;
      transcriptSeen.set(s.transcript, size);
      const len = Math.min(size, 65536), buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, size - len);
      const lines = buf.toString("utf8").split("\n");
      for (let i = lines.length - 1; i >= 0; i--) {
        let entry; try { entry = JSON.parse(lines[i]); } catch { continue; }
        if (entry.type !== "user" && entry.type !== "assistant") continue;
        if (entry.type === "assistant") return false;
        const c = entry.message && entry.message.content;
        const text = typeof c === "string" ? c : Array.isArray(c) && c[0] && c[0].type === "text" ? c[0].text : "";
        return /^\[Request interrupted by user/.test(String(text));
      }
    } finally { fs.closeSync(fd); }
  } catch {}
  return false;
}

// Claude plan usage as the status line last saw it, and whether that status line is still ours
// (Claude Code's /statusline command, or the user, can replace it).
function readUsage() {
  let u = null, connected = false;
  try { u = JSON.parse(fs.readFileSync(USAGE, "utf8")); } catch {}
  try { connected = /agent-aquarium-statusline|\/lockscreen\/app\/statusline\.js/.test(String(JSON.parse(fs.readFileSync(CLAUDE_SETTINGS, "utf8")).statusLine?.command || "")); } catch {}
  return { connected, five_hour: u?.five_hour || null, seven_day: u?.seven_day || null, updated_at: u?.updated_at || 0,
    seen_at: u?.seen_at || 0, reported_at: u?.reported_at || 0 };
}

function send(res, code, body) {
  res.writeHead(code, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

// A JSON content type forces a CORS preflight, so other websites can't post to these routes.
function readJson(req, res, then) {
  if (!String(req.headers["content-type"]).startsWith("application/json")) return send(res, 415, { error: "json only" });
  let body = "";
  req.on("data", (c) => { body += c; if (body.length > 2e4) req.destroy(); });
  req.on("end", () => {
    let data;
    try { data = JSON.parse(body); } catch { return send(res, 400, { error: "bad json" }); }
    Promise.resolve().then(() => then(data)).catch((e) => { if (!res.headersSent) send(res, 500, { error: String(e.message || e) }); });
  });
}

function updateConfig(req, res) {
  readJson(req, res, (patch) => {
    const cfg = readConfig();
    if (themes().includes(patch.theme)) cfg.theme = patch.theme;
    if (typeof patch.customText === "string") cfg.customText = patch.customText.slice(0, 140);
    if (typeof patch.showDetails === "boolean") cfg.showDetails = patch.showDetails;
    if (typeof patch.sessionNames === "boolean") cfg.sessionNames = patch.sessionNames;
    if (Array.isArray(patch.presets)) cfg.presets = cleanPresets(patch.presets);
    if (typeof patch.calTitles === "boolean") cfg.calTitles = patch.calTitles;
    if (typeof patch.showUsage === "boolean") cfg.showUsage = patch.showUsage;
    if (typeof patch.keepAwake === "boolean") cfg.keepAwake = patch.keepAwake;
    if (typeof patch.powerSaver === "boolean") cfg.powerSaver = patch.powerSaver;
    writeConfig(cfg);
    updateAwake();
    send(res, 200, publicConfig());
  });
}

// Adds an iCal address after checking it really is a calendar we can read.
function addCalendar(req, res) {
  readJson(req, res, async ({ url }) => {
    const cfg = readConfig();
    const clean = calendar.normalizeUrl(url);
    if (!clean) return send(res, 400, { error: "Paste a calendar address starting with https:// or webcal://" });
    if (cfg.calendars.some((c) => c.url === clean)) return send(res, 409, { error: "That calendar is already connected" });
    if (cfg.calendars.length >= MAX_CALENDARS) return send(res, 400, { error: `Up to ${MAX_CALENDARS} calendars` });
    const probe = await calendar.sync({ id: "probe", url: clean, events: [] });
    if (!probe.ok) return send(res, 422, { error: probe.error });
    const entry = { id: crypto.randomBytes(6).toString("hex"), url: clean, name: probe.name };
    cfg.calendars.push(entry);
    writeConfig(cfg);
    calendar.setFeeds(cfg.calendars);
    Object.assign(calendar.feeds.get(entry.id), { ok: true, name: probe.name, syncedAt: probe.syncedAt, events: probe.events });
    send(res, 200, calendar.snapshot());
  });
}
function removeCalendar(req, res) {
  readJson(req, res, ({ id }) => {
    const cfg = readConfig();
    cfg.calendars = cfg.calendars.filter((c) => c.id !== id);
    writeConfig(cfg);
    calendar.setFeeds(cfg.calendars);
    send(res, 200, calendar.snapshot());
  });
}
/* ---------- Keep the Mac awake while agents work ---------- */
// With "Keep Mac awake" on, macOS's own caffeinate holds off idle sleep (-i: the system only, so the display still
// sleeps and the screensaver and locking work as usual) while a session is actively working, and lets go when none is.
// "Actively" matches the lock screen: a working session that hasn't reported for a while has probably stalled (an
// interrupted turn sends no Stop), so it stops counting after 5 min of thinking or 20 min inside one tool.
// -w ties caffeinate to this server, so it never outlives it.
let caffeinate = null;
function workingSessions(list = readSessions(), now = Date.now()) {
  return list.filter((s) => (s.state === "working" || s.state === "thinking") &&
    now - (s.updated_at || 0) <= (s.state === "thinking" ? 5 : 20) * 60e3).length;
}
function awakeStatus(list) {
  const working = workingSessions(list);
  return { on: readConfig().keepAwake === true, holding: !!caffeinate, working };
}
function updateAwake() {
  const want = process.platform === "darwin" && readConfig().keepAwake === true && workingSessions() > 0;
  if (want && !caffeinate) {
    caffeinate = spawn("/usr/bin/caffeinate", ["-i", "-w", String(process.pid)], { stdio: "ignore" });
    caffeinate.on("error", () => { caffeinate = null; });
    caffeinate.on("exit", function () { if (caffeinate === this) caffeinate = null; });
  } else if (!want && caffeinate) {
    caffeinate.kill();
    caffeinate = null;
  }
}

/* ---------- Sign in with Google ---------- */
function googleRoute(req, res, action) {
  readJson(req, res, async (body) => {
    try {
      if (action === "connect") {
        const url = google.startAuth();
        // Google blocks sign-in inside embedded web views, so it opens in the default browser.
        if (!process.env.CLAUDE_LOCKSCREEN_NO_OPEN) execFile("/usr/bin/open", [url]);
        return send(res, 200, { url, google: google.status() });
      }
      if (action === "calendars") google.setSelected(body.ids);
      if (action === "disconnect") await google.disconnect();
      send(res, 200, { google: google.status(), calendar: calendar.snapshot() });
    } catch (e) {
      send(res, 400, { error: String(e.message || e) });
    }
  });
}
function callbackPage(ok, text) {
  const color = ok ? "#2f8f5b" : "#c0392b";
  return `<!doctype html><meta charset="utf-8"><title>Agent Aquarium</title><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f5f4ef;color:#1f1e1d;font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}
@media(prefers-color-scheme:dark){body{background:#1b1a19;color:#f0eee6}}main{max-width:440px;padding:32px;text-align:center}
.i{width:52px;height:52px;border-radius:50%;margin:0 auto 16px;display:grid;place-items:center;background:${color};color:#fff;font-size:26px}h1{font-size:20px;margin:0 0 6px}p{margin:0;opacity:.7}</style>
<main><div class="i">${ok ? "✓" : "!"}</div><h1>${ok ? "Google Calendar connected" : "Couldn't connect Google Calendar"}</h1><p>${text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)}</p></main>`;
}
async function googleCallback(req, res, query) {
  let ok = true, text;
  try {
    const email = await google.handleCallback(query);
    text = `Signed in${email ? ` as ${email}` : ""}. Your meetings will show on the lock screen. You can close this tab.`;
  } catch (e) { ok = false; text = String(e.message || e); }
  res.writeHead(ok ? 200 : 400, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
  res.end(callbackPage(ok, text));
}

/* ---------- Update check ---------- */
// About once a day, one GET to the website's latest.json, which names the current version and where to get it.
// Nothing is sent but the request itself. The app is still replaced by hand; this only tells you when to.
let UPDATE_URL = "https://agentaquarium.danamsalem.com/latest.json";
let DOWNLOAD_URL = null; // where "Update available" leads; null: the url latest.json names
if (process.env.CLAUDE_LOCKSCREEN_UPDATE_URL) UPDATE_URL = process.env.CLAUDE_LOCKSCREEN_UPDATE_URL; // for testing
// The app's version, from the Info.plist of the app that bundles this server (aquarium-node lives in Contents/MacOS).
// Unknown when running from source (node server.js): no update check then.
const APP_VERSION = process.env.CLAUDE_LOCKSCREEN_VERSION || (() => {
  try {
    const plist = fs.readFileSync(path.join(path.dirname(process.execPath), "..", "Info.plist"), "utf8");
    return /<key>CFBundleShortVersionString<\/key>\s*<string>([\d.]+)<\/string>/.exec(plist)?.[1] || null;
  } catch { return null; }
})();
let update = null; // { version, url } when a newer version is out
const newer = (a, b) => { // is version a newer than b?
  const x = a.split(".").map(Number), y = b.split(".").map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
  return false;
};
// latest.json may only point at this project's GitHub pages. Parsed, so "/../" can't leave the path.
function isUpdatePage(url) {
  try {
    const u = new URL(url);
    return u.origin === "https://github.com" && u.pathname.startsWith("/danamsalem/agent-aquarium/");
  } catch { return false; }
}
async function checkForUpdate() {
  if (!APP_VERSION) return;
  try {
    const res = await fetch(UPDATE_URL, { signal: AbortSignal.timeout(15e3), cache: "no-store" });
    const latest = await res.json();
    const ok = typeof latest.version === "string" && /^\d+(\.\d+)*$/.test(latest.version) && isUpdatePage(latest.url);
    update = ok && newer(latest.version, APP_VERSION) ? { version: latest.version, url: DOWNLOAD_URL || latest.url } : null;
  } catch { /* offline: try again next time */ }
}

function syncCalendars(req, res) {
  readJson(req, res, async () => {
    await Promise.all([...calendar.feeds.values()].map(calendar.sync));
    send(res, 200, calendar.snapshot());
  });
}

// Only our own addresses: a website that points its domain at 127.0.0.1 (DNS rebinding) sends its own Host and is refused.
const ALLOWED_HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`]);

const server = http.createServer((req, res) => {
  if (!ALLOWED_HOSTS.has(String(req.headers.host || "").toLowerCase())) return send(res, 403, { error: "forbidden" });
  const { pathname } = new URL(req.url, "http://localhost");
  if (req.method === "GET" && pathname === "/status") {
    battery.markShown(new URL(req.url, "http://localhost").searchParams.get("shown"));
    const cfg = publicConfig();
    // "Use session names" (on by default): label each agent by its Claude session name, else by its folder.
    const sessions = readSessions().map((s) => (cfg.sessionNames !== false && s.title ? { ...s, project: s.title } : s));
    return send(res, 200, { now: Date.now(), sessions, config: cfg, calendar: calendar.snapshot(), google: google.status(), usage: readUsage(), battery: battery.summary(), awake: awakeStatus(sessions), version: APP_VERSION, update });
  }
  if (req.method === "POST" && pathname === "/config") return updateConfig(req, res);
  if (req.method === "POST" && pathname === "/update/open") { // the settings window can't open web pages itself
    if (update && !process.env.CLAUDE_LOCKSCREEN_NO_OPEN) execFile("/usr/bin/open", [update.url]);
    return send(res, 200, { update });
  }
  if (req.method === "POST" && pathname === "/calendars/add") return addCalendar(req, res);
  if (req.method === "POST" && pathname === "/calendars/remove") return removeCalendar(req, res);
  if (req.method === "POST" && pathname === "/calendars/sync") return syncCalendars(req, res);
  const g = /^\/google\/(connect|calendars|disconnect)$/.exec(pathname);
  if (req.method === "POST" && g) return googleRoute(req, res, g[1]);
  if (req.method === "GET" && pathname === "/google/callback") return googleCallback(req, res, new URL(req.url, "http://localhost").searchParams);
  if (req.method === "GET" && pathname === "/settings") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    return fs.createReadStream(SETTINGS_PAGE).pipe(res);
  }
  if (req.method === "GET" && (pathname === "/" || pathname === "/index.html")) {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    return fs.createReadStream(PAGE).pipe(res);
  }
  send(res, 404, { error: "not found" });
});

calendar.setFeeds(readConfig().calendars);
google.init({ dataDir: DATA, port: PORT });
battery.init({ dataDir: DATA, currentTheme: () => publicConfig().theme });
setInterval(updateAwake, 10e3).unref();
updateAwake();
setTimeout(checkForUpdate, 20e3).unref(); // the server restarts whenever the app opens, so this also runs then
setInterval(checkForUpdate, DAY).unref();

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Agent Aquarium: http://127.0.0.1:${PORT}  (data: ${DATA})`);
});
