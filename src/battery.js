// Battery estimate: while the Mac runs on battery, samples its power draw (battery voltage × current, from
// ioreg's AppleSmartBattery) every 20 s and files each sample under what was on screen: the screensaver
// (per theme), the always-on display, or neither. The averages answer "what does the lock screen cost me?".
// It's the whole Mac's draw, so agents working in the background count too; the "rest of the time" number
// is there to compare against. Samples stay on this Mac, in battery.json.
const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

const EVERY_MS = 20e3; // one sample per 20 s of battery time
const CHECK_MS = 5e3; // how often the battery is read, so "right now" follows plugging in and out
const MAX_SAMPLES = 4320; // a day on battery
const KEEP_MS = 14 * 864e5;
const SHOWN_MS = 5e3; // a page that polled this recently is on screen

let file = null, samples = [], now = { present: false }, theme = () => "warm", lastSample = 0;
const shownAt = { saver: 0, display: 0 };

function int(xml, key) {
  const m = new RegExp(`<key>${key}</key>\\s*<integer>(-?\\d+)</integer>`).exec(xml);
  if (!m) return null;
  let n = BigInt(m[1]);
  if (n >= 2n ** 63n) n -= 2n ** 64n; // ioreg writes negative currents as unsigned 64-bit numbers
  return Number(n);
}
const yes = (xml, key) => new RegExp(`<key>${key}</key>\\s*<true/>`).test(xml);

function read() {
  return new Promise((resolve) => {
    execFile("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery", "-a"], { timeout: 5000, maxBuffer: 4 << 20 }, (err, xml) => {
      if (err || !xml || !xml.includes("<key>Voltage</key>")) return resolve({ present: false }); // no battery (desktop Macs)
      const mv = int(xml, "Voltage"), ma = int(xml, "InstantAmperage") ?? int(xml, "Amperage");
      const mah = int(xml, "FullChargeCapacity") ?? int(xml, "NominalChargeCapacity") ?? int(xml, "AppleRawMaxCapacity");
      if (!mv || ma === null) return resolve({ present: false });
      resolve({
        present: true,
        external: yes(xml, "ExternalConnected"),
        percent: int(xml, "CurrentCapacity"),
        watts: ma < 0 ? (-ma * mv) / 1e6 : 0, // drawing from the battery only when the current is negative
        wh: mah ? (mah * mv) / 1e6 : null,
      });
    });
  });
}

function shownNow(t = Date.now()) {
  if (t - shownAt.saver < SHOWN_MS) return "saver";
  if (t - shownAt.display < SHOWN_MS) return "display";
  return "none";
}

async function check() {
  now = await read();
  const t = Date.now();
  if (!now.present || now.external || !now.watts) return void (lastSample = 0); // the next unplugged check samples at once
  if (t - lastSample < EVERY_MS - 500) return;
  lastSample = t;
  const shown = shownNow(t);
  samples.push({ t, w: Math.round(now.watts * 100) / 100, shown, theme: shown === "none" ? null : theme() });
  samples = samples.filter((s) => t - s.t < KEEP_MS).slice(-MAX_SAMPLES);
  save();
}
function save() {
  try { fs.writeFileSync(file, JSON.stringify({ samples })); } catch {}
}

function bucket(list) {
  if (!list.length) return null;
  const w = list.reduce((a, s) => a + s.w, 0) / list.length;
  return { w: Math.round(w * 10) / 10, minutes: Math.round((list.length * EVERY_MS) / 6e3) / 10, samples: list.length };
}

// What the settings page shows. percentPerHour uses the battery's full charge, so it's the same scale as the menu bar.
function summary() {
  const of = (pred) => bucket(samples.filter(pred));
  const pph = (b) => (b && now.wh ? Math.round((b.w / now.wh) * 1000) / 10 : null);
  const lock = of((s) => s.shown === "saver"), other = of((s) => s.shown === "none"), display = of((s) => s.shown === "display");
  const themes = {};
  for (const s of samples) if (s.shown === "saver") (themes[s.theme] = themes[s.theme] || []).push(s);
  return {
    present: !!now.present,
    onBattery: !!now.present && !now.external,
    percent: now.percent ?? null,
    nowW: now.present && !now.external ? Math.round(now.watts * 10) / 10 : null,
    lock: lock && { ...lock, percentPerHour: pph(lock) },
    display: display && { ...display, percentPerHour: pph(display) },
    other: other && { ...other, percentPerHour: pph(other) },
    themes: Object.fromEntries(Object.entries(themes).map(([k, v]) => [k, bucket(v)])),
  };
}

function init({ dataDir, currentTheme }) {
  file = path.join(dataDir, "battery.json");
  if (currentTheme) theme = currentTheme;
  try { samples = JSON.parse(fs.readFileSync(file, "utf8")).samples || []; } catch {}
  check();
  setInterval(check, CHECK_MS).unref();
}
// The lock screen page reports itself while it's visible: from the screensaver, or the always-on display.
function markShown(kind) { if (kind in shownAt) shownAt[kind] = Date.now(); }

module.exports = { init, summary, markShown };
