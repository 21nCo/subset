// Replaces an installed Subset Mac app with the newest artifact of its channel (SET-231). install.mjs downloads,
// stages and verifies the new copy next to the old one, exactly as `subset install` does. Then, synchronously (no
// signal handler runs in between):
//   1. the installed <appName>.app is renamed to a hidden backup name in the same folder, and must still be the copy
//      that was checked (the same device and inode), otherwise it is renamed back and the update refused;
//   2. the verified copy is renamed to <appName>.app (if that fails, the backup is renamed back);
//   3. the receipt is rewritten;
//   4. the backup is renamed into the Trash (trash.mjs) when the Trash is on the same volume.
// On another volume the backup is copied to the Trash afterwards and then removed. So the old app or the new verified
// one is always there: a signal before step 1 leaves the old app untouched, and the steps cannot be split by one. Only
// a SIGKILL or a power loss between steps 1 and 2 can leave <appName>.app missing, and then both copies are still in
// the folder under hidden names.
//
// A running app is never replaced: runningProcesses() finds the processes whose executable is inside the bundle (from
// ps), and quitProcesses() sends them SIGTERM and waits for them to exit.
import { randomBytes } from 'node:crypto';
import { lstatSync, mkdirSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { setTimeout as sleep } from 'node:timers/promises';
import { INSTALL_TOOLS, InstallError, installApp } from './install.mjs';
import { moveToTrash, renameIntoTrash } from './trash.mjs';
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

/** The processes as `pid 123, 456`, for a message. */
export const pids = (processes) => `pid ${processes.map((entry) => entry.pid).join(', ')}`;

/**
 * Writes `receipt` ({ file, document() } or null) by renaming a temporary file over it. When it cannot be written, the
 * receipt there (now describing the replaced copy) is removed and `warn` says so: a receipt is advisory, and the
 * updated app stays.
 */
export function writeReceipt(receipt, warn) {
  if (!receipt) return;
  let temporary;
  try {
    mkdirSync(path.dirname(receipt.file), { recursive: true });
    temporary = `${receipt.file}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
    writeFileSync(temporary, `${JSON.stringify(receipt.document(), null, 2)}\n`, { mode: 0o644, flag: 'wx' });
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

const sameFile = (stat, identity) => stat.dev === identity.dev && stat.ino === identity.ino;

/**
 * Steps 1 to 4 above, synchronously, for the verified `staged` copy and the installed `target`, which must still be
 * `identity` ({ dev, ino }). Returns { backup, trashed }: `trashed` is the copy's path in the Trash, or undefined when
 * the backup could not be renamed there (it is then still at `backup`). Throws an InstallError leaving `target` as it
 * was and `staged` where it was.
 */
export function swapApp({ staged, target, identity, receipt, trash, appName, warn, now = new Date() }) {
  const backup = path.join(path.dirname(target), `.${path.basename(target)}.subset-update-${randomBytes(6).toString('hex')}`);
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
  try {
    renameSync(staged, target);
  } catch (error) {
    throw new InstallError('install', `the new copy cannot be renamed into place (${error.code ?? error.message})${putBack(backup, target)}`);
  }
  writeReceipt(receipt, warn);
  let trashed;
  try {
    trashed = renameIntoTrash(backup, { trash, appName, now });
  } catch {
    // Copied to the Trash, or reported, once the update has finished (updateApp).
  }
  return { backup, trashed };
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
    return { path: target, trashed: await moveToTrash(swapped.backup, { trash, appName: app.appName, now: now(), tools }) };
  } catch (error) {
    warn(`the previous copy could not be moved to the Trash (${error.message}); it is at ${swapped.backup}`);
    return { path: target, trashed: null };
  }
}

/** Opens the app by its bundle ID (`open -b`), after it was quit for an update. Resolves why it failed, or undefined. */
export async function reopenApp(bundleId, { tools = UPDATE_TOOLS } = {}) {
  const run = await runTool(tools.open, ['-b', bundleId]).catch((error) => ({ code: 1, stderr: error.message }));
  return run.code === 0 ? undefined : lastLine(run.stderr);
}
