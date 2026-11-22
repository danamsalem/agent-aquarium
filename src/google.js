// Google Calendar via "Sign in with Google": OAuth for installed apps (loopback redirect + PKCE)
// and the Calendar API. Read-only. Tokens live in ~/.claude/agent-aquarium/google.json (owner-only).
// The OAuth client ships with the app as google-client.json next to this file (the JSON Google
// Cloud downloads for a Desktop client). Desktop-app client secrets aren't confidential, per Google.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const calendar = require("./calendar");

const AUTH_URL = process.env.CLAUDE_LOCKSCREEN_GOOGLE_AUTH || "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = process.env.CLAUDE_LOCKSCREEN_GOOGLE_TOKEN || "https://oauth2.googleapis.com/token";
const REVOKE_URL = process.env.CLAUDE_LOCKSCREEN_GOOGLE_REVOKE || "https://oauth2.googleapis.com/revoke";
const API = process.env.CLAUDE_LOCKSCREEN_GOOGLE_API || "https://www.googleapis.com/calendar/v3";
// The narrowest read-only scopes for what the app does: list your calendars (to pick which to show) and read their events.
const SCOPES = {
  list: "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
  events: "https://www.googleapis.com/auth/calendar.events.readonly",
};
const SCOPE = Object.values(SCOPES).join(" ");
const BROAD = "https://www.googleapis.com/auth/calendar.readonly"; // what sign-ins before 0.10.2 granted; still works
const SOURCE_ID = "google";
// Not meetings: these block time on the calendar but shouldn't say "In a meeting".
const SKIP_TYPES = new Set(["workingLocation", "outOfOffice", "focusTime", "birthday"]);

let FILE, BUNDLED, redirectUri;
let state = {}; // { tokens: { access_token, refresh_token, expires_at }, email, calendars: [{ id, name, primary, selected }] }
const pending = new Map(); // OAuth state → { verifier, at }

function init({ dataDir, port }) {
  FILE = path.join(dataDir, "google.json");
  BUNDLED = path.join(__dirname, "google-client.json");
  redirectUri = `http://127.0.0.1:${port}/google/callback`;
  try { state = JSON.parse(fs.readFileSync(FILE, "utf8")); } catch { state = {}; }
  if (state.tokens && state.tokens.refresh_token) register();
}
function persist() {
  fs.writeFileSync(FILE, JSON.stringify(state, null, 2), { mode: 0o600 });
  fs.chmodSync(FILE, 0o600);
}
let bundledClient = null; // the file ships with the app: read it once found (every /status asks)
function client() {
  if (bundledClient) return bundledClient;
  try {
    const j = JSON.parse(fs.readFileSync(BUNDLED, "utf8"));
    const c = j.installed || j.web || j; // accepts the JSON file Google Cloud lets you download
    if (c.client_id) return (bundledClient = { id: c.client_id, secret: c.client_secret || "" });
  } catch {}
  return null;
}

// What the settings app sees. Never includes tokens or the client secret.
function status() {
  const c = client();
  return {
    configured: !!c,
    connected: !!(state.tokens && state.tokens.refresh_token),
    email: state.email || null,
    calendars: (state.calendars || []).map(({ id, name, primary, selected }) => ({ id, name, primary: !!primary, selected: !!selected })),
  };
}

/* ---------- sign-in ---------- */
const b64url = (buf) => buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
function startAuth() {
  const c = client();
  if (!c) throw new Error("Google sign-in isn't available in this version");
  const verifier = b64url(crypto.randomBytes(48));
  const st = b64url(crypto.randomBytes(18));
  for (const [k, v] of pending) if (Date.now() - v.at > 15 * 60e3) pending.delete(k);
  pending.set(st, { verifier, at: Date.now() });
  const q = new URLSearchParams({
    client_id: c.id, redirect_uri: redirectUri, response_type: "code", scope: SCOPE, state: st,
    code_challenge: b64url(crypto.createHash("sha256").update(verifier).digest()), code_challenge_method: "S256",
    access_type: "offline", prompt: "consent",
  });
  return `${AUTH_URL}?${q}`;
}

async function tokenRequest(params) {
  const c = client();
  const body = new URLSearchParams({ client_id: c.id, ...(c.secret ? { client_secret: c.secret } : {}), ...params });
  const r = await fetch(TOKEN_URL, { method: "POST", body, headers: { "content-type": "application/x-www-form-urlencoded" }, signal: AbortSignal.timeout(20e3) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error(j.error_description || j.error || `HTTP ${r.status}`); e.code = j.error; throw e; }
  return j;
}

// Google redirects the browser here after the user approves (or cancels).
async function handleCallback(query) {
  if (query.get("error")) throw new Error(query.get("error") === "access_denied" ? "Sign-in was cancelled." : `Google said: ${query.get("error")}`);
  const p = pending.get(query.get("state") || "");
  if (!p) throw new Error("This sign-in link expired. Start again from the Agent Aquarium app.");
  pending.delete(query.get("state"));
  const t = await tokenRequest({ grant_type: "authorization_code", code: query.get("code") || "", redirect_uri: redirectUri, code_verifier: p.verifier });
  if (!t.refresh_token) throw new Error("Google didn't grant offline access. Try signing in again.");
  const granted = String(t.scope || SCOPE).split(" ");
  if (!granted.includes(BROAD) && !Object.values(SCOPES).every((s) => granted.includes(s)))
    throw new Error("Calendar access wasn't fully granted. Tick both calendar boxes on Google's consent screen.");
  state.tokens = { access_token: t.access_token, refresh_token: t.refresh_token, expires_at: Date.now() + (t.expires_in || 3600) * 1e3 };
  persist();
  await refreshCalendars();
  register();
  return state.email;
}

async function accessToken() {
  const tk = state.tokens;
  if (!tk || !tk.refresh_token) throw new Error("Not signed in");
  if (tk.access_token && tk.expires_at - Date.now() > 60e3) return tk.access_token;
  try {
    const t = await tokenRequest({ grant_type: "refresh_token", refresh_token: tk.refresh_token });
    Object.assign(tk, { access_token: t.access_token, expires_at: Date.now() + (t.expires_in || 3600) * 1e3 });
    if (t.refresh_token) tk.refresh_token = t.refresh_token;
    persist();
    return tk.access_token;
  } catch (e) {
    if (e.code === "invalid_grant") throw new Error("Google signed you out (access was revoked or expired). Sign in again.");
    throw e;
  }
}

async function api(pathname, params = {}) {
  const url = `${API}${pathname}?${new URLSearchParams(params)}`;
  const r = await fetch(url, { headers: { authorization: `Bearer ${await accessToken()}` }, signal: AbortSignal.timeout(20e3) });
  const j = await r.json().catch(() => ({}));
  if (r.status === 401) { state.tokens.access_token = null; throw new Error("Google rejected the sign-in. Try Sync now, or sign in again."); }
  if (!r.ok) throw new Error((j.error && j.error.message) || `Google Calendar: HTTP ${r.status}`);
  return j;
}

// Your calendars. The primary one is shown by default; others are opt-in in settings.
async function refreshCalendars() {
  const items = [];
  let pageToken;
  do {
    const j = await api("/users/me/calendarList", { maxResults: "250", minAccessRole: "reader", ...(pageToken ? { pageToken } : {}) });
    items.push(...(j.items || []));
    pageToken = j.nextPageToken;
  } while (pageToken);
  const before = new Map((state.calendars || []).map((c) => [c.id, c.selected]));
  state.calendars = items.filter((c) => !c.deleted).map((c) => ({
    id: c.id, name: c.summaryOverride || c.summary || c.id, primary: !!c.primary,
    selected: before.has(c.id) ? before.get(c.id) : !!c.primary,
  })).sort((a, b) => b.primary - a.primary || a.name.localeCompare(b.name));
  const primary = items.find((c) => c.primary);
  if (primary) state.email = primary.id;
  state.calendarsAt = Date.now();
  persist();
}

function setSelected(ids) {
  const want = new Set(ids || []);
  for (const c of state.calendars || []) c.selected = want.has(c.id);
  persist();
  const f = calendar.feeds.get(SOURCE_ID);
  if (f) calendar.sync(f);
}

/* ---------- events ---------- */
function toInstance(e) {
  if (e.status === "cancelled" || e.transparency === "transparent" || SKIP_TYPES.has(e.eventType)) return null;
  if ((e.attendees || []).some((a) => a.self && a.responseStatus === "declined")) return null;
  const allDay = !!(e.start && e.start.date && !e.start.dateTime);
  const at = (x) => {
    if (x.dateTime) return Date.parse(x.dateTime);
    const [y, m, d] = x.date.split("-").map(Number);
    return new Date(y, m - 1, d).getTime(); // all-day: this Mac's midnight
  };
  if (!e.start || !e.end) return null;
  return { title: (e.summary || "").trim() || "Busy", start: at(e.start), end: at(e.end), allDay };
}

async function load(from, to) {
  if (Date.now() - (state.calendarsAt || 0) > 6 * 3600e3) await refreshCalendars();
  const cals = (state.calendars || []).filter((c) => c.selected);
  const events = [];
  await Promise.all(cals.map(async (c) => {
    let pageToken;
    do {
      const j = await api(`/calendars/${encodeURIComponent(c.id)}/events`, {
        timeMin: new Date(from).toISOString(), timeMax: new Date(to).toISOString(),
        singleEvents: "true", orderBy: "startTime", maxResults: "250", showDeleted: "false",
        fields: "nextPageToken,items(status,summary,start,end,transparency,eventType,attendees(self,responseStatus))",
        ...(pageToken ? { pageToken } : {}),
      });
      for (const e of j.items || []) { const i = toInstance(e); if (i) events.push(i); }
      pageToken = j.nextPageToken;
    } while (pageToken);
  }));
  return { name: state.email || "Google Calendar", events: events.sort((a, b) => a.start - b.start) };
}

function register() {
  return calendar.addSource({ id: SOURCE_ID, name: state.email || "Google Calendar", kind: "google", host: "Google Calendar", load });
}

async function disconnect() {
  const token = state.tokens && (state.tokens.refresh_token || state.tokens.access_token);
  calendar.removeSource(SOURCE_ID);
  delete state.tokens; delete state.email; delete state.calendars; delete state.calendarsAt;
  persist();
  if (token) {
    try { await fetch(REVOKE_URL, { method: "POST", body: new URLSearchParams({ token }), signal: AbortSignal.timeout(10e3) }); } catch {}
  }
}

module.exports = { init, status, startAuth, handleCallback, setSelected, disconnect, refreshCalendars };
