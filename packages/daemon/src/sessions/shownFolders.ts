/** The folders the user says the list of sessions shows, and the ones they say it hides (docs/terminal-v0.md §1
 *  “名单”, 2026-11-11). The list leaves out sessions in temporary folders by itself (probes', executors'); a session
 *  left out could be neither seen nor deleted (user: 不显示的话我都管理不了；在搜索旁边加一个加号，输入目录之后就可以
 *  展示在侧边栏并强行扫里面的session…再加一个对目录右键选择隐藏的功能). What the user says comes first: a folder
 *  shown is listed with everything under it wherever it is; a folder hidden is not listed, nor anything under it.
 *  Hiding deletes nothing.
 *
 *  A folder is the same folder by either of its names: `/tmp/x` is `/private/tmp/x` on macOS, and agents record
 *  whichever they were started with (user: 扫描/tmp的时候记得要把/private/tmp也算进去). */

import { mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, normalize } from "node:path";

export type ShownFolders = { readonly shown: readonly string[]; readonly hidden: readonly string[] };
const MAX_FOLDERS = 200, MAX_PATH = 1000;
/** macOS keeps these three under `/private`; the short names are links. */
const PRIVATE = ["/tmp", "/var", "/etc"] as const;

/** A folder's one spelling: as the disk has it where it is there, else with macOS's `/private` put before the three
 *  it keeps there; no slash at its end. */
export function canonicalFolder(path: string): string {
  const plain = normalize(path).replace(/\/+$/, "") || "/";
  try { return realpathSync(plain); } catch { /* not there (a temporary folder cleared away): by its name */ }
  const short = PRIVATE.find((p) => plain === p || plain.startsWith(`${p}/`));
  return short && process.platform === "darwin" ? `/private${plain}` : plain;
}

/** Both names a folder may be recorded under: the canonical one, and without `/private` where it has it. */
export function folderNames(path: string): string[] {
  const full = canonicalFolder(path);
  const short = full.startsWith("/private/") && PRIVATE.some((p) => full === `/private${p}` || full.startsWith(`/private${p}/`)) ? full.slice("/private".length) : null;
  return short ? [full, short] : [full];
}

/** `cwd` is `root` or under it, by either name of each. */
export function folderWithin(cwd: string, root: string): boolean {
  const at = canonicalFolder(cwd), top = canonicalFolder(root);
  return at === top || at.startsWith(top === "/" ? "/" : `${top}/`);
}

/** What was typed as a folder, whole: `~` is the home folder; null for what is not an absolute path. */
export function typedFolder(text: string, home: string = homedir()): string | null {
  const t = text.trim();
  const path = t === "~" ? home : t.startsWith("~/") ? join(home, t.slice(2)) : t;
  if (!path.startsWith("/") || path.length > MAX_PATH || path.includes("\0")) return null;
  return canonicalFolder(path);
}

export class ShownFoldersStore {
  private readonly file: string;
  private kept: ShownFolders | null = null;

  constructor(home: string) { this.file = join(home, "sessions", "folders.json"); }

  get(): ShownFolders {
    if (this.kept) return this.kept;
    try { this.kept = clean(JSON.parse(readFileSync(this.file, "utf8"))); } catch { this.kept = { shown: [], hidden: [] }; }
    return this.kept;
  }

  /** `folder` is shown from now on (and no longer hidden, nor anything above or under it that was hidden for it). */
  show(folder: string): ShownFolders {
    const now = this.get();
    return this.save({ shown: [...now.shown.filter((f) => !folderWithin(f, folder)), folder], hidden: now.hidden.filter((f) => !folderWithin(folder, f) && !folderWithin(f, folder)) });
  }

  /** `folder` is hidden from now on, with everything under it (what was shown under it is no longer said to be). */
  hide(folder: string): ShownFolders {
    const now = this.get();
    return this.save({ shown: now.shown.filter((f) => !folderWithin(f, folder)), hidden: [...now.hidden.filter((f) => !folderWithin(f, folder)), folder] });
  }

  /** Nothing is said of `folder` any more: it is listed, or not, as any folder is. */
  forget(folder: string): ShownFolders {
    const now = this.get(), same = (f: string) => canonicalFolder(f) === canonicalFolder(folder);
    return this.save({ shown: now.shown.filter((f) => !same(f)), hidden: now.hidden.filter((f) => !same(f)) });
  }

  private save(next: ShownFolders): ShownFolders {
    const kept = clean(next);
    mkdirSync(dirname(this.file), { recursive: true, mode: 0o700 });
    const tmp = `${this.file}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(kept, null, 2), { mode: 0o600 });
    renameSync(tmp, this.file);
    return (this.kept = kept);
  }
}

function clean(raw: unknown): ShownFolders {
  const o = (raw && typeof raw === "object" ? raw : {}) as { shown?: unknown; hidden?: unknown };
  const list = (v: unknown): string[] => [...new Set((Array.isArray(v) ? v : []).filter((x): x is string => typeof x === "string" && x.startsWith("/") && x.length <= MAX_PATH).map(canonicalFolder))].slice(-MAX_FOLDERS);
  return { shown: list(o.shown), hidden: list(o.hidden) };
}
