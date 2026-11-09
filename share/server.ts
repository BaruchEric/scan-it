#!/usr/bin/env bun
/**
 * scan-it live dashboard server. Started by `scan-catalog serve`.
 *
 * Serves share/dashboard.html with the catalog and a live config injected,
 * reports scanner state and staged batches as JSON, and runs the scan-it
 * tools (scan-batch, batch-file, scan-diag, scan-catalog) as background jobs
 * when a dashboard button asks.
 *
 * Local only: it binds 127.0.0.1, refuses any Host header other than its own
 * (DNS rebinding), and every POST must carry the per-launch token embedded in
 * the page. Jobs run detached with their output in <staging>/.logs, so they
 * keep going if the server stops.
 *
 * SCAN_SERVE_MOCK=1 (or --mock) swaps the scanners, batches and jobs for a
 * simulation, for UI work without paper or hardware.
 */
import { spawn, spawnSync } from "node:child_process";
import { randomBytes, timingSafeEqual } from "node:crypto";
import {
  appendFileSync, closeSync, existsSync, mkdirSync, openSync, readdirSync,
  readFileSync, renameSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { homedir, hostname } from "node:os";
import { join, resolve, sep } from "node:path";

// ---------- types ----------

type ScannerState =
  | "idle" | "scanning" | "restarting" | "busy" | "jam" | "cover-open" | "offline" | "error" | "unknown";
type BatchState = "scanning" | "stopping" | "staged" | "ready" | "filed";
type JobKind = "scan" | "resume" | "file" | "diag" | "refresh" | "restart-services";
type JobState = "running" | "done" | "failed";

interface Service { name: string; running: boolean }

interface Scanner {
  slug: string;
  model: string;
  where: string | null;
  present: boolean;
  connection: "usb" | "network" | null;
  state: ScannerState;
  detail: string;
  paper: boolean | null;
  services: Service[] | null;
  batch: string | null;
  actions: string[];
  checked: string;
}

interface Batch {
  id: string;
  dir: string;
  state: BatchState;
  pages: number;
  started: string | null;
  updated: string | null;
  scanner: string | null;
  user: string | null;
  default_entity: string | null;
  mode: string | null;
  duplex: boolean;
  resolution: number | null;
  documents: number | null;
  review_items: number | null;
  odd_pages: boolean;
  job: string | null;
  log_tail: string[];
  actions: string[];
}

interface Job {
  id: string;
  kind: JobKind;
  label: string;
  state: JobState;
  started: string;
  ended: string | null;
  exit_code: number | null;
  /** Last line of output once the job ends, so a failure says why. */
  summary: string | null;
  batch: string | null;
  reload: boolean;
}

interface ScannerDef { slug: string; model: string; where: string | null }

interface ScanRequest {
  scanner: ScannerDef;
  user: string;
  duplex: boolean;
  gray: boolean;
  idle: number;
}

/** What the HTTP layer needs; RealBackend drives the tools, MockBackend simulates them. */
interface Backend {
  scanners(defs: ScannerDef[], batches: Batch[], force: boolean): Promise<Scanner[]>;
  batches(): Batch[];
  jobs(): Job[];
  jobOutput(id: string): string | null;
  scan(req: ScanRequest): Job;
  stop(b: Batch): void;
  resume(b: Batch, idle: number): Job;
  file(b: Batch): Job;
  discard(b: Batch): void;
  reveal(path: string): void;
  diag(): Job;
  restartBrother(): Job;
  refresh(): Job;
  thumb(b: Batch, page: number): Promise<Response>;
}

class HttpError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

// ---------- configuration ----------

const HOME = homedir();
const HERE = import.meta.dir;
const BIN = resolve(HERE, "../bin");

function parseArgs(argv: string[]) {
  const opts = {
    root: process.env.SCAN_ROOT ?? join(HOME, "My Drive", "scans"),
    staging: process.env.SCAN_STAGING ?? join(HOME, ".cache", "scan-it", "batches"),
    port: 7820,
    open: true,
    mock: process.env.SCAN_SERVE_MOCK === "1",
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => {
      const v = argv[++i];
      if (v === undefined) fatal(`${a} requires a value`, 64);
      return v;
    };
    switch (a) {
      case "--root": opts.root = val(); break;
      case "--staging": opts.staging = val(); break;
      case "--port": {
        const p = Number(val());
        if (!Number.isInteger(p) || p < 1 || p > 65535) fatal("--port must be 1-65535", 64);
        opts.port = p;
        break;
      }
      case "--no-open": opts.open = false; break;
      case "--mock": opts.mock = true; break;
      case "-h": case "--help":
        console.log("Usage: bun server.ts [--root DIR] [--staging DIR] [--port N] [--no-open] [--mock]");
        process.exit(0);
      default: fatal(`unknown argument: ${a}`, 64);
    }
  }
  opts.root = resolve(opts.root.replace(/\/+$/, ""));
  opts.staging = resolve(opts.staging.replace(/\/+$/, ""));
  return opts;
}

function fatal(msg: string, code = 1): never {
  console.error(`scan-it server: ${msg}`);
  process.exit(code);
}

const OPTS = parseArgs(Bun.argv.slice(2));
const ROOT = OPTS.root;
const STAGING = OPTS.staging;
const LOGS = join(STAGING, ".logs");
const THUMBS = join(STAGING, ".thumbs");
const TEMPLATE = process.env.SCAN_DASHBOARD_TEMPLATE ?? join(HERE, "dashboard.html");
const TOKEN = randomBytes(24).toString("hex");
const STARTED = new Date().toISOString();
const HOST = hostname().split(".")[0] ?? "unknown";
const BROTHER_SERVER_DIR = "/Library/Printers/Brother/Utilities/Server";
const BROTHER_SERVICES = ["LOGINserver", "USBserver", "NETserver"];
const ORIGINS = [`http://127.0.0.1:${OPTS.port}`, `http://localhost:${OPTS.port}`];
const HOSTS = [`127.0.0.1:${OPTS.port}`, `localhost:${OPTS.port}`];

const CHILD_ENV: Record<string, string> = {
  ...Object.fromEntries(Object.entries(process.env).filter((e): e is [string, string] => e[1] !== undefined)),
  PATH: [BIN, join(HOME, "bin"), "/opt/homebrew/bin", "/usr/local/bin",
         process.env.PATH ?? "/usr/bin:/bin"].join(":"),
  SCAN_ROOT: ROOT,
  SCAN_STAGING: STAGING,
};

// ---------- small helpers ----------

const now = () => new Date().toISOString();
const tool = (name: string) => join(BIN, name);
// Same overrides scan-batch honors, so tests can stand in for the hardware.
const ESCL = process.env.SCAN_BATCH_ESCL ?? tool("escl-scan");
const SCANIMAGE = process.env.SCAN_BATCH_SCANIMAGE ?? "scanimage";
// Tests swap the restart for a stub so they never kill the real Brother services.
const BROTHER_RESTART = process.env.SCAN_BROTHER_RESTART ?? null;

/** batch.json and sidecars write offsets as -0800; Safari's Date wants -08:00. */
function isoFix(s: unknown): string | null {
  if (typeof s !== "string" || s === "") return null;
  return s.replace(/([+-]\d{2})(\d{2})$/, "$1:$2");
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function errCode(e: unknown): string | null {
  return e instanceof Error && "code" in e && typeof e.code === "string" ? e.code : null;
}

function readJson(path: string): Record<string, unknown> | null {
  try {
    const v: unknown = JSON.parse(readFileSync(path, "utf8"));
    return isRecord(v) ? v : null;
  } catch {
    return null;
  }
}

function isDir(path: string): boolean {
  try { return statSync(path).isDirectory(); } catch { return false; }
}

function str(v: unknown): string | null {
  return typeof v === "string" && v !== "" ? v : null;
}

function arrLen(v: unknown): number | null {
  return Array.isArray(v) ? v.length : null;
}

/** Strip ANSI colors, collapse carriage-return progress lines, drop scanimage progress spam. */
function cleanOutput(text: string): string {
  return text
    .replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((line) => {
      const parts = line.split("\r").filter((p) => p !== "");
      return parts.length ? parts[parts.length - 1] : "";
    })
    .filter((line) => !/^Progress:/.test(line))
    .slice(-2000)
    .join("\n");
}

function tail(text: string, n: number): string[] {
  return text.split("\n").map((l) => l.trimEnd()).filter((l) => l !== "").slice(-n);
}

function spawnPiped(cmd: string[]) {
  return Bun.spawn(cmd, { env: CHILD_ENV, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
}

async function run(cmd: string[], timeoutMs: number): Promise<{ code: number | null; out: string; err: string }> {
  let proc: ReturnType<typeof spawnPiped>;
  try {
    proc = spawnPiped(cmd);
  } catch {
    return { code: null, out: "", err: `${cmd[0]} not found` };
  }
  const timer = setTimeout(() => proc.kill(), timeoutMs);
  const work = Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]).then(([out, err, code]) => ({ code, out, err }));
  const late = new Promise<{ code: null; out: string; err: string }>((r) =>
    setTimeout(() => r({ code: null, out: "", err: "timed out" }), timeoutMs + 1000));
  try {
    return await Promise.race([work, late]);
  } finally {
    clearTimeout(timer);
  }
}

function pageFiles(dir: string): Map<number, string> {
  const pages = new Map<number, string>();
  try {
    for (const f of readdirSync(join(dir, "pages"))) {
      const m = /^page-(\d+)\.jpg$/.exec(f);
      if (m) pages.set(Number(m[1]), join(dir, "pages", f));
    }
  } catch { /* no pages dir yet */ }
  return pages;
}

function scannerDefs(): ScannerDef[] {
  const prof = readJson(join(ROOT, "profiles.json"));
  const list: unknown[] = Array.isArray(prof?.scanners) ? prof.scanners : [];
  const defs = list.filter(isRecord).flatMap((s) => {
    const slug = str(s.slug);
    return slug === null ? [] : [{ slug, model: str(s.model) ?? slug, where: str(s.where) }];
  });
  return defs.length ? defs : [
    { slug: "brother", model: "Brother ADS-4300N", where: null },
    { slug: "ix500", model: "Fujitsu ScanSnap iX500", where: null },
  ];
}

function userSlugs(): string[] {
  const prof = readJson(join(ROOT, "profiles.json"));
  const list: unknown[] = Array.isArray(prof?.users) ? prof.users : [];
  return list.filter(isRecord).flatMap((u) => {
    const slug = str(u.slug);
    return slug === null ? [] : [slug];
  });
}

/** Same resolution as scan-batch: an account match in profiles.json, else the login name. */
function defaultUser(): string {
  const login = process.env.USER ?? "unknown";
  const prof = readJson(join(ROOT, "profiles.json"));
  const list: unknown[] = Array.isArray(prof?.users) ? prof.users : [];
  for (const rec of list.filter(isRecord)) {
    const accounts: unknown[] = Array.isArray(rec.accounts) ? rec.accounts : [];
    const slug = str(rec.slug);
    if (slug !== null && (accounts.includes(login) || accounts.includes(`${login}@${HOST}`))) return slug;
  }
  return login.toLowerCase().replace(/[^a-z0-9-]/g, "-");
}

/** A scanner card reflects a batch scanning on it, whatever the last probe said. */
function overlayBusy(list: Scanner[], batches: Batch[]): Scanner[] {
  return list.map((s) => {
    const b = batches.find((x) => x.scanner === s.slug && (x.state === "scanning" || x.state === "stopping"));
    if (!b) return s;
    const pages = `${b.pages} page${b.pages === 1 ? "" : "s"} so far`;
    return {
      ...s,
      present: true,
      state: "scanning",
      batch: b.id,
      detail: b.state === "stopping"
        ? `Stopping batch ${b.id} after the current stack (${pages}).`
        : `Scanning batch ${b.id} for ${b.user ?? "someone"} (${pages}).`,
      // scan-diag probes the device too; mid-batch that fights scan-batch.
      actions: [],
    };
  });
}

/** The running Brother restart job, if any. */
function restartJob(jobs: Job[]): Job | undefined {
  return jobs.find((j) => j.kind === "restart-services" && j.state === "running");
}

/**
 * While a restart runs, the Brother card says so and offers nothing to click.
 * Mid-restart the probe sees NETserver down and would call that an error, and
 * a second restart would kill the first one's helper processes. Diagnose
 * checks every scanner, so it waits on all cards.
 */
function overlayRestart(list: Scanner[], jobs: Job[]): Scanner[] {
  const r = restartJob(jobs);
  if (!r) return list;
  return list.map((s): Scanner => {
    if (s.slug !== "brother" || s.state === "scanning") {
      return { ...s, actions: s.actions.filter((a) => a !== "diag") };
    }
    return {
      ...s,
      state: "restarting",
      detail: "Restarting the Brother services. USBserver is back within seconds, NETserver about 30 s later.",
      actions: [],
    };
  });
}

function batchActions(state: BatchState, pages: number, busy: boolean): string[] {
  if (busy) return ["reveal"];
  switch (state) {
    case "scanning": return ["stop", "reveal"];
    case "stopping": return ["reveal"];
    case "staged": return pages > 0 ? ["resume", "analyze", "reveal", "discard"] : ["resume", "discard"];
    case "ready": return ["file", "analyze", "reveal", "discard"];
    case "filed": return ["analyze", "reveal", "discard"];
  }
}

// ---------- real backend ----------

interface RealJob extends Job { log: string }

class RealBackend implements Backend {
  private jobList: RealJob[] = [];
  private seq = 0;
  private cache: { at: number; data: Map<string, Scanner> } = { at: 0, data: new Map() };
  private probing: Promise<Map<string, Scanner>> | null = null;
  // Bumped when a cached probe is known to be wrong (a restart just ended), so
  // a probe that started before then can't write its stale answer back.
  private gen = 0;

  private invalidate(): void {
    this.gen++;
    this.cache.at = 0;
    this.probing = null;
  }

  jobs(): Job[] {
    for (const j of this.jobList) {
      if (j.kind === "scan" && j.batch === null) {
        const m = /^Batch (\S+) \(/m.exec(this.readLog(j));
        if (m) j.batch = m[1];
      }
    }
    return this.jobList.map(({ log: _log, ...rest }) => ({
      ...rest,
      reload: rest.reload && rest.state === "done",
    }));
  }

  jobOutput(id: string): string | null {
    const j = this.jobList.find((x) => x.id === id);
    return j ? cleanOutput(this.readLog(j)) : null;
  }

  private readLog(j: RealJob): string {
    try { return readFileSync(j.log, "utf8"); } catch { return ""; }
  }

  private start(kind: JobKind, label: string, cmd: string[], batch: string | null = null, reload = false): Job {
    mkdirSync(LOGS, { recursive: true });
    const id = `j${++this.seq}`;
    const stamp = now().replace(/[-:]/g, "").replace(/\..*/, "");
    const log = join(LOGS, `${stamp}-${id}-${kind}.log`);
    const job: RealJob = {
      id, kind, label, state: "running", started: now(), ended: null,
      exit_code: null, summary: null, batch, reload, log,
    };
    const fd = openSync(log, "a");
    try {
      const child = spawn(cmd[0], cmd.slice(1), {
        cwd: HOME, env: CHILD_ENV, stdio: ["ignore", fd, fd], detached: true,
      });
      child.on("exit", (code, signal) => {
        if (signal) appendFileSync(log, `\nStopped by ${signal}.\n`);
        job.exit_code = code;
        job.state = code === 0 ? "done" : "failed";
        job.ended = now();
        job.summary = tail(cleanOutput(this.readLog(job)), 1)[0] ?? null;
        if (kind === "restart-services") this.invalidate();
      });
      child.on("error", (e) => {
        appendFileSync(log, `\n${e.message}\n`);
        job.state = "failed";
        job.ended = now();
        job.summary = e.message;
      });
      child.unref();
    } finally {
      closeSync(fd);
    }
    this.jobList.unshift(job);
    this.jobList.length = Math.min(this.jobList.length, 30);
    return job;
  }

  batches(): Batch[] {
    if (!isDir(STAGING)) return [];
    const jobs = this.jobs();
    const out: Batch[] = [];
    for (const id of readdirSync(STAGING)) {
      if (id.startsWith(".")) continue;
      const dir = join(STAGING, id);
      if (!isDir(join(dir, "pages"))) continue;
      out.push(this.readBatch(id, dir, jobs));
    }
    return out.sort((a, b) => Date.parse(b.updated ?? b.started ?? "") - Date.parse(a.updated ?? a.started ?? ""));
  }

  private scanBatchAlive(dir: string): boolean {
    let pid: number;
    try { pid = Number(readFileSync(join(dir, ".pid"), "utf8").trim()); } catch { return false; }
    if (!Number.isInteger(pid) || pid <= 1) return false;
    try { process.kill(pid, 0); } catch (e) {
      if (errCode(e) !== "EPERM") return false;
    }
    // A stale .pid can point at a recycled pid; make sure it is scan-batch.
    const ps = spawnSync("ps", ["-p", String(pid), "-o", "command="], { encoding: "utf8" });
    return ps.status === 0 && ps.stdout.includes("scan-batch");
  }

  private readBatch(id: string, dir: string, jobs: Job[]): Batch {
    const meta = readJson(join(dir, "batch.json")) ?? {};
    const manifest = readJson(join(dir, "manifest.json"));
    const pages = pageFiles(dir).size;
    const alive = this.scanBatchAlive(dir);
    const state: BatchState = alive
      ? existsSync(join(dir, ".stop")) ? "stopping" : "scanning"
      : existsSync(join(dir, ".filed")) ? "filed" : manifest ? "ready" : "staged";
    const job = jobs.find((j) => j.batch === id) ?? null;
    // .filing is batch-file's lock: a filing run from this server, an earlier
    // server, or a terminal. No other action may touch the batch meanwhile.
    const busy = existsSync(join(dir, ".filing")) ||
      (job !== null && job.state === "running" && (job.kind === "file" || job.kind === "resume") && !alive);
    const duplex = meta.source !== "ADF Front";
    const mine = job ? this.jobList.find((j) => j.id === job.id) : undefined;
    return {
      id, dir, state, pages,
      started: isoFix(meta.started),
      updated: isoFix(meta.updated),
      scanner: str(meta.scanner),
      user: str(meta.user),
      default_entity: str(meta.default_entity),
      mode: str(meta.mode),
      duplex,
      resolution: typeof meta.resolution === "number" ? meta.resolution : null,
      documents: manifest ? arrLen(manifest.documents) : null,
      review_items: manifest ? arrLen(manifest.review) ?? 0 : null,
      odd_pages: duplex && pages % 2 === 1 && state !== "scanning",
      job: job?.id ?? null,
      log_tail: mine ? tail(cleanOutput(this.readLog(mine)), 6) : [],
      actions: batchActions(state, pages, busy),
    };
  }

  async scanners(defs: ScannerDef[], batches: Batch[], force: boolean): Promise<Scanner[]> {
    const busy = new Set(batches.filter((b) => b.state === "scanning" || b.state === "stopping")
      .map((b) => b.scanner ?? ""));
    // An offline Brother costs ~4 s of Bonjour browsing per probe, longer than
    // the page's poll interval. So a stale cache is served at once while a
    // background probe refreshes it; only the first call and actions
    // (force) wait for a fresh result.
    const fresh = Date.now() - this.cache.at < 5000;
    if (force || !fresh) {
      if (!this.probing) {
        const gen = this.gen;
        this.probing = this.probeAll(defs, busy)
          .then((data) => { if (gen === this.gen) this.cache = { at: Date.now(), data }; return data; })
          .finally(() => { if (gen === this.gen) this.probing = null; });
      }
      if (force || this.cache.at === 0) await this.probing;
    }
    const list = defs.map((d) => this.cache.data.get(d.slug) ?? unknownScanner(d));
    return overlayBusy(list, batches);
  }

  private async probeAll(defs: ScannerDef[], busy: Set<string>): Promise<Map<string, Scanner>> {
    const usb = await run(["ioreg", "-p", "IOUSB", "-w0"], 4000);
    const results = await Promise.all(defs.map(async (d): Promise<Scanner> => {
      // Probing a scanner mid-batch would fight scan-batch for the device.
      if (busy.has(d.slug)) return this.cache.data.get(d.slug) ?? unknownScanner(d);
      if (d.slug === "brother") return this.probeBrother(d, usb.out);
      if (d.slug === "ix500") return this.probeIx500(d, usb.out);
      return unknownScanner(d);
    }));
    return new Map(results.map((s) => [s.slug, s]));
  }

  private async probeBrother(d: ScannerDef, ioreg: string): Promise<Scanner> {
    const ps = await run(["pgrep", "-fl", `${BROTHER_SERVER_DIR}/`], 3000);
    // Match the executable path at the start of the command, not any process
    // (a shell, a grep) whose arguments happen to mention it.
    const procs = ps.out.split("\n").map((l) => l.replace(/^\d+ /, ""));
    const services = BROTHER_SERVICES.map((name) => ({
      name, running: procs.some((c) => c.startsWith(`${BROTHER_SERVER_DIR}/${name}.app/`)),
    }));
    const onUsb = /ADS-?4300|Brother/i.test(ioreg);
    const st = await run([ESCL, "--status"], 9000);
    const m = /State=(\S+) Adf=(\S+) Endpoint=(\S+)/.exec(st.out);
    const base: Scanner = {
      slug: d.slug, model: d.model, where: d.where, present: false, connection: onUsb ? "usb" : null,
      state: "offline", detail: "", paper: null, services, batch: null,
      actions: ["diag", "restart-services"], checked: now(),
    };
    if (!m) {
      const down = services.filter((s) => !s.running).map((s) => s.name);
      if (down.length) {
        return { ...base, present: onUsb, state: "error",
          detail: `The Brother services are not running (${down.join(", ")}), so the Mac can't reach the scanner. Restart them.` };
      }
      if (onUsb) {
        return { ...base, present: true, state: "error",
          detail: "On USB but not answering eSCL. Restart the Brother services, or run Diagnose." };
      }
      return { ...base, detail: "Not found. Check it is powered on and plugged in." };
    }
    const [, pwg, adf, endpoint] = m;
    const local = /\/\/(localhost|127\.0\.0\.1)[:/]/.test(endpoint);
    const s: Scanner = { ...base, present: true, connection: local ? "usb" : "network" };
    if (/Jam|Mispick|Multipick/i.test(adf)) {
      return { ...s, state: "jam", paper: null, detail: "Paper jam or misfeed. Clear the feeder, then scan again." };
    }
    if (/HatchOpen|DoorOpen/i.test(adf)) {
      return { ...s, state: "cover-open", paper: null, detail: "The feeder cover is open. Close it." };
    }
    const paper = /Loaded/i.test(adf) ? true : /Empty/i.test(adf) ? false : null;
    if (pwg === "Idle") {
      return { ...s, state: "idle", paper, actions: ["scan", "diag", "restart-services"],
        detail: paper === true ? "Ready. Paper is in the feeder." : paper === false ? "Ready. The feeder is empty." : "Ready." };
    }
    if (pwg === "Processing" || pwg === "Testing") {
      return { ...s, state: "busy", paper, detail: "Busy with a job from another app (Image Capture?)." };
    }
    return { ...s, state: "error", paper, detail: `The scanner reports ${pwg}. Power-cycle it, then run Diagnose.` };
  }

  private async probeIx500(d: ScannerDef, ioreg: string): Promise<Scanner> {
    const base: Scanner = {
      slug: d.slug, model: d.model, where: d.where, present: false, connection: null,
      state: "offline", detail: "Not connected to this Mac. It is USB only, and the lid is its power switch.",
      paper: null, services: null, batch: null, actions: ["diag"], checked: now(),
    };
    if (!/ScanSnap/i.test(ioreg)) return base;
    const list = await run([SCANIMAGE, "-L"], 12000);
    const m = /`(fujitsu:ScanSnap iX500:[^']+)'/.exec(list.out) ?? /(fujitsu:ScanSnap iX500:\S+)/.exec(list.out);
    if (!m) {
      const thief = await run(["pgrep", "-fil", "scansnap"], 3000);
      return { ...base, present: true, connection: "usb", state: "error",
        detail: thief.out.trim()
          ? "On USB, but ScanSnap software is running and holds the scanner. Quit it."
          : "On USB, but SANE can't open it. Open the lid, or run Diagnose." };
    }
    const opts = await run([SCANIMAGE, "-d", m[1], "-A"], 12000);
    const pl = /--page-loaded[^\n]*\[(yes|no)\]/.exec(opts.out);
    const paper = pl ? pl[1] === "yes" : null;
    return { ...base, present: true, connection: "usb", state: "idle", paper,
      actions: ["scan", "diag"],
      detail: paper === true ? "Ready. Paper is in the feeder." : paper === false ? "Ready. The feeder is empty." : "Ready." };
  }

  scan(r: ScanRequest): Job {
    const cmd = [tool("scan-batch"), "--scanner", r.scanner.slug, "--user", r.user, "--idle", String(r.idle)];
    if (!r.duplex) cmd.push("--simplex");
    if (r.gray) cmd.push("--gray");
    return this.start("scan", `Scan on ${r.scanner.model} as ${r.user}`, cmd);
  }

  stop(b: Batch): void {
    writeFileSync(join(b.dir, ".stop"), `${now()}\n`);
  }

  resume(b: Batch, idle: number): Job {
    const cmd = [tool("scan-batch"), "--resume", b.dir, "--idle", String(idle)];
    if (b.scanner) cmd.push("--scanner", b.scanner);
    return this.start("resume", `Resume ${b.id}`, cmd, b.id);
  }

  file(b: Batch): Job {
    return this.start("file", `File ${b.id}`, [tool("batch-file"), "-o", ROOT, b.dir], b.id, true);
  }

  discard(b: Batch): void {
    const trash = join(HOME, ".Trash");
    mkdirSync(trash, { recursive: true });
    let target = join(trash, b.id);
    if (existsSync(target)) target = `${target}-${Date.now()}`;
    try {
      renameSync(b.dir, target);
    } catch {
      const mv = spawnSync("mv", [b.dir, target]);
      if (mv.status !== 0) throw new HttpError(500, `Could not move ${b.id} to the Trash.`);
    }
    rmSync(join(THUMBS, b.id), { recursive: true, force: true });
  }

  reveal(path: string): void {
    spawn("open", [path], { stdio: "ignore", detached: true }).unref();
  }

  diag(): Job {
    return this.start("diag", "Scanner diagnostics", [tool("scan-diag")]);
  }

  restartBrother(): Job {
    // Patterns are anchored to the executable path. Unanchored, pkill -f also
    // matched any shell whose arguments named a service, which is how a second
    // restart click killed the first restart's script.
    const svc = (names: string) => `'^${BROTHER_SERVER_DIR}/(${names})\\.app/'`;
    const up = `pgrep -qf ${svc("USBserver")} && pgrep -qf ${svc("NETserver")}`;
    const script = [
      "echo 'Stopping the Brother services.'",
      `pkill -f ${svc("LOGINserver|USBserver|NETserver")} || true`,
      "sleep 1",
      "echo 'Starting LOGINserver. It starts USBserver at once and NETserver about 30 s later.'",
      `open '${BROTHER_SERVER_DIR}/LOGINserver.app'`,
      "for _ in $(seq 1 60); do",
      `  ${up} && break`,
      "  sleep 1",
      "done",
      "echo 'Running now:'",
      `pgrep -fl '${BROTHER_SERVER_DIR}/' | sed -nE 's#^[0-9]+ ${BROTHER_SERVER_DIR}/(LOGINserver|USBserver|NETserver)\\.app/.*#  \\1#p' | sort -u`,
      `if ${up}; then echo 'All three Brother services are running.'; else`,
      "  echo 'USBserver or NETserver did not come back within 60 s. Log out and back in, then run Diagnose.'; exit 1; fi",
    ].join("\n");
    this.invalidate();
    const cmd = BROTHER_RESTART ? [BROTHER_RESTART] : ["/bin/bash", "-c", script];
    return this.start("restart-services", "Restart Brother services", cmd);
  }

  refresh(): Job {
    return this.start("refresh", "Refresh dashboards", [tool("scan-catalog"), "-r", ROOT, "dashboard"], null, true);
  }

  async thumb(b: Batch, page: number): Promise<Response> {
    const src = pageFiles(b.dir).get(page);
    if (!src) throw new HttpError(404, `No page ${page} in ${b.id}.`);
    const out = join(THUMBS, b.id, `page-${String(page).padStart(3, "0")}.jpg`);
    let stale = true;
    try { stale = statSync(out).mtimeMs < statSync(src).mtimeMs; } catch { /* not made yet */ }
    if (stale) {
      mkdirSync(join(THUMBS, b.id), { recursive: true });
      const r = await run(["sips", "-Z", "360", src, "--out", out], 15000);
      if (r.code !== 0) return fileResponse(src, "image/jpeg");
    }
    return fileResponse(out, "image/jpeg");
  }
}

function unknownScanner(d: ScannerDef): Scanner {
  return {
    slug: d.slug, model: d.model, where: d.where, present: false, connection: null,
    state: "unknown", detail: "No live check for this scanner yet.", paper: null,
    services: null, batch: null, actions: ["diag"], checked: now(),
  };
}

function fileResponse(path: string, type: string): Response {
  return new Response(Bun.file(path), {
    headers: { "Content-Type": type, "Cache-Control": "private, max-age=60" },
  });
}

// ---------- mock backend ----------

interface MockBatch {
  id: string;
  state: BatchState;
  pages: number;
  target: number;
  started: number;
  updated: number;
  scanner: string;
  user: string;
  default_entity: string | null;
  duplex: boolean;
  gray: boolean;
  documents: number | null;
  review_items: number | null;
  stoppedAt: number | null;
  job: string | null;
}

interface MockJob extends Job {
  lines: string[];
  duration: number;
  startedMs: number;
  willFail: boolean;
  onDone?: () => void;
  live?: () => string[];
}

class MockBackend implements Backend {
  private list: MockBatch[];
  private jobList: MockJob[] = [];
  private seq = 0;
  private paperFlip = 0;

  constructor() {
    const t = Date.now();
    const h = 3600_000;
    this.list = [
      { id: "batch-20261108-091200", state: "staged", pages: 12, target: 12, started: t - 2 * h, updated: t - 2 * h + 240_000,
        scanner: "brother", user: "ariel", default_entity: "rio-laundromat", duplex: true, gray: false,
        documents: null, review_items: null, stoppedAt: null, job: null },
      { id: "batch-20261107-163000", state: "ready", pages: 8, target: 8, started: t - 20 * h, updated: t - 19 * h,
        scanner: "brother", user: "eric", default_entity: null, duplex: true, gray: false,
        documents: 5, review_items: 1, stoppedAt: null, job: null },
      { id: "batch-20261106-120500", state: "filed", pages: 5, target: 5, started: t - 45 * h, updated: t - 44 * h,
        scanner: "brother", user: "eric", default_entity: null, duplex: true, gray: false,
        documents: 3, review_items: 1, stoppedAt: null, job: null },
    ];
  }

  private dir(id: string) { return join(STAGING, id); }

  /** Advance the simulation to the current time. */
  private tick(): void {
    const t = Date.now();
    for (const b of this.list) {
      if (b.state === "scanning") {
        b.pages = Math.min(b.target, Math.floor((t - b.started) / 2500) * 2);
        b.updated = t;
        // Feeder empty for a while after the last stack: the idle timeout ends it.
        if (b.pages >= b.target && t - b.started > (b.target / 2) * 2500 + 8000) b.state = "staged";
      } else if (b.state === "stopping" && b.stoppedAt !== null && t - b.stoppedAt > 2500) {
        b.state = "staged";
      }
    }
    for (const j of this.jobList) {
      if (j.state !== "running") continue;
      const b = j.batch ? this.list.find((x) => x.id === j.batch) : undefined;
      const scanning = (j.kind === "scan" || j.kind === "resume") && b !== undefined &&
        (b.state === "scanning" || b.state === "stopping");
      if (scanning) continue;
      if (j.kind === "scan" || j.kind === "resume" || t - j.startedMs >= j.duration) {
        j.state = j.willFail ? "failed" : "done";
        j.exit_code = j.willFail ? 1 : 0;
        j.ended = now();
        j.summary = this.shown(j).at(-1) ?? null;
        j.onDone?.();
      }
    }
  }

  private add(kind: JobKind, label: string, lines: string[], duration: number,
              extra: Partial<MockJob> = {}): Job {
    const job: MockJob = {
      id: `j${++this.seq}`, kind, label, state: "running", started: now(), ended: null,
      exit_code: null, summary: null, batch: null, reload: false, lines, duration, startedMs: Date.now(),
      willFail: false, ...extra,
    };
    this.jobList.unshift(job);
    this.jobList.length = Math.min(this.jobList.length, 30);
    return job;
  }

  private shown(j: MockJob): string[] {
    if (j.live) return j.live();
    if (j.state !== "running") return j.lines;
    const frac = Math.min(1, (Date.now() - j.startedMs) / j.duration);
    return j.lines.slice(0, Math.max(1, Math.ceil(j.lines.length * frac)));
  }

  jobs(): Job[] {
    this.tick();
    return this.jobList.map(({ lines: _l, duration: _d, startedMs: _s, willFail: _w, onDone: _o, live: _v, ...rest }) => ({
      ...rest, reload: rest.reload && rest.state === "done",
    }));
  }

  jobOutput(id: string): string | null {
    this.tick();
    const j = this.jobList.find((x) => x.id === id);
    return j ? this.shown(j).join("\n") : null;
  }

  batches(): Batch[] {
    this.tick();
    return this.list
      .map((b): Batch => {
        const job = this.jobList.find((j) => j.batch === b.id) ?? null;
        const busy = job !== null && job.state === "running" && job.kind === "file";
        return {
          id: b.id, dir: this.dir(b.id), state: b.state, pages: b.pages,
          started: new Date(b.started).toISOString(), updated: new Date(b.updated).toISOString(),
          scanner: b.scanner, user: b.user, default_entity: b.default_entity,
          mode: b.gray ? "Gray" : "Color", duplex: b.duplex, resolution: 300,
          documents: b.documents, review_items: b.review_items,
          odd_pages: b.duplex && b.pages % 2 === 1 && b.state !== "scanning",
          job: job?.id ?? null,
          log_tail: job ? tail(this.shown(job).join("\n"), 6) : [],
          actions: batchActions(b.state, b.pages, busy),
        };
      })
      .sort((a, b) => Date.parse(b.updated ?? "") - Date.parse(a.updated ?? ""));
  }

  async scanners(defs: ScannerDef[], batches: Batch[]): Promise<Scanner[]> {
    this.paperFlip++;
    const list = defs.map((d): Scanner => {
      const checked = now();
      if (d.slug === "brother") {
        const paper = Math.floor(this.paperFlip / 4) % 3 !== 2;
        return { slug: d.slug, model: d.model, where: d.where, present: true, connection: "usb",
          state: "idle", paper, detail: paper ? "Ready. Paper is in the feeder." : "Ready. The feeder is empty.",
          services: BROTHER_SERVICES.map((name) => ({ name, running: true })), batch: null,
          actions: ["scan", "diag", "restart-services"], checked };
      }
      if (d.slug === "ix500") {
        return { slug: d.slug, model: d.model, where: d.where, present: false, connection: null,
          state: "offline", paper: null, services: null, batch: null, actions: ["diag"], checked,
          detail: "Not connected to this Mac. It is USB only, and the lid is its power switch." };
      }
      return unknownScanner(d);
    });
    return overlayBusy(list, batches);
  }

  scan(r: ScanRequest): Job {
    const t = new Date();
    const pad = (n: number) => String(n).padStart(2, "0");
    const id = `batch-${t.getFullYear()}${pad(t.getMonth() + 1)}${pad(t.getDate())}-${pad(t.getHours())}${pad(t.getMinutes())}${pad(t.getSeconds())}`;
    const b: MockBatch = {
      id, state: "scanning", pages: 0, target: r.duplex ? 16 : 8, started: Date.now(), updated: Date.now(),
      scanner: r.scanner.slug, user: r.user, default_entity: r.user === "ariel" ? "rio-laundromat" : r.user === "elsa" ? "personal" : null,
      duplex: r.duplex, gray: r.gray, documents: null, review_items: null, stoppedAt: null, job: null,
    };
    this.list.unshift(b);
    const header = `Batch ${id} (${r.duplex ? "ADF Duplex" : "ADF Front"}, ${r.gray ? "Gray" : "Color"}, 300dpi) for ${r.user} on ${r.scanner.slug}`;
    return this.add("scan", `Scan on ${r.scanner.model} as ${r.user}`, [], 0, {
      batch: id,
      live: () => this.scanLines(b, header),
    });
  }

  private scanLines(b: MockBatch, header: string): string[] {
    const lines = [header, `Feed the ADF. Enter ends the batch (or the dashboard's Stop); idle timeout 60s.`];
    const step = b.duplex ? 4 : 2;
    for (let n = step; n <= b.pages; n += step) lines.push(`Chunk done: ${step} page(s), total ${n}.`);
    if (b.state === "stopping" || (b.state === "staged" && b.stoppedAt !== null)) lines.push("Stop requested.");
    if (b.state === "staged") lines.push(`Batch complete: ${b.pages} page(s).`, this.dir(b.id));
    return lines;
  }

  stop(b: Batch): void {
    const m = this.list.find((x) => x.id === b.id);
    if (m) { m.state = "stopping"; m.stoppedAt = Date.now(); m.target = m.pages; }
  }

  resume(b: Batch): Job {
    const m = this.list.find((x) => x.id === b.id);
    if (!m) throw new HttpError(404, "No such batch.");
    const base = m.pages;
    m.state = "scanning"; m.stoppedAt = null; m.target = base + 6;
    m.started = Date.now() - (base / 2) * 2500;
    return this.add("resume", `Resume ${m.id}`, [], 0, {
      batch: m.id, live: () => this.scanLines(m, `Batch ${m.id} resumed at page ${base + 1}`),
    });
  }

  file(b: Batch): Job {
    const m = this.list.find((x) => x.id === b.id);
    if (!m) throw new HttpError(404, "No such batch.");
    const lines = [
      `Filing ${m.id} into ${ROOT}`,
      "  rio-laundromat/receipts/2026/receipt-2026-11-03-home-depot $45.23.pdf",
      "  rio-laundromat/invoices/2026/invoice-2026-11-01-ecolab $312.00.pdf",
      "  personal/taxes/2025/tax-2025-1099-int-chase.pdf  (copied to Baruch/Tax/2025)",
      "  rio-laundromat/paychecks/2026/checks20261031.pdf  (3 checks)",
      `  _review/review-${m.id}-01.pdf  (total unreadable)`,
      `Filed ${m.documents ?? 0} document(s), 1 paycheck(s), ${m.review_items ?? 0} held for review.`,
      `Dashboards refreshed: ${ROOT}/dashboard.html`,
      "Follow-ups pending: 3 (scan-catalog pending)",
      `Staging kept: ${this.dir(m.id)}`,
    ];
    return this.add("file", `File ${m.id}`, lines, 4000, {
      batch: m.id, reload: true,
      onDone: () => { m.state = (m.review_items ?? 0) > 0 ? "filed" : "staged"; if (m.state === "staged") this.list = this.list.filter((x) => x !== m); },
    });
  }

  discard(b: Batch): void {
    this.list = this.list.filter((x) => x.id !== b.id);
  }

  reveal(): void { /* nothing to show in mock mode */ }

  diag(): Job {
    return this.add("diag", "Scanner diagnostics", [
      "scan-diag: scanning stack (Brother ADS-4300N / ScanSnap iX500)",
      "",
      "PASS  jq, img2pdf, qpdf, poppler installed",
      "PASS  Brother services running (LOGINserver, USBserver, NETserver)",
      "PASS  eSCL endpoint answers: http://localhost:60123/eSCL",
      "PASS  Brother state: Idle, feeder loaded",
      "SKIP  iX500 not on USB",
      "PASS  filing root: " + ROOT,
      "",
      "6 passed, 0 failed",
    ], 3000);
  }

  restartBrother(): Job {
    return this.add("restart-services", "Restart Brother services", [
      "Stopping the Brother services.",
      "Starting LOGINserver. It starts USBserver at once and NETserver about 30 s later.",
      "Running now:", "  LOGINserver", "  NETserver", "  USBserver",
      "All three Brother services are running.",
    ], 8000);
  }

  refresh(): Job {
    return this.add("refresh", "Refresh dashboards", [
      `${ROOT}/dashboard.html`,
    ], 1500, { reload: true });
  }

  async thumb(b: Batch, page: number): Promise<Response> {
    if (page < 1 || page > b.pages) throw new HttpError(404, `No page ${page} in ${b.id}.`);
    const back = b.duplex && page % 2 === 0;
    const rows = back ? "" : Array.from({ length: 9 }, (_, i) =>
      `<rect x="22" y="${70 + i * 24}" width="${180 - ((i * 37 + page * 13) % 70)}" height="7" rx="2" fill="#d5dae1"/>`).join("");
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="255" height="330" viewBox="0 0 255 330">` +
      `<rect width="255" height="330" fill="#fdfdfc"/>` +
      (back ? `<text x="127" y="170" font-family="sans-serif" font-size="13" text-anchor="middle" fill="#b4bac4">blank back</text>`
            : `<rect x="22" y="26" width="110" height="14" rx="2" fill="#9aa3b0"/><rect x="170" y="26" width="62" height="14" rx="2" fill="#c3c9d1"/>${rows}`) +
      `<text x="233" y="314" font-family="sans-serif" font-size="15" text-anchor="end" fill="#8a93a3">p. ${page}</text></svg>`;
    return new Response(svg, { headers: { "Content-Type": "image/svg+xml", "Cache-Control": "private, max-age=600" } });
  }
}

// ---------- page ----------

async function buildCatalog(): Promise<unknown> {
  const r = await run([tool("scan-catalog"), "-r", ROOT, "build"], 60000);
  if (r.code !== 0) {
    console.error(`scan-it server: scan-catalog build failed: ${r.err.trim()}`);
    return null;
  }
  try {
    const c: unknown = JSON.parse(r.out);
    return isRecord(c) ? { ...c, link_prefix: "/files/" } : null;
  } catch {
    return null;
  }
}

/** JSON safe inside a <script> block: every "<" escaped, as scan-catalog does. */
const scriptJson = (v: unknown) => JSON.stringify(v).replace(/</g, "\\u003c");

async function page(): Promise<Response> {
  let html: string;
  try { html = readFileSync(TEMPLATE, "utf8"); } catch {
    return new Response(`Dashboard template missing: ${TEMPLATE}`, { status: 500 });
  }
  const catalog = await buildCatalog();
  const live = {
    api: "/api", files: "/files/", token: TOKEN, started: STARTED, host: HOST,
    default_user: defaultUser(), mock: OPTS.mock, poll_ms: 3000,
    url: `http://127.0.0.1:${OPTS.port}/`,
  };
  const body = html
    .split("\n")
    .map((line) => {
      if (line.includes("/*__CATALOG__*/")) return catalog === null ? line : scriptJson(catalog);
      if (line.includes("/*__LIVE__*/")) return scriptJson(live);
      return line;
    })
    .join("\n")
    .split("default-src 'none';").join("default-src 'none'; connect-src 'self';")
    .split("img-src data:").join("img-src 'self' data:");
  return new Response(body, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer",
    },
  });
}

// ---------- HTTP ----------

const backend: Backend = OPTS.mock ? new MockBackend() : new RealBackend();

const json = (v: unknown, status = 200) =>
  new Response(JSON.stringify(v), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

function tokenOk(req: Request): boolean {
  const got = Buffer.from(req.headers.get("x-scan-token") ?? "");
  const want = Buffer.from(TOKEN);
  return got.length === want.length && timingSafeEqual(got, want);
}

async function body(req: Request): Promise<Record<string, unknown>> {
  try {
    const v: unknown = await req.json();
    return isRecord(v) ? v : {};
  } catch {
    return {};
  }
}

function idleOf(v: unknown): number {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? Math.min(3600, Math.max(10, Math.round(n))) : 60;
}

function findBatch(id: string): Batch {
  const b = backend.batches().find((x) => x.id === id);
  if (!b) throw new HttpError(404, `No staged batch ${id}. It may have been filed or discarded.`);
  return b;
}

function requireAction(b: Batch, action: string, why: string): void {
  if (!b.actions.includes(action)) throw new HttpError(409, why);
}

async function status(force = false) {
  const batches = backend.batches();
  const probed = await backend.scanners(scannerDefs(), batches, force);
  const jobs = backend.jobs();
  return { now: now(), mock: OPTS.mock, scanners: overlayRestart(probed, jobs), batches, jobs };
}

async function handle(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname;
  const host = req.headers.get("host") ?? "";
  if (!HOSTS.includes(host)) return new Response("Wrong host.", { status: 421 });

  if (req.method === "GET") {
    if (path === "/" || path === "/index.html") return page();
    if (path === "/api/ping") return json({ app: "scan-it", root: ROOT, started: STARTED, mock: OPTS.mock });
    if (path === "/api/status") return json(await status());
    let m = /^\/api\/jobs\/([A-Za-z0-9]+)$/.exec(path);
    if (m) {
      const job = backend.jobs().find((j) => j.id === m?.[1]);
      if (!job) throw new HttpError(404, "No such job.");
      return json({ ...job, output: backend.jobOutput(job.id) ?? "" });
    }
    m = /^\/api\/batches\/([A-Za-z0-9._-]+)\/thumb\/(\d+)$/.exec(path);
    if (m) return backend.thumb(findBatch(m[1]), Number(m[2]));
    if (path.startsWith("/files/")) {
      let rel: string;
      try { rel = path.slice("/files/".length).split("/").map(decodeURIComponent).join("/"); } catch {
        throw new HttpError(400, "Bad path.");
      }
      const abs = resolve(ROOT, rel);
      if (!abs.startsWith(ROOT + sep) || !/\.pdf$/i.test(abs) || !existsSync(abs)) {
        throw new HttpError(404, "No such PDF under the filing root.");
      }
      return new Response(Bun.file(abs), {
        headers: { "Content-Type": "application/pdf", "Content-Disposition": "inline", "Cache-Control": "no-store" },
      });
    }
    if (path === "/favicon.ico") return new Response(null, { status: 204 });
    throw new HttpError(404, "Not found.");
  }

  if (req.method !== "POST") throw new HttpError(405, "Method not allowed.");
  const origin = req.headers.get("origin");
  if (origin !== null && !ORIGINS.includes(origin)) throw new HttpError(403, "Cross-origin request refused.");
  if (!tokenOk(req)) throw new HttpError(403, "Missing or stale token. Reload the page.");
  const b = await body(req);

  if (path === "/api/scan") {
    const slug = str(b.scanner);
    const def = scannerDefs().find((d) => d.slug === slug);
    if (!def) throw new HttpError(400, "Pick a scanner.");
    const user = str(b.user) ?? defaultUser();
    if (!/^[a-z0-9][a-z0-9-]*$/.test(user)) throw new HttpError(400, "The user must be a lowercase slug.");
    const known = userSlugs();
    if (known.length && !known.includes(user)) throw new HttpError(400, `${user} is not in profiles.json.`);
    const s = (await status(true)).scanners.find((x) => x.slug === def.slug);
    if (s?.state === "scanning") throw new HttpError(409, `The ${def.model} is already scanning ${s.batch}.`);
    if (!s?.actions.includes("scan")) throw new HttpError(409, `The ${def.model} isn't ready. ${s?.detail ?? ""}`.trim());
    const job = backend.scan({ scanner: def, user, duplex: b.duplex !== false, gray: b.gray === true, idle: idleOf(b.idle) });
    return json({ job: job.id });
  }

  let m = /^\/api\/batches\/([A-Za-z0-9._-]+)\/(stop|resume|file|discard|reveal)$/.exec(path);
  if (m) {
    const batch = findBatch(m[1]);
    switch (m[2]) {
      case "stop":
        requireAction(batch, "stop", `${batch.id} is not scanning.`);
        backend.stop(batch);
        return json({ ok: true });
      case "resume": {
        requireAction(batch, "resume", `${batch.id} can't be resumed while it is ${batch.state}.`);
        const s = (await status(true)).scanners.find((x) => x.slug === batch.scanner);
        if (s?.state === "scanning") throw new HttpError(409, `The ${s.model} is busy with ${s.batch}.`);
        return json({ job: backend.resume(batch, idleOf(b.idle)).id });
      }
      case "file":
        requireAction(batch, "file", batch.state === "staged"
          ? `${batch.id} has no manifest yet. Analyze it with Claude first.`
          : `${batch.id} can't be filed while it is ${batch.state}.`);
        return json({ job: backend.file(batch).id });
      case "discard":
        requireAction(batch, "discard", `${batch.id} is busy. Stop it first.`);
        backend.discard(batch);
        return json({ ok: true });
      case "reveal":
        backend.reveal(batch.dir);
        return json({ ok: true });
    }
  }

  m = /^\/api\/(diag|brother\/restart|dashboard\/refresh|reveal)$/.exec(path);
  if (m) {
    switch (m[1]) {
      case "diag": {
        const scanning = backend.batches().find((x) => x.state === "scanning" || x.state === "stopping");
        if (scanning) throw new HttpError(409, `${scanning.id} is scanning. Run Diagnose after it ends.`);
        const r = restartJob(backend.jobs());
        if (r) throw new HttpError(409, `The Brother services are restarting (${r.id}). Run Diagnose when that job finishes.`);
        return json({ job: backend.diag().id });
      }
      case "brother/restart": {
        const busy = backend.batches().find((x) => x.scanner === "brother" && (x.state === "scanning" || x.state === "stopping"));
        if (busy) throw new HttpError(409, `The Brother is scanning ${busy.id}. Stop it first.`);
        const r = restartJob(backend.jobs());
        if (r) throw new HttpError(409, `The Brother services are already restarting (${r.id}). It takes about 30 s.`);
        return json({ job: backend.restartBrother().id });
      }
      case "dashboard/refresh": return json({ job: backend.refresh().id });
      case "reveal":
        backend.reveal(ROOT);
        return json({ ok: true });
    }
  }
  throw new HttpError(404, "Not found.");
}

let server: ReturnType<typeof Bun.serve>;
try {
  server = Bun.serve({
    hostname: "127.0.0.1",
    port: OPTS.port,
    idleTimeout: 60,
    async fetch(req) {
      try {
        return await handle(req);
      } catch (e) {
        if (e instanceof HttpError) return json({ error: e.message }, e.status);
        console.error(e);
        return json({ error: "The server hit an error. Check its terminal." }, 500);
      }
    },
  });
} catch (e) {
  fatal(`can't listen on 127.0.0.1:${OPTS.port} (${e instanceof Error ? e.message : String(e)}). Is another program using it? Pass --port.`);
}

const url = `http://127.0.0.1:${server.port}/`;
console.log(`scan-it live dashboard: ${url}${OPTS.mock ? "  (mock data)" : ""}`);
console.log(`  filing root: ${ROOT}`);
console.log(`  staging:     ${STAGING}`);
console.log("  Ctrl-C stops the server. Scans and filing jobs it started keep running.");
if (OPTS.open) spawn("open", [url], { stdio: "ignore", detached: true }).unref();
