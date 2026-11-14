// Replaces an installed Subset Mac app with the newest artifact of its channel (SET-231). install.mjs downloads,
// stages and verifies the new copy next to the old one, exactly as `subset install` does. Then, synchronously (no
// signal handler runs in between):
//   1. the installed <appName>.app is renamed to a hidden backup name in the same folder, and must still be the copy
//      that was checked (the same device and inode), otherwise it is renamed back and the update refused;
//   2. the verified copy is renamed to <appName>.app (if that fails, the backup is renamed back);
//   3. the backup, now a replaced copy, is renamed to a hidden `old` name (trash.mjs hiddenName()), which is never put
//      back;
//   4. the receipt is rewritten, when the new copy is still at <appName>.app;
//   5. the old copy is renamed into the Trash (trash.mjs) when the Trash is on the same volume.
// On another volume the old copy is copied to the Trash afterwards and then removed. So the old app or the new verified
// one is always there: a signal before step 1 leaves the old app untouched, and the steps cannot be split by one. Only
// a SIGKILL or a power loss between steps 1 and 2 can leave <appName>.app missing, and then both copies are still in
// the folder under hidden names; recoverApps(), which the next subset install, update or uninstall runs first, renames
// the backup back. A copy that is no longer the installed one (an `old` copy that could not reach the Trash, or one
// left between steps 2 and 3) is never put back, so a later uninstall followed by an install cannot revive it.
//
// A running app is never replaced: runningProcesses() finds the processes whose executable is inside the bundle (from
// ps), and quitProcesses() sends them SIGTERM and waits for them to exit. The commands hold the app's lock (lock.mjs)
// throughout, so no other subset install, update or uninstall of the app runs meanwhile.
import { randomBytes } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { setTimeout as sleep } from 'node:timers/promises';
import { INSTALL_TOOLS, InstallError, installApp } from './install.mjs';
import { alive } from './lock.mjs';
import { hiddenName, moveToTrash, renameIntoTrash } from './trash.mjs';
import { compareNumbers, compareVersions, runTool } from './verify.mjs';

export const UPDATE_TOOLS = Object.freeze({ ...INSTALL_TOOLS, ps: '/bin/ps', open: '/usr/bin/open' });
export const QUIT_TIMEOUT_MS = 10_000;
const QUIT_POLL_MS = 200;
const VERSION = /^\d+\.\d+\.\d+$/;
const BUILD = /^\d+$/;

/** The app is running, or whether it is cannot be told: it is not replaced or moved. */
export class RunningError extends InstallError {
  constructor(message) {
    super('running', message);
  }
}

/**
 * What updating one installed copy ({ version, build, channel } from detectApps) to the channel would do, with
 * `release` the channel's feed entry:
 *   { action: 'update', release }   the channel's version is newer, or (same version) the copy is a beta per its receipt
 *                                   and the live release is asked for, or (--beta, same version) a beta with a newer build
 *   { action: 'current', release }  the same version (a copy without a receipt is current at an equal version)
 *   { action: 'ahead', release }    the copy is newer than the channel: updating would be a downgrade
 *   { action: 'unknown', release }  the copy's version is not x.y.z, so it cannot be compared
 *   { action: 'no-release' }        the feed has no such channel for the app
 */
export function decideUpdate(copy, app, beta) {
  const release = beta ? app.channels.beta : app.channels.live;
  if (!release) return { action: 'no-release' };
  if (typeof copy.version !== 'string' || !VERSION.test(copy.version)) return { action: 'unknown', release };
  const order = compareVersions(release.version, copy.version);
  if (order !== 0) return { action: order > 0 ? 'update' : 'ahead', release };
  if (!beta) return { action: copy.channel === 'beta' ? 'update' : 'current', release };
  // --beta at the same version: only a beta (by its receipt) compares builds; the live release of a version is not
  // older than its betas.
  if (copy.channel !== 'beta' || !BUILD.test(copy.build ?? '')) return { action: 'current', release };
  const builds = compareNumbers(String(release.build), copy.build);
  return { action: builds > 0 ? 'update' : builds < 0 ? 'ahead' : 'current', release };
}

const lastLine = (text) => text.trim().split('\n').at(-1)?.trim() || 'no output';

/**
 * The processes whose executable is inside `bundle` (its path as given or its real path), from `ps -axww -o pid=,comm=`,
 * which prints each process's executable path: [{ pid, executable }]. Rejects with a RunningError when ps fails, since
 * whether the app runs is then unknown.
 */
export async function runningProcesses(bundle, { tools = UPDATE_TOOLS, signal } = {}) {
  const roots = new Set([bundle]);
  try {
    roots.add(realpathSync(bundle));
  } catch {
    // A bundle that is gone has no real path; its path as given is still matched.
  }
  const ps = await runTool(tools.ps, ['-axww', '-o', 'pid=,comm='], { signal });
  if (ps.code !== 0) throw new RunningError(`whether ${bundle} is running cannot be told (ps: ${lastLine(ps.stderr)})`);
  const found = [];
  for (const line of ps.stdout.split('\n')) {
    const match = /^\s*(\d+)\s(.+)$/.exec(line);
    if (!match) continue;
    const pid = Number(match[1]);
    const executable = match[2].trim();
    if (pid !== process.pid && [...roots].some((root) => executable.startsWith(`${root}/`))) found.push({ pid, executable });
  }
  return found;
}

/**
 * Sends SIGTERM to each of `processes` and waits up to `timeoutMs` for every process inside `bundle` to exit. Resolves
 * the processes still running then ([] when none).
 */
export async function quitProcesses(bundle, processes, { tools = UPDATE_TOOLS, timeoutMs = QUIT_TIMEOUT_MS, signal } = {}) {
  for (const { pid } of processes) {
    try {
      process.kill(pid, 'SIGTERM');
    } catch {
      // It has exited already, or belongs to another user (it then stays, and is reported below).
    }
  }
  const until = Date.now() + timeoutMs;
  for (;;) {
    const left = await runningProcesses(bundle, { tools, signal });
    if (left.length === 0 || Date.now() >= until) return left;
    await sleep(QUIT_POLL_MS, undefined, { signal });
  }
}

const sameFile = (stat, identity) => stat.dev === identity.dev && stat.ino === identity.ino;

/** The processes as `pid 123, 456`, for a message. */
export const pids = (processes) => `pid ${processes.map((entry) => entry.pid).join(', ')}`;

/**
 * Writes `receipt` ({ file, document() } or null) for the copy at `target` by renaming a temporary file over it, only
 * while that copy is still `identity` ({ dev, ino }); otherwise `warn` says it was not written. When it cannot be
 * written, the receipt there (now describing the replaced copy) is removed and `warn` says so: a receipt is advisory,
 * and the updated app stays.
 */
export function writeReceipt(receipt, warn, { target, identity }) {
  if (!receipt) return;
  let temporary;
  try {
    mkdirSync(path.dirname(receipt.file), { recursive: true });
    // Named apart from the bundle ID, so it fits whenever the receipt's own name does.
    temporary = path.join(path.dirname(receipt.file), `.receipt.${process.pid}.${randomBytes(4).toString('hex')}.tmp`);
    writeFileSync(temporary, `${JSON.stringify(receipt.document(), null, 2)}\n`, { mode: 0o644, flag: 'wx' });
    let current;
    try {
      current = lstatSync(target);
    } catch {
      current = undefined;
    }
    if (!current || !sameFile(current, identity)) {
      rmSync(temporary, { force: true });
      warn(`the receipt ${receipt.file} was not written: ${target} was replaced or removed after the update`);
      return;
    }
    renameSync(temporary, receipt.file);
  } catch (error) {
    try {
      if (temporary !== undefined) rmSync(temporary, { force: true });
      rmSync(receipt.file, { force: true });
    } catch {
      // Nothing more can be done about it.
    }
    warn(`the receipt ${receipt.file} cannot be written (${error.code ?? error.message}); the app is updated without one`);
  }
}

// Renames `from` back to `to` after a failed step; resolves the message to add when that fails too.
function putBack(from, to) {
  try {
    renameSync(from, to);
    return '';
  } catch (error) {
    return `, and the previous copy could not be put back (${error.code ?? error.message}): it is at ${from}; rename it to ${to}`;
  }
}

/**
 * Steps 1 to 5 above, synchronously, for the verified `staged` copy and the installed `target`, which must still be
 * `identity` ({ dev, ino }). Returns { old, trashed }: `trashed` is the replaced copy's path in the Trash, or undefined
 * when it could not be renamed there (it is then still at `old`, its hidden name). Throws an InstallError leaving
 * `target` as it was and `staged` where it was.
 */
export function swapApp({ staged, target, identity, receipt, trash, appName, warn, now = new Date() }) {
  const backup = hiddenName(path.dirname(target), appName, 'update');
  const changed = `${target} was changed or removed while it was being updated (by another subset install, update or uninstall?)`;
  try {
    renameSync(target, backup);
  } catch (error) {
    if (error.code === 'ENOENT') throw new InstallError('install', changed);
    throw new InstallError('install', `${target} cannot be moved aside (${error.code ?? error.message})`);
  }
  let moved;
  try {
    moved = lstatSync(backup);
  } catch {
    moved = undefined;
  }
  if (!moved || !sameFile(moved, identity)) throw new InstallError('install', `${changed}${putBack(backup, target)}`);
  let placed;
  try {
    placed = lstatSync(staged);
    renameSync(staged, target);
  } catch (error) {
    throw new InstallError('install', `the new copy cannot be renamed into place (${error.code ?? error.message})${putBack(backup, target)}`);
  }
  // The backup is no longer the installed copy: renamed out of the names recoverApps() puts back. If even that fails,
  // the next subset install, update or uninstall renames it (it finds <appName>.app in place).
  let old = hiddenName(path.dirname(target), appName, 'old');
  try {
    renameSync(backup, old);
  } catch {
    old = backup;
  }
  writeReceipt(receipt, warn, { target, identity: placed });
  let trashed;
  try {
    trashed = renameIntoTrash(old, { trash, appName, now });
  } catch {
    // Copied to the Trash, or reported, once the update has finished (updateApp).
  }
  return { old, trashed };
}

/**
 * Updates the installed copy at `target` (still `identity`, { dev, ino }) to `release` of `app`: install.mjs stages and
 * verifies the new copy beside it, `ready()` runs (the caller's running-app check), and swapApp() puts it in place and
 * moves the old copy to the Trash `trash`. `receipt` is { file, document() } or null. `signal` aborts the update before
 * the swap, leaving the installed copy untouched. Resolves { path, trashed }, with `trashed` the old copy's path in the
 * Trash, or null when it could not be moved there (`warn` then names where it is).
 */
export async function updateApp({ app, release, beta, target, identity, receipt, trash, signal, fetch = globalThis.fetch, tools = UPDATE_TOOLS, log = () => {}, warn = () => {}, ready, now = () => new Date() }) {
  let swapped;
  await installApp({
    app,
    release,
    beta,
    dir: path.dirname(target),
    receipt: null,
    signal,
    fetch,
    tools,
    log,
    warn,
    ready,
    commit: (staged) => {
      swapped = swapApp({ staged, target, identity, receipt, trash, appName: app.appName, warn, now: now() });
    }
  });
  if (swapped.trashed) return { path: target, trashed: swapped.trashed };
  // The Trash is on another volume (or the rename failed): the copy is made now, and is not interrupted.
  try {
    return { path: target, trashed: await moveToTrash(swapped.old, { trash, appName: app.appName, now: now(), tools, setAside: false }) };
  } catch (error) {
    warn(`the previous copy could not be moved to the Trash (${error.message}); it is at ${error.left ?? swapped.old}`);
    return { path: target, trashed: null };
  }
}

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * Looks, for each app of `apps` in each of `folders`, at the copies a subset update or uninstall set aside beside
 * `<appName>.app` under a hidden name (trash.mjs hiddenName()) and left there: what a SIGKILL or a power loss between
 * two renames, or a copy that could not reach the Trash, leaves. Copies whose subset (their pid) still runs are left
 * alone. Of the others:
 *   - `update` and `trash` copies are the installed copy of an update or uninstall that did not finish. When
 *     `<appName>.app` is missing and there is exactly one, it is renamed back to `<appName>.app`. When `<appName>.app`
 *     is there, they are no longer the installed copy: they are renamed to `old` names, as the update or uninstall
 *     would have done.
 *   - `old` copies were replaced by an update or already copied to the Trash (and may be partly removed): they are
 *     never put back, only named.
 * With `restore` false (subset list) nothing is renamed. A staged copy (`.subset-install-*`) is never touched: it may
 * not have been verified. Returns a note for each app put back, missing, or with copies left beside it.
 */
export function recoverApps(apps, folders, { restore = true, running = alive } = {}) {
  const notes = [];
  for (const app of apps) {
    const pattern = new RegExp(`^\\.${escapeRegExp(app.appName)}\\.app\\.subset-(update|trash|old)-(\\d+)-[0-9a-f]{12}$`);
    for (const folder of folders) {
      let names;
      try {
        names = readdirSync(folder.dir);
      } catch {
        continue;
      }
      const target = path.join(folder.dir, `${app.appName}.app`);
      const found = names.flatMap((name) => {
        const match = pattern.exec(name);
        return match ? [{ file: path.join(folder.dir, name), kind: match[1], pid: Number(match[2]) }] : [];
      });
      if (found.length === 0) continue;
      let present = true;
      try {
        if (!lstatSync(target).isDirectory()) {
          // Not an app folder (a link or a file): nothing is put back over it or renamed beside it, only named.
          notes.push(`${target} is not an app folder, and an interrupted subset update or uninstall left copies of ${app.name} beside it at ${found.map((entry) => entry.file).join(', ')}.`);
          continue;
        }
      } catch {
        present = false;
      }
      const busy = found.find((entry) => entry.pid !== process.pid && running(entry.pid));
      const unfinished = found.filter((entry) => entry.kind !== 'old');
      if (!present && unfinished.length > 0) {
        const where = unfinished.map((entry) => entry.file).join(', ');
        let why;
        if (busy) why = `subset (pid ${busy.pid}) is still updating or uninstalling it`;
        else if (unfinished.length > 1) why = `rename the copy to keep to ${target}`;
        else if (!restore) why = `subset update ${app.id} puts it back`;
        else {
          try {
            if (!lstatSync(unfinished[0].file).isDirectory()) throw Object.assign(new Error('not a folder'), { code: 'ENOTDIR' });
            renameSync(unfinished[0].file, target);
            notes.push(`${app.name} was put back at ${target}: an interrupted subset update or uninstall had left it at ${unfinished[0].file}.`);
            present = true;
          } catch (error) {
            why = `it could not be renamed back (${error.code ?? error.message}); rename it to ${target}`;
          }
        }
        if (!present) {
          notes.push(`${app.name} is missing from ${folder.label}, and an interrupted subset update or uninstall left it at ${where}; ${why}.`);
          continue;
        }
      }
      if (busy) continue;
      // <appName>.app is in place: every copy left beside it is an old one.
      const left = found.filter((entry) => existsSync(entry.file)).map((entry) => {
        if (entry.kind === 'old' || !restore) return entry.file;
        const old = hiddenName(folder.dir, app.appName, 'old');
        try {
          renameSync(entry.file, old);
          return old;
        } catch {
          return entry.file;
        }
      });
      if (left.length > 0) notes.push(`a previous copy of ${app.name} that subset did not move to the Trash is at ${left.join(', ')}; it is not used any more and can be moved to the Trash.`);
    }
  }
  return notes;
}

/** Opens the app by its bundle ID (`open -b`), after it was quit for an update. Resolves why it failed, or undefined. */
export async function reopenApp(bundleId, { tools = UPDATE_TOOLS } = {}) {
  const run = await runTool(tools.open, ['-b', bundleId]).catch((error) => ({ code: 1, stderr: error.message }));
  return run.code === 0 ? undefined : lastLine(run.stderr);
}
