import { execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import * as nodeFs from 'node:fs';
import { closeSync, fstatSync, openSync, readdirSync, readFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { writeAll } from './store.mjs';

/** A takeover marker held this long by a live pid is checked for a pid the system gave to another process. */
const MARKER_CHECK_AGE_MS = 10_000;
/** How much later than its marker a live holder must have started to be another process given the pid. */
const PID_START_SLACK_MS = 2_000;
const ATTEMPTS = 50;
const RETRY_MS = 20;
/** How often one removal claims a marker after removing an abandoned one. */
const MARKER_TRIES = 3;
/** `ps` by its absolute path, so a directory earlier in PATH cannot replace it. */
const PS = '/bin/ps';
/** A file this module writes beside the lock and removes once done: `<lock or marker>.<pid>-<token>.new`. */
const LEFTOVER = /^(.+)\.(\d+)-[0-9a-f]{32}\.new$/;
/**
 * What follows the lock's name in a marker's: `.takeover.<generation>`. Every marker, including one
 * for removing an abandoned marker, sits beside the lock under this one bounded name.
 */
const MARKER = /^\.takeover\.([0-9a-f]{32})$/;

/** True when a process with this pid exists, including one owned by another user. */
export function pidAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

const elapsedTimeOf = (pid) => execFileSync(PS, ['-o', 'etime=', '-p', String(pid)], { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' }, stdio: ['ignore', 'pipe', 'ignore'], timeout: 2_000 });

/**
 * The earliest the process with this pid can have started, in epoch milliseconds, or null when it
 * cannot be told. `ps -o etime` reports the elapsed time, floored to the second, on macOS and Linux
 * alike. The clock is read before `ps` runs and the rounding is subtracted, so however slow `ps` is
 * the result is never later than the real start: a takeover needs proof, not a late estimate.
 */
export function processStartTime(pid, { now = Date.now, elapsedOf = elapsedTimeOf } = {}) {
  const before = now();
  let output;
  try {
    output = elapsedOf(pid);
  } catch {
    return null;
  }
  // [[dd-]hh:]mm:ss
  const match = /^\s*(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)\s*$/.exec(output);
  if (!match) return null;
  const [days, hours, minutes, seconds] = match.slice(1).map((part) => Number(part ?? 0));
  return before - ((((days * 24 + hours) * 60 + minutes) * 60 + seconds) * 1_000 + 1_000);
}

function isCode(error, ...codes) {
  return error && codes.includes(error.code);
}

const newToken = () => randomBytes(16).toString('hex');

/** What a holder writes: its pid, and a token no other acquisition has, so its file is told apart from any later one. */
const ownerContent = (pid, token) => `${pid}\n${token}\n`;

/**
 * The holder of the lock (or of a takeover marker), or null when there is no such file. `raw` is
 * the whole content, unique to one acquisition; `pid` is null when the file holds no valid pid.
 */
export function readLock(lockPath) {
  let fd;
  try {
    fd = openSync(lockPath, 'r');
  } catch (error) {
    if (isCode(error, 'ENOENT')) return null;
    throw error;
  }
  // Read the content and the time from one open file, so both describe the same lock.
  let raw;
  let stat;
  try {
    stat = fstatSync(fd);
    raw = readFileSync(fd, 'utf8');
  } finally {
    closeSync(fd);
  }
  const match = /^(\d+)\n(?:([0-9a-f]{32})\n)?$/.exec(raw);
  const pid = match ? Number(match[1]) : null;
  return { pid: Number.isSafeInteger(pid) && pid > 0 ? pid : null, token: match?.[2] ?? null, raw, mtimeMs: stat.mtimeMs };
}

function unlinkQuietly(path, fs = nodeFs) {
  try {
    fs.unlinkSync(path);
  } catch (error) {
    if (!isCode(error, 'ENOENT')) throw error;
  }
}

/** Cleanup that never hides the error being handled; a file left behind is removed by the next daemon. */
function unlinkBestEffort(path, fs) {
  try {
    fs.unlinkSync(path);
  } catch {
    // Left for removeLeftovers, once this pid is gone.
  }
}

/**
 * Creates `path` holding `content`, whole from the moment it exists: the content is written and
 * fsynced to a file of its own, which is then hard-linked to `path`. Returns false when `path`
 * exists. Nobody ever sees the file empty or half written.
 */
function createExclusive(path, content, pid, fs) {
  const temp = `${path}.${pid}-${newToken()}.new`;
  try {
    const fd = fs.openSync(temp, 'wx', 0o600);
    try {
      writeAll(fs, fd, Buffer.from(content));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.linkSync(temp, path);
    return true;
  } catch (error) {
    if (isCode(error, 'EEXIST')) return false;
    throw error;
  } finally {
    unlinkBestEffort(temp, fs);
  }
}

/** The generation of a lock or marker file: its token, or a digest of its content when it holds none. */
const generationOf = (held) => held.token ?? createHash('sha256').update(held.raw).digest('hex').slice(0, 32);

/**
 * A marker naming a process that is gone is abandoned, and so, once it is this old, is one whose
 * pid now belongs to a process that started after it was written. A live holder keeps its marker
 * however long it is stopped, so no other process acts in its place.
 */
function isAbandoned(held, { isAlive, startTimeOf, now }) {
  // The marker sections of this process are synchronous, so a marker naming it is left over.
  if (held.pid === null || held.pid === process.pid || !isAlive(held.pid)) return true;
  if (now() - held.mtimeMs < MARKER_CHECK_AGE_MS) return false;
  const startedAt = startTimeOf(held.pid);
  return startedAt !== null && startedAt > held.mtimeMs + PID_START_SLACK_MS;
}

const markerOf = (lockPath, gen) => `${lockPath}.takeover.${gen}`;

/**
 * Removes `path` (the lock, or a marker) while it still holds generation `gen`. The removal is done
 * holding `<lock>.takeover.<gen>`, created exclusively and naming this process. Generations are
 * never reused, and `path` only stops holding `gen` when the holder of that marker removes it, so
 * the holder's check and removal are one step: no other process can remove or replace `path` in
 * between, whatever it saw earlier. An abandoned marker is removed the same way, under the marker
 * of its own generation, beside the lock like every other: names stay the same length however
 * many holders died removing abandoned markers, and the whole chain is followed. `seen` holds the
 * generations on the chain, which only a corrupt marker could repeat. Returns `removed`, `gone`
 * (`path` no longer holds `gen`) or `busy` (a live process holds the marker).
 */
function removeGeneration(path, gen, context, seen = new Set()) {
  const marker = markerOf(context.lockPath, gen);
  seen.add(gen);
  for (let tries = 0; tries < MARKER_TRIES; tries++) {
    if (createExclusive(marker, ownerContent(context.pid, newToken()), context.pid, context.fs)) {
      try {
        const current = readLock(path);
        if (!current || generationOf(current) !== gen) return 'gone';
        unlinkQuietly(path, context.fs);
        return 'removed';
      } finally {
        // Once `path` no longer holds `gen` it never will again, so every marker for `gen` is inert
        // and this one can go whoever holds it. While it still holds `gen`, only this process can.
        unlinkQuietly(marker, context.fs);
      }
    }
    const held = readLock(marker);
    if (!held) continue;
    const next = generationOf(held);
    if (seen.has(next) || !isAbandoned(held, context)) return 'busy';
    if (removeGeneration(marker, next, context, seen) === 'busy') return 'busy';
  }
  return 'busy';
}

const contextOf = (lockPath, { pid = process.pid, isAlive = pidAlive, startTimeOf = processStartTime, now = Date.now, fs = nodeFs } = {}) => ({ lockPath, pid, isAlive, startTimeOf, now, fs });

/**
 * Removes `held`, the lock file seen earlier, if the lock still holds the same acquisition. Returns
 * false when another process is removing it.
 */
export function removeStaleLock(lockPath, held, options = {}) {
  return removeGeneration(lockPath, generationOf(held), contextOf(lockPath, options)) !== 'busy';
}

/**
 * Removes files left beside the lock by processes that crashed: a `.new` file of a pid that is gone,
 * and a marker for a generation that neither the lock nor any marker holds, which nobody acts on
 * again: generations are never reused, so no file will hold it later.
 */
function removeLeftovers(lockPath, { isAlive, fs }) {
  const directory = dirname(lockPath);
  const lockName = basename(lockPath);
  const generationIn = (name) => (name.startsWith(lockName) ? MARKER.exec(name.slice(lockName.length))?.[1] : undefined);
  const markers = new Map();
  for (const name of readdirSync(directory)) {
    const leftover = LEFTOVER.exec(name);
    if (leftover) {
      if ((leftover[1] === lockName || generationIn(leftover[1])) && !isAlive(Number(leftover[2]))) unlinkQuietly(join(directory, name), fs);
    } else if (generationIn(name)) {
      markers.set(generationIn(name), join(directory, name));
    }
  }
  // Removing a marker leaves the marker for its own removal inert, so repeat until none is.
  for (let removed = true; removed; ) {
    const held = new Set([lockPath, ...markers.values()].map(readLock).filter(Boolean).map(generationOf));
    removed = false;
    for (const [gen, path] of markers) {
      if (held.has(gen)) continue;
      unlinkQuietly(path, fs);
      markers.delete(gen);
      removed = true;
    }
  }
}

/**
 * Takes `daemon.lock`, created exclusively and holding the pid and a token of this acquisition. A
 * lock whose pid is not alive, or that holds no valid pid, is stale and replaced. Resolves
 * `{ acquired: true, token, release, isHeld }`, or `{ acquired: false, holder }` naming the live
 * holder (null when another process kept removing a stale lock). `fs` replaces the calls that
 * create, write and remove files, for tests.
 */
export async function acquireLock(lockPath, options = {}) {
  const context = contextOf(lockPath, options);
  const token = newToken();
  for (let tries = 1; ; tries++) {
    if (createExclusive(lockPath, ownerContent(context.pid, token), context.pid, context.fs)) {
      removeLeftovers(lockPath, context);
      return { acquired: true, token, release: () => releaseLock(lockPath, token, options), isHeld: () => holdsLock(lockPath, token) };
    }
    const current = readLock(lockPath);
    if (current?.pid && context.isAlive(current.pid)) return { acquired: false, holder: current };
    // Gone already, or stale and removed: create it at once. Otherwise another process is removing it.
    if (!current || removeGeneration(lockPath, generationOf(current), context) !== 'busy') continue;
    if (tries >= ATTEMPTS) return { acquired: false, holder: null };
    await sleep(RETRY_MS);
  }
}

/** True while `daemon.lock` is still the file of the acquisition with this token. */
export function holdsLock(lockPath, token) {
  return readLock(lockPath)?.token === token;
}

/**
 * Removes the lock only while it is still the file of this acquisition. During another process's
 * takeover it is left, naming a pid that is about to exit, which the next daemon replaces.
 */
export function releaseLock(lockPath, token, options = {}) {
  removeGeneration(lockPath, token, contextOf(lockPath, options));
}
