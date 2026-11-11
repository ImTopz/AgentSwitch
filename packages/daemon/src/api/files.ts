/** Uploads are staged, then moved into the task's own folder in the data directory by POST /tasks; what an agent hands
 *  back is written beside them (`artifacts/<task>/in`, `…/out`; files/names.ts, 2026-11-11). Downloads come from there.
 *  A task from before that kept both in its working directory: its files are still read from `<cwd>/in/` and
 *  `<cwd>/out/` only, never the rest of a user-chosen cwd, never through a symlink or hard link, never from a place
 *  that holds credentials (the cwd rules are applied again to the cwd and to the resolved file) — and of `out/`, which
 *  every task in that folder shared, only what was written while the task ran.
 *  `GET /attachments` lists every task's kept files together, `DELETE /attachments[/:id]` removes them (the tasks stay). */

import type { Hono } from "hono";
import { createReadStream, lstatSync, readdirSync, realpathSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { Readable } from "node:stream";
import { listTree, resolveInside, type TreeEntry } from "../files/artifacts.js";
import { ARTIFACT_TTL_MS, ATTACH_DIR, contentType, isImage, MAX_FILE_BYTES, MAX_FILES_PER_UPLOAD, OUT_DIR } from "../files/names.js";
import { TERMINAL, type Task } from "../engine/types.js";
import { checkStoredCwd, deniedRootOf, isWorkDir, physicalPath } from "./cwdPolicy.js";
import type { ApiDeps } from "./shared.js";

/** A downloaded file is data, never a page of this origin: an SVG or HTML deliverable opened directly runs no script. */
const DOWNLOAD_HEADERS = {
  "cache-control": "private, no-cache",
  "x-content-type-options": "nosniff",
  "content-security-policy": "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox",
} as const;

/** Where a task's files are read from: each dir a real directory (not a symlink), listed paths prefixed. `owned` = the
 *  daemon made the directory (artifacts store, a work dir under workRoot), so the cwd rules do not apply to it. */
type Source = { readonly root: "store" | "artifacts" | "cwd"; readonly dirs: readonly { readonly prefix: string; readonly dir: string }[]; readonly owned: boolean; readonly since?: number; readonly until?: number };

const realDir = (p: string): boolean => { try { return lstatSync(p).isDirectory(); } catch { return false; } };
/** A hard link makes a file from anywhere look like one of the task's own. */
const singleLink = (p: string): boolean => { try { return lstatSync(p).nlink === 1; } catch { return false; } };
const isDir = (p: string): boolean => { try { return statSync(p).isDirectory(); } catch { return false; } };

function taskSource(deps: ApiDeps, task: Task): Source | null {
  const art = join(deps.artifactsDir, task.id);
  // `store`: the task's own two folders. (`artifacts`, the older name, is a kept copy of an `out/` alone: every file
  // of it is one handed back, which is how the apps read that word.)
  const own = [ATTACH_DIR, OUT_DIR].filter((name) => realDir(join(art, name)));
  if (own.length) return { root: "store", dirs: own.map((name) => ({ prefix: `${name}/`, dir: physicalPath(join(art, name)) })), owned: true };
  if (realDir(art)) return { root: "artifacts", dirs: [{ prefix: "", dir: physicalPath(art) }], owned: true };
  if (!isDir(task.cwd) || checkStoredCwd(task.cwd, deps.cwdRules, deps.workRoot)) return null;
  const cwd = physicalPath(task.cwd);
  const owned = isWorkDir(cwd, deps.workRoot);
  const dirs = [ATTACH_DIR, OUT_DIR].filter((name) => realDir(join(cwd, name))).map((name) => ({ prefix: `${name}/`, dir: join(cwd, name) }));
  // The folder's `out/` was every task's that worked there: a finished task shows what was written while it ran.
  return { root: "cwd", dirs, owned, since: task.createdAt - 1000, ...(TERMINAL.has(task.status) ? { until: task.updatedAt + LEGACY_SLACK_MS } : {}) };
}

/** A finished task's last write and its last update are not the same moment (the summary, the acceptance check). */
const LEGACY_SLACK_MS = 10 * 60_000;

function sourceFiles(src: Source): TreeEntry[] {
  return src.dirs.flatMap((d) => listTree(d.dir).filter((f) => singleLink(join(d.dir, f.path)))
    .filter((f) => d.prefix !== `${OUT_DIR}/` || src.since === undefined || (f.mtime >= src.since && (src.until === undefined || f.mtime <= src.until)))
    .map((f) => ({ ...f, path: d.prefix + f.path })));
}

/** The first line of what was asked, for a list of files by task. */
const titleOf = (task: Task): string => (task.task.split("\n").find((l) => l.trim()) ?? "").trim().slice(0, 120);

/** The real path of `rel` in the source, or null: outside in/ and out/, a directory, escaping through a symlink,
 *  hard-linked from elsewhere, or inside a denied root. */
function sourceFile(deps: ApiDeps, src: Source, rel: string): string | null {
  const d = src.dirs.find((x) => rel.startsWith(x.prefix));
  const file = d ? resolveInside(d.dir, rel.slice(d.prefix.length)) : null;
  if (!file) return null;
  let real: string;
  try { real = realpathSync.native(file); } catch { return null; }
  if (!singleLink(real)) return null;
  if (!src.owned && deniedRootOf(real, deps.cwdRules)) return null;
  return real;
}

/** The folders of the store, each a task's (its id the folder's name), with the task when it is still known. */
function keptTasks(deps: ApiDeps): { id: string; task: Task | undefined; mtime: number }[] {
  let names: string[] = [];
  try { names = readdirSync(deps.artifactsDir); } catch { return []; }
  return names.filter((n) => /^[A-Za-z0-9_-]+$/.test(n) && realDir(join(deps.artifactsDir, n)))
    .map((id) => ({ id, task: deps.store.getTask(id), mtime: statSync(join(deps.artifactsDir, id)).mtimeMs }));
}

export function mountFiles(app: Hono, deps: ApiDeps): void {
  app.post("/uploads", async (c) => {
    const form = await c.req.formData().catch(() => null);
    if (!form) return c.json({ error: "multipart form expected" }, 400);
    const entries = [...form.values()].filter((v): v is File => v instanceof File);
    if (!entries.length) return c.json({ error: "no files" }, 400);
    if (entries.length > MAX_FILES_PER_UPLOAD) return c.json({ error: `at most ${MAX_FILES_PER_UPLOAD} files per upload` }, 400);
    const big = entries.find((f) => f.size > MAX_FILE_BYTES);
    if (big) return c.json({ error: `${big.name} exceeds ${MAX_FILE_BYTES / 1024 / 1024} MB` }, 413);
    const files = [];
    for (const f of entries) files.push(deps.uploads.stage(f.name, Buffer.from(await f.arrayBuffer()), f.type));
    return c.json({ files });
  });

  app.get("/tasks/:id/files", (c) => {
    const task = deps.store.getTask(c.req.param("id"));
    if (!task) return c.json({ error: "not found" }, 404);
    const src = taskSource(deps, task);
    return c.json({ root: src?.root ?? null, files: src ? sourceFiles(src) : [] });
  });

  // Every task's files kept in the data directory, newest task first (Dispatch › Files): what each handed back and what
  // was attached to it, with how much room they take. Tasks from before, whose files are in their own folders, are not
  // here: nothing of theirs is AgentSwitch's to remove.
  app.get("/attachments", (c) => {
    const tasks = keptTasks(deps).map(({ task, id, mtime }) => {
      const src = task ? taskSource(deps, task) : null;
      const files = src && src.root !== "cwd" ? sourceFiles(src) : listTree(join(deps.artifactsDir, id));
      return { id, title: task ? titleOf(task) : "", createdAt: task?.createdAt ?? Math.round(mtime), known: !!task, files };
    }).filter((t) => t.files.length).sort((a, b) => b.createdAt - a.createdAt);
    return c.json({ tasks, bytes: tasks.reduce((n, t) => n + t.files.reduce((m, f) => m + f.size, 0), 0), keptDays: ARTIFACT_TTL_MS / 86_400_000 });
  });

  // One task's kept files, or everyone's. The tasks themselves stay; one still at work keeps its files.
  const removeKept = (ids: readonly string[]): { removed: number; busy: number } => {
    let removed = 0, busy = 0;
    for (const id of ids) {
      const task = deps.store.getTask(id);
      if (task && !TERMINAL.has(task.status)) { busy++; continue; }
      const dir = join(deps.artifactsDir, id);
      if (!/^[A-Za-z0-9_-]+$/.test(id) || !realDir(dir)) continue;
      rmSync(dir, { recursive: true, force: true });
      removed++;
    }
    return { removed, busy };
  };
  app.delete("/attachments", (c) => c.json(removeKept(keptTasks(deps).map((t) => t.id))));
  app.delete("/attachments/:id", (c) => {
    const id = c.req.param("id");
    if (!/^[A-Za-z0-9_-]+$/.test(id) || !realDir(join(deps.artifactsDir, id))) return c.json({ error: "not found" }, 404);
    const r = removeKept([id]);
    return r.busy ? c.json({ error: "任务还在进行，文件暂不能删除。" }, 409) : c.json(r);
  });

  app.get("/tasks/:id/files/*", (c) => {
    const task = deps.store.getTask(c.req.param("id"));
    const src = task ? taskSource(deps, task) : null;
    if (!src) return c.notFound();
    const marker = "/files/";
    let rel: string;
    try { rel = decodeURIComponent(c.req.path.slice(c.req.path.indexOf(marker) + marker.length)); } catch { return c.notFound(); }
    const file = sourceFile(deps, src, rel);
    if (!file) return c.notFound();
    const name = rel.split("/").pop() ?? "file";
    const disposition = `${isImage(name) ? "inline" : "attachment"}; filename*=UTF-8''${encodeURIComponent(name)}`;
    // Streamed: a deliverable may be hundreds of MB (a folder's archive), more than should sit in memory at once.
    const body = Readable.toWeb(createReadStream(file)) as ReadableStream<Uint8Array>;
    return c.body(body, 200, { ...DOWNLOAD_HEADERS, "content-type": contentType(name), "content-disposition": disposition, "content-length": String(statSync(file).size) });
  });
}
