// Calendar feeds for the lock screen: fetches iCal (.ics) addresses, such as Google Calendar's
// "secret address in iCal format" or an Apple/iCloud public calendar link, and expands them into
// the meetings around now. No dependencies; handles time zones, recurring events, exceptions,
// cancelled and declined meetings, and events marked "free".
const SYNC_MS = 5 * 60e3;
const BACK_MS = 24 * 3600e3, AHEAD_MS = 3 * 24 * 3600e3; // the window of instances kept
const MAX_BYTES = 30e6;
const DAY = 86400e3;
const WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];

/* ---------- parsing ---------- */
function unfold(text) { return text.replace(/\r\n/g, "\n").replace(/\n[ \t]/g, ""); }
function unescapeText(v) { return v.replace(/\\([\\;,nN])/g, (_, c) => (c === "n" || c === "N" ? "\n" : c)); }

// "DTSTART;TZID=Europe/Paris:20261016T090000" → { name, params: { TZID }, value }
function parseLine(line) {
  let i = 0, inQuote = false;
  for (; i < line.length; i++) {
    const c = line[i];
    if (c === '"') inQuote = !inQuote;
    else if (c === ":" && !inQuote) break;
  }
  const head = line.slice(0, i), value = line.slice(i + 1);
  const [name, ...rawParams] = head.split(/;(?=(?:[^"]*"[^"]*")*[^"]*$)/);
  const params = {};
  for (const p of rawParams) {
    const eq = p.indexOf("=");
    if (eq > 0) params[p.slice(0, eq).toUpperCase()] = p.slice(eq + 1).replace(/^"|"$/g, "");
  }
  return { name: name.toUpperCase(), params, value };
}

// A date-time as wall-clock parts plus how to place it: UTC ("Z"), a named zone, or floating.
function parseDate(prop) {
  if (!prop) return null;
  const v = prop.value.trim();
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$/.exec(v);
  if (!m) return null;
  const allDay = prop.params.VALUE === "DATE" || !m[4];
  return {
    wall: Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0)),
    tz: m[7] ? "UTC" : prop.params.TZID || null,
    allDay,
  };
}

function parseDuration(v) {
  const m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(String(v || "").trim());
  if (!m) return null;
  const ms = ((+m[2] || 0) * 7 * DAY) + ((+m[3] || 0) * DAY) + ((+m[4] || 0) * 3600e3) + ((+m[5] || 0) * 60e3) + ((+m[6] || 0) * 1e3);
  return m[1] === "-" ? -ms : ms;
}

function parseRRule(v) {
  const r = {};
  for (const part of v.split(";")) {
    const [k, val] = part.split("=");
    if (k && val !== undefined) r[k.toUpperCase()] = val;
  }
  return {
    freq: r.FREQ,
    interval: Math.max(1, +r.INTERVAL || 1),
    count: r.COUNT ? +r.COUNT : null,
    until: r.UNTIL ? parseDate({ value: r.UNTIL, params: {} }) : null,
    byDay: r.BYDAY ? r.BYDAY.split(",").map((d) => { const m = /^([+-]?\d+)?([A-Z]{2})$/.exec(d.trim()); return m && { n: m[1] ? +m[1] : 0, wd: WEEKDAYS.indexOf(m[2]) }; }).filter((d) => d && d.wd >= 0) : null,
    byMonthDay: r.BYMONTHDAY ? r.BYMONTHDAY.split(",").map(Number) : null,
    byMonth: r.BYMONTH ? r.BYMONTH.split(",").map((n) => +n - 1) : null,
    bySetPos: r.BYSETPOS ? r.BYSETPOS.split(",").map(Number) : null,
    wkst: WEEKDAYS.indexOf(r.WKST || "MO"),
  };
}

function parseICS(text) {
  const cal = { name: "", events: [] };
  let ev = null, depth = 0; // depth > 0 inside a component nested in VEVENT (VALARM)
  for (const line of unfold(text).split("\n")) {
    if (!line) continue;
    const p = parseLine(line);
    if (p.name === "BEGIN") {
      if (p.value === "VEVENT") ev = { exdates: [], attendees: [] };
      else if (ev) depth++;
      continue;
    }
    if (p.name === "END") {
      if (p.value === "VEVENT" && ev) { cal.events.push(ev); ev = null; depth = 0; }
      else if (ev && depth) depth--;
      continue;
    }
    if (!ev) { if (p.name === "X-WR-CALNAME") cal.name = unescapeText(p.value); continue; }
    if (depth) continue;
    switch (p.name) {
      case "UID": ev.uid = p.value; break;
      case "SUMMARY": ev.title = unescapeText(p.value).trim(); break;
      case "LOCATION": ev.location = unescapeText(p.value).trim(); break;
      case "DTSTART": ev.start = parseDate(p); break;
      case "DTEND": ev.end = parseDate(p); break;
      case "DURATION": ev.duration = parseDuration(p.value); break;
      case "RRULE": ev.rrule = parseRRule(p.value); break;
      case "EXDATE": for (const v of p.value.split(",")) { const d = parseDate({ value: v, params: p.params }); if (d) ev.exdates.push(d); } break;
      case "RECURRENCE-ID": ev.recurrenceId = parseDate(p); break;
      case "STATUS": ev.status = p.value.toUpperCase(); break;
      case "TRANSP": ev.transp = p.value.toUpperCase(); break;
      case "ATTENDEE": ev.attendees.push({ email: p.value.replace(/^mailto:/i, "").toLowerCase(), partstat: (p.params.PARTSTAT || "").toUpperCase() }); break;
    }
  }
  return cal;
}

/* ---------- time zones ---------- */
const zoneFmt = new Map();
function zoneOffset(ms, tz) {
  let f = zoneFmt.get(tz);
  if (f === undefined) {
    try {
      f = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
    } catch { f = null; } // e.g. Outlook's "Pacific Standard Time": fall back to this Mac's zone
    zoneFmt.set(tz, f);
  }
  if (!f) return -new Date(ms).getTimezoneOffset() * 60e3;
  const p = Object.fromEntries(f.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - Math.floor(ms / 1e3) * 1e3;
}
// Wall-clock time in a zone → real UTC milliseconds. Floating and all-day times use this Mac's zone.
function toUtc(wall, tz) {
  if (tz === "UTC") return wall;
  const off = (ms) => (tz ? zoneOffset(ms, tz) : -new Date(ms).getTimezoneOffset() * 60e3);
  let t = wall - off(wall);
  t = wall - off(t); // second pass settles DST boundaries
  return t;
}
function placeOf(d) { return d.allDay ? null : d.tz; }

/* ---------- recurrence ---------- */
const wallParts = (w) => { const d = new Date(w); return { y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate(), wd: d.getUTCDay(), tod: w - Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) }; };
const daysInMonth = (y, m) => new Date(Date.UTC(y, m + 1, 0)).getUTCDate();

// Days of one month matching BYDAY entries like "TU", "2TU" or "-1FR".
function monthByDay(y, m, byDay) {
  const out = [], n = daysInMonth(y, m);
  for (const { n: ord, wd } of byDay) {
    const hits = [];
    for (let d = 1; d <= n; d++) if (new Date(Date.UTC(y, m, d)).getUTCDay() === wd) hits.push(d);
    if (!ord) out.push(...hits);
    else { const h = ord > 0 ? hits[ord - 1] : hits[hits.length + ord]; if (h) out.push(h); }
  }
  return out;
}
function monthDays(y, m, r, startDay) {
  let days;
  if (r.byMonthDay) {
    const n = daysInMonth(y, m);
    days = r.byMonthDay.map((d) => (d < 0 ? n + d + 1 : d)).filter((d) => d >= 1 && d <= n);
    if (r.byDay) { const allowed = new Set(monthByDay(y, m, r.byDay)); days = days.filter((d) => allowed.has(d)); }
  } else if (r.byDay) days = monthByDay(y, m, r.byDay);
  else days = startDay <= daysInMonth(y, m) ? [startDay] : [];
  days = [...new Set(days)].sort((a, b) => a - b);
  if (r.bySetPos) days = r.bySetPos.map((p) => (p > 0 ? days[p - 1] : days[days.length + p])).filter(Boolean);
  return days;
}

// Start wall-clock times of a recurring event, from DTSTART up to `endWall`.
function* occurrences(ev, endWall) {
  const r = ev.rrule, s = ev.start, sp = wallParts(s.wall);
  // UNTIL is usually UTC while occurrences are wall-clock: move it onto the event's wall clock.
  let until = Infinity;
  if (r.until) {
    until = r.until.wall;
    if (r.until.tz === "UTC" && !s.allDay && s.tz !== "UTC") until += s.tz ? zoneOffset(until, s.tz) : -new Date(until).getTimezoneOffset() * 60e3;
    if (r.until.allDay) until += DAY - 1; // a date-only UNTIL includes that whole day
  }
  let emitted = 0;
  const emit = function* (w) {
    if (w < s.wall) return false;
    if (w > until || (r.count && emitted >= r.count)) return true;
    emitted++;
    yield w;
    return false;
  };
  for (let period = 0; period < 20000; period++) {
    let cands = [];
    if (r.freq === "DAILY") {
      const w = s.wall + period * r.interval * DAY, p = wallParts(w);
      if ((!r.byDay || r.byDay.some((b) => b.wd === p.wd)) && (!r.byMonth || r.byMonth.includes(p.m)) && (!r.byMonthDay || r.byMonthDay.includes(p.d))) cands = [w];
      if (w > endWall) return;
    } else if (r.freq === "WEEKLY") {
      const back = (sp.wd - r.wkst + 7) % 7;
      const weekStart = Date.UTC(sp.y, sp.m, sp.d - back) + period * r.interval * 7 * DAY;
      if (weekStart > endWall) return;
      const wds = r.byDay ? r.byDay.map((b) => b.wd) : [sp.wd];
      cands = [...new Set(wds)].map((wd) => weekStart + ((wd - r.wkst + 7) % 7) * DAY + sp.tod).sort((a, b) => a - b);
      if (r.byMonth) cands = cands.filter((w) => r.byMonth.includes(wallParts(w).m));
    } else if (r.freq === "MONTHLY") {
      const mi = sp.m + period * r.interval, y = sp.y + Math.floor(mi / 12), m = ((mi % 12) + 12) % 12;
      if (Date.UTC(y, m, 1) > endWall) return;
      if (!r.byMonth || r.byMonth.includes(m)) cands = monthDays(y, m, r, sp.d).map((d) => Date.UTC(y, m, d) + sp.tod);
    } else if (r.freq === "YEARLY") {
      const y = sp.y + period * r.interval;
      if (Date.UTC(y, 0, 1) > endWall) return;
      for (const m of r.byMonth || [sp.m]) {
        const days = r.byMonthDay || r.byDay ? monthDays(y, m, r, sp.d) : sp.d <= daysInMonth(y, m) ? [sp.d] : [];
        cands.push(...days.map((d) => Date.UTC(y, m, d) + sp.tod));
      }
      cands.sort((a, b) => a - b);
    } else {
      yield s.wall; // unsupported FREQ (hourly etc.): treat as a single event
      return;
    }
    for (const w of cands) if (yield* emit(w)) return;
  }
}

/* ---------- instances in a window ---------- */
function instances(cal, from, to) {
  const owner = /@/.test(cal.name) ? cal.name.toLowerCase() : null; // Google names the primary calendar after its owner
  const overrides = new Map(); // "uid|originalStartUtc" → override event
  for (const ev of cal.events) if (ev.recurrenceId && ev.uid) overrides.set(`${ev.uid}|${toUtc(ev.recurrenceId.wall, placeOf(ev.recurrenceId))}`, ev);

  const out = [];
  const add = (ev, startUtc, endUtc) => {
    if (ev.status === "CANCELLED" || ev.transp === "TRANSPARENT") return;
    if (owner && ev.attendees.some((a) => a.email === owner && a.partstat === "DECLINED")) return;
    if (endUtc <= from || startUtc >= to) return;
    out.push({ title: ev.title || "Busy", start: startUtc, end: endUtc, allDay: !!ev.start.allDay });
  };
  for (const ev of cal.events) {
    if (!ev.start) continue;
    const place = placeOf(ev.start);
    const startUtc = toUtc(ev.start.wall, place);
    const length = ev.end ? toUtc(ev.end.wall, placeOf(ev.end)) - startUtc
      : ev.duration != null ? ev.duration : ev.start.allDay ? DAY : 0;
    if (ev.recurrenceId || !ev.rrule) { add(ev, startUtc, startUtc + length); continue; }
    const ex = new Set(ev.exdates.map((d) => toUtc(d.wall, d.allDay ? null : d.tz || place)));
    const endWall = to + 14 * 3600e3 + DAY; // generous: walls are offset from UTC by up to ±14h
    for (const w of occurrences(ev, endWall)) {
      const st = toUtc(w, place);
      if (st >= to) break;
      if (ex.has(st)) continue;
      const o = overrides.get(`${ev.uid}|${st}`);
      if (o) continue; // the override is added on its own above
      add(ev, st, st + length);
    }
  }
  return out.sort((a, b) => a.start - b.start);
}

/* ---------- feeds ---------- */
const feeds = new Map(); // id → { id, url, name, ok, error, syncedAt, events }

function normalizeUrl(raw) {
  let u = String(raw || "").trim().replace(/^webcals?:\/\//i, "https://");
  try { u = new URL(u); } catch { return null; }
  return /^https?:$/.test(u.protocol) ? u.toString() : null;
}
function hostLabel(url) { try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return "calendar"; } }

async function fetchFeed(url) {
  const r = await fetch(url, { signal: AbortSignal.timeout(20e3), headers: { accept: "text/calendar, */*" }, redirect: "follow" });
  if (!r.ok) throw new Error(r.status === 404 || r.status === 403 || r.status === 401 ? `The calendar address was refused (HTTP ${r.status}). It may have been reset or made private.` : `HTTP ${r.status}`);
  const len = +r.headers.get("content-length") || 0;
  if (len > MAX_BYTES) throw new Error("The calendar is too large");
  const text = await r.text();
  if (!/BEGIN:VCALENDAR/i.test(text)) throw new Error("That address isn't an iCal calendar (.ics)");
  return parseICS(text);
}

// A feed is an iCal address, or a source module (like google.js) that brings its own load(from, to).
async function sync(feed) {
  try {
    const now = Date.now(), from = now - BACK_MS, to = now + AHEAD_MS;
    let name, events;
    if (feed.load) ({ name, events } = await feed.load(from, to));
    else { const cal = await fetchFeed(feed.url); name = cal.name || hostLabel(feed.url); events = instances(cal, from, to); }
    Object.assign(feed, { name: name || feed.name, ok: true, error: null, syncedAt: now, events });
  } catch (e) {
    const error = e.name === "TimeoutError" ? "Timed out reaching the calendar"
      : e instanceof TypeError ? "Couldn't reach that address. Check the link and your internet connection."
      : String(e.message || e);
    Object.assign(feed, { ok: false, error, syncedAt: Date.now() });
  }
  return feed;
}

// Keeps the running feeds in line with the saved list ([{ id, url }]).
function setFeeds(list) {
  const want = new Map((list || []).map((c) => [c.id, c]));
  for (const [id, f] of feeds) if (!f.load && !want.has(id)) feeds.delete(id);
  for (const c of want.values()) {
    if (feeds.has(c.id)) continue;
    const f = { id: c.id, url: c.url, name: c.name || hostLabel(c.url), ok: null, error: null, syncedAt: 0, events: [] };
    feeds.set(c.id, f);
    sync(f);
  }
}
// Source modules register here; `kind` and `host` are what the settings app shows for them.
function addSource({ id, name, kind, host, load }) {
  const f = { id, name, kind, host, load, ok: null, error: null, syncedAt: 0, events: [] };
  feeds.set(id, f);
  return sync(f);
}
function removeSource(id) { feeds.delete(id); }
setInterval(() => { for (const f of feeds.values()) sync(f); }, SYNC_MS).unref();

// What the lock screen gets: meetings from a few hours ago to tomorrow night, and each feed's health.
// Calendar addresses are secrets, so they never leave the server.
function snapshot() {
  const now = Date.now(), seen = new Set(), events = [];
  for (const f of feeds.values()) for (const e of f.events) {
    if (e.end < now - 6 * 3600e3 || e.start > now + 36 * 3600e3) continue;
    const key = `${e.title}|${e.start}|${e.end}`; // the same meeting on two shared calendars
    if (seen.has(key)) continue;
    seen.add(key);
    events.push(e);
  }
  events.sort((a, b) => a.start - b.start);
  const list = [...feeds.values()].map(({ id, name, kind, host, ok, error, syncedAt, url }) => ({ id, name, kind: kind || "ics", host: host || hostLabel(url), ok, error, syncedAt }));
  return { events, feeds: list };
}

module.exports = { parseICS, instances, normalizeUrl, fetchFeed, setFeeds, addSource, removeSource, sync, snapshot, feeds, hostLabel };
