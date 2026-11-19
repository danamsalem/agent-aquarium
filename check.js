#!/usr/bin/env node
// The checks CI runs on every push and pull request (.github/workflows/ci.yml). Run them here with `node check.js`.
//   1. Every script parses: the .js files, and the inline <script> of index.html and settings.html.
//   2. The server starts and serves /, /settings and /status.
//   3. Nothing that must stay private is committed (google-client.json).
const fs = require("fs");
const os = require("os");
const path = require("path");
const vm = require("vm");
const http = require("http");
const { spawn, execFileSync } = require("child_process");

const ROOT = __dirname;
const SRC = path.join(ROOT, "src");
const SOURCES = ["index.html", "settings.html", "server.js", "calendar.js", "google.js", "battery.js", "hook.js", "statusline.js", "setup-hooks.js"];
const TOOLS = ["check.js", "macos/bundle.js"];
let failed = 0;

function ok(msg) { console.log(`  ok  ${msg}`); }
function fail(msg) { failed++; console.log(`  FAIL  ${msg}`); }

// Parses a script without running it; an HTML page's inline <script> blocks are parsed one by one.
function parses(name, text) {
  const scripts = name.endsWith(".html")
    ? [...text.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1])
    : [text.replace(/^#!.*/, "")];
  if (!scripts.length) throw new Error("no inline <script> found");
  for (const s of scripts) new vm.Script(name.endsWith(".js") ? `(function (exports, require, module, __filename, __dirname) {${s}\n})` : s, { filename: name });
}

function syntax(files) {
  for (const [name, text] of files) {
    try { parses(name, text); ok(`${name} parses`); }
    catch (e) { fail(`${name}: ${e.message}`); }
  }
}

function get(port, p) {
  return new Promise((resolve, reject) => {
    http.get({ host: "127.0.0.1", port, path: p, timeout: 3000 }, (res) => {
      let body = "";
      res.on("data", (c) => (body += c));
      res.on("end", () => resolve({ status: res.statusCode, body }));
    }).on("error", reject);
  });
}

async function serves(port) {
  const data = fs.mkdtempSync(path.join(os.tmpdir(), "aquarium-check-"));
  const env = { ...process.env, CLAUDE_LOCKSCREEN_PORT: String(port), CLAUDE_LOCKSCREEN_DIR: data, CLAUDE_LOCKSCREEN_NO_OPEN: "1" };
  const server = spawn(process.execPath, [path.join(SRC, "server.js")], { env, stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  server.stderr.on("data", (c) => (stderr += c));
  try {
    let up = false;
    for (let i = 0; i < 50 && !up; i++) {
      await new Promise((r) => setTimeout(r, 100));
      up = await get(port, "/status").then(() => true, () => false);
    }
    if (!up) return fail(`server did not start${stderr ? `: ${stderr.trim()}` : ""}`);
    for (const [p, expect] of [["/", "<html"], ["/settings", "<html"], ["/status", '"sessions"']]) {
      const r = await get(port, p);
      if (r.status === 200 && r.body.includes(expect)) ok(`server GET ${p}`);
      else fail(`server GET ${p}: ${r.status}`);
    }
  } finally {
    server.kill();
    fs.rmSync(data, { recursive: true, force: true });
  }
}

(async () => {
  console.log("Syntax");
  syntax(SOURCES.map((f) => [`src/${f}`, fs.readFileSync(path.join(SRC, f), "utf8")]));
  syntax(TOOLS.map((f) => [f, fs.readFileSync(path.join(ROOT, f), "utf8")]));

  console.log("Server");
  await serves(4891);

  console.log("Committed files");
  try {
    const tracked = execFileSync("git", ["ls-files"], { cwd: ROOT, encoding: "utf8" }).split("\n");
    if (tracked.some((f) => path.basename(f) === "google-client.json")) fail("google-client.json is committed");
    else ok("google-client.json is not committed");
  } catch { ok("not a git checkout, skipped"); }

  console.log(failed ? `\n${failed} check(s) failed` : "\nAll checks passed");
  process.exit(failed ? 1 : 0);
})();
