/** What a terminal leaves running after it ended (docs/terminal-v0.md §11). A terminal's program ends with SIGHUP to its
 *  process group; what the agent started outside that group — `nohup … &`, `setsid`, a job in the background — lives
 *  on, reparented to launchd, with the CPU and memory it had (2026-11-04, user: 有的时候session死了但是工具还在跑). Every
 *  process started under a terminal inherits `AGENTSWITCH_TERMINAL_ID` and `AGENTSWITCH_TERMINAL_URL` from it, and that
 *  is the handle: whatever still carries this service's address and the id of a terminal that is not running any more
 *  is a leftover. Thirty seconds after a terminal ended, its leftovers are ended (SIGTERM, SIGKILL after a moment); now
 *  and then every leftover is, which covers a service that restarted or crashed. No exceptions (the user, 2026-11-04:
 *  不留口子): what should outlive a terminal is started elsewhere.
 *
 *  macOS: `ps -E` appends each process's environment to its command, for the caller's own processes. Linux: `ps` for the
 *  table and `/proc/<pid>/environ` for the environment, readable for one's own processes. A process that scrubbed its
 *  environment (`env -i`) or one launchd started is not found: that is the edge of this. */

import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { promisify } from "node:util";

const run = promisify(execFile);
const PS_TIMEOUT_MS = 10_000;
const PS_BUFFER = 64 * 1024 * 1024;

/** How long after a terminal ended its leftovers are given before they are ended. */
export const LEFTOVER_GRACE_MS = 30_000;
/** How often every leftover is looked for. */
export const LEFTOVER_SWEEP_MS = 60_000;
/** After SIGTERM, how long before SIGKILL. */
const HARD_AFTER_MS = 3_000;

export type Leftover = {
  readonly pid: number;
  readonly ppid: number;
  readonly pgid: number;
  /** The terminal whose program it descends from, and the service address that terminal was started with. */
  readonly terminal: string;
  readonly url: string;
  /** As `ps` says them: elapsed time (`etime`), CPU percent, resident memory in KB. */
  readonly elapsed: string;
  readonly cpu: number;
  readonly rssKb: number;
  readonly command: string;
};

type Row = { pid: number; ppid: number; pgid: number; elapsed: string; cpu: number; rssKb: number; rest: string };

/** `ps -o pid=,ppid=,pgid=,etime=,pcpu=,rss=,<command>=` lines. */
function parseRows(stdout: string): Row[] {
  const rows: Row[] = [];
  for (const line of stdout.split("\n")) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+([\d.]+)\s+(\d+)\s+(.*)$/.exec(line);
    if (m) rows.push({ pid: Number(m[1]), ppid: Number(m[2]), pgid: Number(m[3]), elapsed: m[4]!, cpu: Number(m[5]), rssKb: Number(m[6]), rest: m[7]! });
  }
  return rows;
}

/** The terminal's tags in an environment, as `NAME=value` pairs separated by `sep`. */
function tagsOf(env: string, sep: RegExp): { terminal: string; url: string } | null {
  let terminal: string | undefined, url: string | undefined;
  for (const pair of env.split(sep)) {
    if (pair.startsWith("AGENTSWITCH_TERMINAL_ID=")) terminal = pair.slice("AGENTSWITCH_TERMINAL_ID=".length);
    else if (pair.startsWith("AGENTSWITCH_TERMINAL_URL=")) url = pair.slice("AGENTSWITCH_TERMINAL_URL=".length);
  }
  return terminal && /^[\w-]{1,64}$/.test(terminal) && url ? { terminal, url } : null;
}

/** macOS `ps -E`'s lines: the command, then the environment, all in one column. The command is what comes before the
 *  first word shaped like a variable (`NAME=…`); an option of the command's own (`--flag=x`) is not one. */
export function parsePsEnv(stdout: string): Leftover[] {
  const out: Leftover[] = [];
  for (const r of parseRows(stdout)) {
    const at = r.rest.search(/(?:^|\s)[A-Z_][A-Z0-9_]*=/);
    if (at < 0) continue;
    const tags = tagsOf(r.rest.slice(at).trim(), /\s+(?=[A-Z_][A-Z0-9_]*=)/);
    if (!tags) continue;
    out.push({ pid: r.pid, ppid: r.ppid, pgid: r.pgid, elapsed: r.elapsed, cpu: r.cpu, rssKb: r.rssKb, ...tags, command: r.rest.slice(0, at).trim().slice(0, 300) });
  }
  return out;
}

/** Linux: the table from `ps`, each process's environment from /proc (one's own processes; the rest are not readable,
 *  and not ours). */
export function withProcEnviron(stdout: string, environ: (pid: number) => string | null = procEnviron): Leftover[] {
  const out: Leftover[] = [];
  for (const r of parseRows(stdout)) {
    const env = environ(r.pid);
    const tags = env ? tagsOf(env, /\0/) : null;
    if (tags) out.push({ pid: r.pid, ppid: r.ppid, pgid: r.pgid, elapsed: r.elapsed, cpu: r.cpu, rssKb: r.rssKb, ...tags, command: r.rest.trim().slice(0, 300) });
  }
  return out;
}

function procEnviron(pid: number): string | null {
  try { return readFileSync(`/proc/${pid}/environ`, "latin1"); } catch { return null; }
}

/** Every process on this machine that was started under one of AgentSwitch's terminals (any service's), as `ps` sees
 *  it now. */
export async function taggedProcesses(platform: NodeJS.Platform = process.platform): Promise<Leftover[]> {
  if (platform === "darwin") {
    const { stdout } = await run("ps", ["-axwwEo", "pid=,ppid=,pgid=,etime=,pcpu=,rss=,command="], { timeout: PS_TIMEOUT_MS, maxBuffer: PS_BUFFER });
    return parsePsEnv(stdout);
  }
  const { stdout } = await run("ps", ["-axwwo", "pid=,ppid=,pgid=,etime=,pcpu=,rss=,args="], { timeout: PS_TIMEOUT_MS, maxBuffer: PS_BUFFER });
  return withProcEnviron(stdout);
}

function isAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch (err) { return (err as NodeJS.ErrnoException).code === "EPERM"; }
}

export type LeftoversOptions = {
  /** The address this service gives its terminals (`http://127.0.0.1:<port>`): only what carries it is this service's
   *  — another service on this machine (a test's, a development copy's) has terminals of its own. */
  readonly url: () => string;
  /** The terminals whose program runs now: nothing of theirs is left yet. */
  readonly live: () => ReadonlySet<string>;
  readonly source?: () => Promise<Leftover[]>;
  readonly kill?: (pid: number, signal: NodeJS.Signals) => void;
  readonly alive?: (pid: number) => boolean;
  readonly graceMs?: number;
  readonly sweepMs?: number;
  readonly hardAfterMs?: number;
  readonly log?: (line: string) => void;
};

export class Leftovers {
  private timer: NodeJS.Timeout | null = null;
  private readonly pending = new Map<string, NodeJS.Timeout>();
  private stopped = false;

  constructor(private readonly o: LeftoversOptions) {}

  /** What is left now: this service's, of a terminal that is not running, not this process. */
  async list(): Promise<Leftover[]> {
    const url = this.o.url(), live = this.o.live();
    let all: Leftover[];
    try { all = await (this.o.source ?? taggedProcesses)(); }
    catch (err) { this.o.log?.(`terminals: leftovers not listed: ${(err as Error).message}`); return []; }
    return all.filter((p) => p.url === url && !live.has(p.terminal) && p.pid > 1 && p.pid !== process.pid && p.pid !== process.ppid);
  }

  /** Terminal `id` ended — its program exited, or it was deleted: what it left is ended after the grace. */
  ended(id: string): void {
    if (this.stopped || this.pending.has(id)) return;
    const t = setTimeout(() => { this.pending.delete(id); void this.sweep(id); }, this.o.graceMs ?? LEFTOVER_GRACE_MS);
    t.unref();
    this.pending.set(id, t);
  }

  /** Ends the leftovers — of terminal `only`, of the pids `only` names, or all — SIGTERM first, SIGKILL for what is
   *  still there after a moment. Returns what was ended. */
  async sweep(only?: string | readonly number[]): Promise<Leftover[]> {
    const left = (await this.list()).filter((p) => only === undefined || (typeof only === "string" ? p.terminal === only : only.includes(p.pid)));
    if (!left.length) return [];
    const kill = this.o.kill ?? ((pid: number, signal: NodeJS.Signals) => { process.kill(pid, signal); });
    const alive = this.o.alive ?? isAlive;
    for (const p of left) { try { kill(p.pid, "SIGTERM"); } catch { /* gone already */ } }
    await new Promise<void>((resolve) => { setTimeout(resolve, this.o.hardAfterMs ?? HARD_AFTER_MS).unref(); });
    let hard = 0;
    for (const p of left) if (alive(p.pid)) { hard += 1; try { kill(p.pid, "SIGKILL"); } catch { /* gone meanwhile */ } }
    const terminals = [...new Set(left.map((p) => p.terminal))].join(", ");
    this.o.log?.(`terminals: ${left.length} left behind by ${terminals} ended${hard ? ` (${hard} by SIGKILL)` : ""}: ${left.map((p) => `${p.pid} ${p.command.split(/\s+/)[0]}`).join(", ")}`);
    return left;
  }

  /** Every leftover ended now and then from now on — a service that starts finds what the last one's terminals left. */
  start(): void {
    if (this.timer || this.stopped) return;
    this.timer = setInterval(() => { void this.sweep(); }, this.o.sweepMs ?? LEFTOVER_SWEEP_MS);
    this.timer.unref();
  }

  stop(): void {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    for (const t of this.pending.values()) clearTimeout(t);
    this.pending.clear();
  }
}
