// Xray watcher bot: /watch, /unwatch, /watching + alerts when
// holders' avg PnL >= MIN_PNL and winrate >= MIN_WINRATE.
// MODE=site (default): asks xray-terminal.com's scan API (its server already has the full
// wallet-history index). MODE=local: runs the xray-terminal CLI inside this container.

import { Bot, InputFile } from "grammy";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { readFile, writeFile, unlink, mkdir, rename } from "node:fs/promises";
import path from "node:path";

const run = promisify(execFile);

// ---------- config (all overridable with env vars) ----------
const env = (k, d) => (process.env[k] !== undefined && process.env[k] !== "" ? process.env[k] : d);
const BOT_TOKEN = env("BOT_TOKEN");
const XRAY_DIR = env("XRAY_DIR", "./xray-terminal");
const DATA_DIR = env("DATA_DIR", "./data");
const MODE = env("MODE", "site"); // "site" or "local"
const SITE_URL = env("SITE_URL", "https://xray-terminal.com").replace(/\/+$/, "");
const SITE_MIN_GAP_MS = Number(env("SITE_MIN_GAP_SECONDS", "10")) * 1000; // pause between site requests
const INTERVAL_MS = Number(env("INTERVAL_SECONDS", MODE === "site" ? "120" : "20")) * 1000;
const SEND_CARD = env("SEND_CARD", "true") !== "false"; // attach the share-card image to /check and alerts
const MIN_WALLETS = Number(env("MIN_WALLETS", "20")); // need this many holders with history before alerting
const MIN_PNL = Number(env("MIN_PNL", "15"));
const MIN_WINRATE = Number(env("MIN_WINRATE", "55"));
const PNL_SCALE = Number(env("PNL_SCALE", "1")); // set 100 if the JSON stores 0.15 for 15%
const WINRATE_SCALE = Number(env("WINRATE_SCALE", "1"));
// exact JSON fields of xray-terminal: the HOLDERS' record (not this token's own pnl)
const PNL_KEY = env("PNL_KEY", "aggregates.avgProfilePnl");
const WINRATE_KEY = env("WINRATE_KEY", "aggregates.avgWinrate");
const SCAN_TIMEOUT_MS = Number(env("SCAN_TIMEOUT_SECONDS", "180")) * 1000;
const MAX_WATCH = Number(env("MAX_WATCH_PER_USER", "10"));
const ALLOWED = env("ALLOWED_USER_IDS", "").split(",").map((s) => s.trim()).filter(Boolean);
const ENABLE_FOLLOW = env("ENABLE_FOLLOW", "false") === "true";

if (!BOT_TOKEN) {
  console.error("BOT_TOKEN is missing. Set it in Railway > Variables.");
  process.exit(1);
}

// ---------- tiny JSON store ----------
const DB_FILE = path.join(DATA_DIR, "watchlist.json");
const TMP_DIR = path.join(DATA_DIR, "tmp");
// users[chatId][ca] = { alerted: boolean };  tokens[ca] = last scan result
let db = { users: {}, tokens: {} };
let saveTimer = null;

async function loadDb() {
  await mkdir(TMP_DIR, { recursive: true });
  try {
    db = JSON.parse(await readFile(DB_FILE, "utf8"));
    db.users ||= {};
    db.tokens ||= {};
  } catch {
    /* first run */
  }
}
function saveDb() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    const tmp = DB_FILE + ".tmp";
    await writeFile(tmp, JSON.stringify(db));
    await rename(tmp, DB_FILE);
  }, 300);
}

// ---------- metric extraction (field names in the JSON are auto-detected) ----------
function flatten(obj, prefix = "", out = []) {
  if (obj && typeof obj === "object") {
    for (const [k, v] of Object.entries(obj)) {
      const p = prefix ? `${prefix}.${k}` : k;
      if (v && typeof v === "object") flatten(v, p, out);
      else out.push([p, k, v]);
    }
  }
  return out;
}
function toNumber(v) {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const n = parseFloat(v.replace(/[+%,\s]/g, "").replace("\u2212", "-"));
    return Number.isFinite(n) ? n : null;
  }
  return null;
}
function pick(leaves, exact, regex, avoid) {
  let cands;
  if (exact) {
    cands = leaves.filter(([p, k]) => p === exact || k === exact);
  } else {
    cands = leaves.filter(([p, k]) => regex.test(k) && !(avoid && avoid.test(p)));
  }
  cands = cands.filter(([, , v]) => toNumber(v) !== null);
  if (!cands.length) return null;
  // prefer the holders' record, which is the tool's headline number
  cands.sort((a, b) => /holder/i.test(b[0]) - /holder/i.test(a[0]));
  const [p, , v] = cands[0];
  return { path: p, value: toNumber(v) };
}
function extract(json) {
  const leaves = flatten(json);
  const pnl = pick(leaves, PNL_KEY, /avg.*pnl|average.*pnl|pnl.*avg/i, /own|this_?token/i);
  const wr = pick(leaves, WINRATE_KEY, /win.?rate/i, /own|this_?token/i);
  const grade = leaves.find(([, k, v]) => /^grade$/i.test(k) && typeof v === "string");
  const nw = (key) => {
    const hit = leaves.find(([pth]) => pth === key);
    return hit && typeof hit[2] === "number" ? hit[2] : 0;
  };
  return {
    wallets: Math.min(nw("aggregates.profilePnlWallets"), nw("aggregates.winrateWallets")),
    pnl: pnl ? pnl.value * PNL_SCALE : null,
    winrate: wr ? wr.value * WINRATE_SCALE : null,
    grade: grade ? grade[2] : null,
    pnlPath: pnl?.path ?? null,
    winratePath: wr?.path ?? null,
  };
}

// ---------- scanning (strictly one scan at a time) ----------
let queue = Promise.resolve();
function enqueue(fn) {
  const p = queue.then(fn, fn);
  queue = p.catch(() => {});
  return p;
}

async function scanLocal(ca, { card = false } = {}) {
  const base = path.join(TMP_DIR, `${ca}-${Date.now()}`);
  const out = base + ".json";
  const cardPath = base + ".png";
  const args = ["run", "cli", "--", "check", ca, "--format", "json", "--output", out];
  if (card) args.push("--card", cardPath);
  try {
    const { stdout } = await run("npm", args, {
      cwd: XRAY_DIR,
      timeout: SCAN_TIMEOUT_MS,
      maxBuffer: 50 * 1024 * 1024,
    });
    let raw;
    try {
      raw = await readFile(out, "utf8");
    } catch {
      raw = stdout.slice(stdout.indexOf("{")); // fall back to stdout JSON
    }
    const json = JSON.parse(raw);
    return { ...extract(json), raw, cardPath: card ? cardPath : null, out };
  } catch (e) {
    await unlink(out).catch(() => {});
    const tail = (t, n) => String(t || "").trim().split("\n").filter((l) => l && !l.startsWith(">")).slice(-n).join("\n");
    const detail = [`exit=${e.code} signal=${e.signal} timeout=${e.killed}`, tail(e.stderr, 4), tail(e.stdout, 4)]
      .filter(Boolean)
      .join("\n");
    throw new Error(detail.slice(-280));
  }
}

// ---------- site mode: use xray-terminal.com's streaming scan API ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let lastSiteCall = 0;
let siteBlockedUntil = 0;

function fromSite(result) {
  const v = result.verdict || {};
  const pnl = typeof v.holdersPnlNum === "number" ? v.holdersPnlNum : null;
  const winrate = toNumber(v.winrate); // site sends text like "61%", or null
  const pnlWallets = Number(v.holdersPnlWallets) || 0;
  const wrWallets = Number(v.traced) || 0;
  return {
    pnl,
    winrate,
    wallets: Math.min(pnlWallets, wrWallets),
    grade: result.grade ?? null,
    ticker: result.token?.ticker ?? null,
    mcap: result.token?.mcap ?? null, // text like "$71k", as shown on the site
    dead: !!result.dead,
    pnlPath: "verdict.holdersPnlNum",
    winratePath: "verdict.winrate",
    raw: JSON.stringify({ ...result, holders: `[${result.holders?.length ?? 0} rows omitted]` }, null, 2),
    card: result.card ?? null, // data for the share card, rendered later with the xray engine
    cardPath: null,
    out: null,
  };
}

async function scanSite(ca) {
  const wait = Math.max(siteBlockedUntil, lastSiteCall + SITE_MIN_GAP_MS) - Date.now();
  if (wait > 0) await sleep(wait);
  lastSiteCall = Date.now();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), SCAN_TIMEOUT_MS);
  try {
    const resp = await fetch(`${SITE_URL}/api/scan/stream?token=${ca}`, {
      headers: { accept: "text/event-stream", "user-agent": "xray-watcher-bot/1.0" },
      signal: ctrl.signal,
    });
    if (resp.status === 429 || resp.status === 403) {
      siteBlockedUntil = Date.now() + (resp.status === 429 ? 120_000 : 600_000);
      throw new Error(`site refused the request (HTTP ${resp.status}); backing off`);
    }
    if (!resp.ok || !resp.body) throw new Error(`site error HTTP ${resp.status}`);
    const decoder = new TextDecoder();
    let buf = "";
    let result = null;
    let err = null;
    for await (const chunk of resp.body) {
      buf += decoder.decode(chunk, { stream: true });
      let i;
      while ((i = buf.indexOf("\n\n")) >= 0) {
        const block = buf.slice(0, i);
        buf = buf.slice(i + 2);
        let ev = "message";
        let data = "";
        for (const line of block.split("\n")) {
          if (line.startsWith("event:")) ev = line.slice(6).trim();
          else if (line.startsWith("data:")) data += line.slice(5).trim();
        }
        if (!data) continue;
        if (ev === "result") result = JSON.parse(data);
        else if (ev === "error") err = JSON.parse(data);
        else if (ev === "picks") err = { message: "ambiguous token, use the full address" };
      }
      if (result || err) break;
    }
    if (err) throw new Error(String(err.message || "site reported an error").slice(0, 200));
    if (!result) throw new Error("site closed the stream without a result");
    return fromSite(result);
  } catch (e) {
    if (e.name === "AbortError") throw new Error("site scan timed out");
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

function scan(ca, opts) {
  return MODE === "site" ? scanSite(ca) : scanLocal(ca, opts);
}

// ---------- share card: drawn locally with xray-terminal's own card renderer ----------
const RENDER_SCRIPT = path.join(DATA_DIR, "render-card.mjs");
const RENDER_SRC = `import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";
const [, , xrayDir, inFile, outFile] = process.argv;
const { renderCardPng } = await import(pathToFileURL(path.join(xrayDir, "lib/site/card-server.ts")).href);
await writeFile(outFile, await renderCardPng(JSON.parse(await readFile(inFile, "utf8"))));
`;

async function renderCard(card) {
  if (!SEND_CARD || !card) return null;
  const base = path.join(TMP_DIR, `card-${Date.now()}`);
  const inFile = base + ".json";
  const outFile = base + ".png";
  try {
    await writeFile(inFile, JSON.stringify(card));
    await run(path.join(XRAY_DIR, "node_modules", ".bin", "tsx"), [RENDER_SCRIPT, XRAY_DIR, inFile, outFile], {
      cwd: XRAY_DIR, // the renderer looks for fonts and sprites relative to this folder
      timeout: 60_000,
    });
    return outFile;
  } catch (e) {
    console.error("card render failed:", String(e.stderr || e.message).slice(0, 300));
    await unlink(outFile).catch(() => {});
    return null;
  } finally {
    await unlink(inFile).catch(() => {});
  }
}

async function cleanup(res) {
  if (res?.out) await unlink(res.out).catch(() => {});
  if (res?.cardPath) await unlink(res.cardPath).catch(() => {});
}

// ---------- bot ----------
const bot = new Bot(BOT_TOKEN);
const CA_RE = /^0x[a-fA-F0-9]{40}$/;
const fmt = (n) => (n === null || n === undefined ? "n/a" : `${n.toFixed(1)}%`);
const code = (s) => `<code>${s}</code>`;
const meets = (t) =>
  t && t.pnl !== null && t.winrate !== null && t.pnl >= MIN_PNL && t.winrate >= MIN_WINRATE && (t.wallets ?? 0) >= MIN_WALLETS;

bot.command("id", (ctx) => ctx.reply(`Your Telegram user ID: ${ctx.from.id}`));

bot.use(async (ctx, next) => {
  if (ALLOWED.length && !ALLOWED.includes(String(ctx.from?.id))) {
    return ctx.reply("Not authorized. Send /id and give the number to the bot owner.");
  }
  return next();
});

const help =
  `Xray watcher\n\n` +
  `/watch 0xCA - start watching a token\n` +
  `/unwatch 0xCA - stop watching\n` +
  `/watching - list watched tokens\n` +
  `/check 0xCA - one-off scan with share card\n` +
  `/raw 0xCA - send raw JSON (to verify field detection)\n` +
  `/doctor - test that the xray engine works on the server\n\n` +
  `Alert rule: holders' avg PnL per trade >= ${MIN_PNL}% AND holders' winrate >= ${MIN_WINRATE}%.\n` +
  `Source: ${MODE === "site" ? SITE_URL : "local engine"}. Each token is checked about every ${INTERVAL_MS / 1000}s.`;
bot.command(["start", "help"], (ctx) => ctx.reply(help));

function parseCa(ctx) {
  const ca = String(ctx.match || "").trim();
  return CA_RE.test(ca) ? ca.toLowerCase() : null;
}

bot.command("watch", async (ctx) => {
  const ca = parseCa(ctx);
  if (!ca) return ctx.reply("Usage: /watch 0x... (full 42-character contract address)");
  const list = (db.users[ctx.chat.id] ||= {});
  if (list[ca]) return ctx.reply("Already watching that token.");
  if (Object.keys(list).length >= MAX_WATCH) return ctx.reply(`Limit reached (${MAX_WATCH}). Use /unwatch first.`);
  list[ca] = { alerted: false };
  saveDb();
  await ctx.reply(`Watching ${ca}\nYou'll get a message when avg PnL >= ${MIN_PNL}% and winrate >= ${MIN_WINRATE}%.`);
});

bot.command("unwatch", async (ctx) => {
  const ca = parseCa(ctx);
  if (!ca) return ctx.reply("Usage: /unwatch 0x...");
  const list = db.users[ctx.chat.id] || {};
  if (!list[ca]) return ctx.reply("You aren't watching that token.");
  delete list[ca];
  pruneTokens();
  saveDb();
  await ctx.reply(`Stopped watching ${ca}`);
});

bot.command("watching", async (ctx) => {
  const cas = Object.keys(db.users[ctx.chat.id] || {});
  if (!cas.length) return ctx.reply("Nothing watched yet. Use /watch 0x...");
  const lines = cas.map((ca) => {
    const t = db.tokens[ca];
    if (!t) return `${code(ca)}\n  waiting for first scan...`;
    const ago = Math.round((Date.now() - t.checkedAt) / 1000);
    const state = t.error ? `last scan failed (${ago}s ago)` : `${ago}s ago`;
    const flag = meets(t) ? " ✅ meets target" : "";
    return `${code(ca)}\n  MC ${t.mcap ?? "n/a"} | PnL ${fmt(t.pnl)} | WR ${fmt(t.winrate)} | ${t.wallets ?? 0} wallets | ${state}${flag}`;
  });
  await ctx.reply(lines.join("\n\n"), { parse_mode: "HTML" });
});

bot.command("check", async (ctx) => {
  const ca = parseCa(ctx);
  if (!ca) return ctx.reply("Usage: /check 0x...");
  await ctx.reply("Scanning, this can take a while...");
  let res;
  try {
    res = await enqueue(() => scan(ca, { card: true }));
    if (MODE === "site") res.cardPath = await renderCard(res.card);
    let text =
      `${res.ticker ? res.ticker + " " : ""}${res.grade ? "(" + res.grade + ")" : ""}\n` +
      `Market cap: ${res.mcap ?? "n/a"}\n` +
      `Holders avg PnL/trade: ${fmt(res.pnl)}\n` +
      `Holders winrate: ${fmt(res.winrate)}\n` +
      `Wallets with history: ${res.wallets ?? 0} (alerts need ${MIN_WALLETS}+)\n` +
      `Meets target (>=${MIN_PNL}% / >=${MIN_WINRATE}%): ${meets(res) ? "yes" : "no"}`;
    if (res.pnl === null || res.winrate === null) {
      text += res.dead
        ? "\n\nToken is dead (too few holders), no averages."
        : "\n\nn/a = holder history not available for this token yet.";
    }
    if (res.cardPath) {
      try {
        await ctx.replyWithPhoto(new InputFile(res.cardPath), { caption: text });
      } catch {
        await ctx.reply(text);
      }
    } else {
      await ctx.reply(text);
    }
  } catch (e) {
    await ctx.reply(`Scan failed: ${String(e.message).slice(0, 300)}`);
  } finally {
    await cleanup(res);
  }
});

bot.command("raw", async (ctx) => {
  const ca = parseCa(ctx);
  if (!ca) return ctx.reply("Usage: /raw 0x...");
  await ctx.reply("Scanning...");
  let res;
  try {
    res = await enqueue(() => scan(ca));
    await ctx.replyWithDocument(new InputFile(Buffer.from(res.raw), `${ca}.json`), {
      caption: `Detected avg PnL at: ${res.pnlPath ?? "NOT FOUND"}\nDetected winrate at: ${res.winratePath ?? "NOT FOUND"}`,
    });
  } catch (e) {
    await ctx.reply(`Scan failed: ${String(e.message).slice(0, 300)}`);
  } finally {
    await cleanup(res);
  }
});

const clean = (t) => String(t || "").replace(/\x1b\[[0-9;]*m/g, "").trim();
bot.command("doctor", async (ctx) => {
  await ctx.reply("Running xray doctor (up to 2 min)...");
  try {
    const { stdout, stderr } = await run("npm", ["run", "cli", "--", "doctor"], {
      cwd: XRAY_DIR,
      timeout: 120000,
      maxBuffer: 10 * 1024 * 1024,
    });
    await ctx.reply(clean(stdout + "\n" + stderr).slice(-3500) || "(no output)");
  } catch (e) {
    await ctx.reply(clean(`exit=${e.code} signal=${e.signal}\n${e.stdout || ""}\n${e.stderr || ""}`).slice(-3500) || "(no output)");
  }
});

bot.catch((err) => console.error("bot error:", err.error?.message || err));

// ---------- watch loop ----------
function pruneTokens() {
  const live = new Set(Object.values(db.users).flatMap((l) => Object.keys(l)));
  for (const ca of Object.keys(db.tokens)) if (!live.has(ca)) delete db.tokens[ca];
}
function watchedCas() {
  return [...new Set(Object.values(db.users).flatMap((l) => Object.keys(l)))];
}

async function checkOne(ca) {
  let res;
  try {
    res = await enqueue(() => scan(ca));
    db.tokens[ca] = {
      pnl: res.pnl, winrate: res.winrate, wallets: res.wallets ?? 0, grade: res.grade, mcap: res.mcap ?? null, checkedAt: Date.now(), error: null,
    };
  } catch (e) {
    console.error(`scan failed ${ca}:`, String(e.message).slice(0, 200));
    db.tokens[ca] = { ...(db.tokens[ca] || {}), checkedAt: Date.now(), error: String(e.message).slice(0, 200) };
    return;
  } finally {
    await cleanup(res);
  }

  const t = db.tokens[ca];
  // no usable numbers (dead token, <10 holders, or fields not found): leave alert state alone
  if (t.pnl === null || t.winrate === null) return;

  let alertCard; // rendered lazily, once per alert round
  for (const [chatId, list] of Object.entries(db.users)) {
    const w = list[ca];
    if (!w) continue;
    if (meets(t) && !w.alerted) {
      w.alerted = true; // alert once per crossing, not every scan
      const text =
        `✅ Target reached\n${code(ca)}\nMarket cap: ${t.mcap ?? "n/a"}\nHolders avg PnL/trade: ${fmt(t.pnl)}\n` +
        `Holders winrate: ${fmt(t.winrate)}\nWallets with history: ${t.wallets}`;
      if (alertCard === undefined) alertCard = MODE === "site" ? await renderCard(res?.card) : null;
      const send = alertCard
        ? bot.api.sendPhoto(chatId, new InputFile(alertCard), { caption: text, parse_mode: "HTML" })
        : bot.api.sendMessage(chatId, text, { parse_mode: "HTML" });
      await send.catch((e) => console.error("send failed:", e.message));
    } else if (!meets(t) && w.alerted) {
      w.alerted = false; // re-arm for the next crossing
    }
  }
  if (alertCard) await unlink(alertCard).catch(() => {});
  saveDb();
}

async function cycle() {
  const started = Date.now();
  try {
    for (const ca of watchedCas()) {
      if (watchedCas().includes(ca)) await checkOne(ca);
    }
  } catch (e) {
    console.error("cycle error:", e.message);
  }
  setTimeout(cycle, Math.max(1000, INTERVAL_MS - (Date.now() - started)));
}

// ---------- optional: keep xray's local trade index fresh ----------
function startFollow() {
  const child = spawn("sh", ["-c", "npm run cli -- index && npm run cli -- follow"], {
    cwd: XRAY_DIR,
    stdio: "inherit",
  });
  child.on("exit", () => setTimeout(startFollow, 15000));
}

// ---------- start ----------
await loadDb();
await writeFile(RENDER_SCRIPT, RENDER_SRC);
if (ENABLE_FOLLOW) startFollow();
setTimeout(cycle, 3000);
process.once("SIGTERM", async () => {
  await writeFile(DB_FILE, JSON.stringify(db)).catch(() => {});
  process.exit(0);
});
console.log(`Bot started (mode ${MODE}). Interval ${INTERVAL_MS / 1000}s, targets PnL>=${MIN_PNL}% WR>=${MIN_WINRATE}%`);
bot.start();
