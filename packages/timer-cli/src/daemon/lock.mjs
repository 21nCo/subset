import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
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
/** `ps` by its absolute path, so a directory earlier in PATH cannot replace it. */
const PS = '/bin/ps';
/** A file this module writes beside the lock and removes once done: `<lock or marker>.<pid>-<token>.new|.dead`. */
const LEFTOVER = /^(.+)\.(\d+)-[0-9a-f]{32}\.(?:new|dead)$/;

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
    unlinkQuietly(temp, fs);
  }
}

/**
 * The takeover marker `held` when it is abandoned: the process that wrote it is gone, or, for a
 * marker held this long, the pid now belongs to a process that started after it was written. A
 * live holder keeps its marker however long it is stopped, so no other process acts in its place.
 */
function abandonedMarker(marker, { isAlive, startTimeOf, now }) {
  const held = readLock(marker);
  if (!held) return null;
  // The marker sections of this process are synchronous, so a marker naming it is left over.
  if (held.pid === null || held.pid === process.pid || !isAlive(held.pid)) return held;
  if (now() - held.mtimeMs < MARKER_CHECK_AGE_MS) return null;
  const startedAt = startTimeOf(held.pid);
  return startedAt !== null && startedAt > held.mtimeMs + PID_START_SLACK_MS ? held : null;
}

/**
 * Removes the abandoned marker `held`. It is first renamed aside, so what is removed is what was
 * renamed: when another process has claimed a new marker since `held` was read, that marker is put
 * back rather than removed.
 */
function removeAbandonedMarker(marker, held, fs) {
  const aside = `${marker}.${process.pid}-${newToken()}.dead`;
  try {
    fs.renameSync(marker, aside);
  } catch (error) {
    if (isCode(error, 'ENOENT')) return;
    throw error;
  }
  try {
    if (readLock(aside)?.raw !== held.raw) fs.linkSync(aside, marker);
  } catch (error) {
    // A third process claimed the marker while it was aside; the one renamed sees it is no longer its own.
    if (!isCode(error, 'EEXIST')) throw error;
  } finally {
    unlinkQuietly(aside, fs);
  }
}

/**
 * Runs `remove(current)` holding the `.takeover` marker, itself created exclusively and naming this
 * process, so that checking the lock and removing it are one step among processes taking over or
 * releasing at once, and none of them removes a lock another has just created. Returns false when
 * another process holds the marker; one whose holder is gone is removed for the next attempt.
 */
function withTakeoverMarker(lockPath, remove, { isAlive = pidAlive, startTimeOf = processStartTime, now = Date.now, fs = nodeFs } = {}) {
  const marker = `${lockPath}.takeover`;
  const own = ownerContent(process.pid, newToken());
  if (!createExclusive(marker, own, process.pid, fs)) {
    const held = abandonedMarker(marker, { isAlive, startTimeOf, now });
    if (held) removeAbandonedMarker(marker, held, fs);
    return false;
  }
  const ownsMarker = () => readLock(marker)?.raw === own;
  try {
    const current = readLock(lockPath);
    if (current && remove(current) && ownsMarker()) unlinkQuietly(lockPath, fs);
    return true;
  } finally {
    if (ownsMarker()) unlinkQuietly(marker, fs);
  }
}

/**
 * Removes `held`, the lock file seen earlier, if the lock still holds the same content, which names
 * one acquisition. Returns false when another process is mid-takeover.
 */
export function removeStaleLock(lockPath, held, options = {}) {
  return withTakeoverMarker(lockPath, (current) => current.raw === held.raw, options);
}

/** Removes files a process that crashed mid-write or mid-takeover left beside the lock. */
function removeLeftovers(lockPath, { isAlive, fs }) {
  const directory = dirname(lockPath);
  const names = new Set([basename(lockPath), `${basename(lockPath)}.takeover`]);
  for (const name of readdirSync(directory)) {
    const match = LEFTOVER.exec(name);
    if (match && names.has(match[1]) && !isAlive(Number(match[2]))) unlinkQuietly(join(directory, name), fs);
  }
}

/**
 * Takes `daemon.lock`, created exclusively and holding the pid and a token of this acquisition. A
 * lock whose pid is not alive, or that holds no valid pid, is stale and replaced. Resolves
 * `{ acquired: true, token, release, isHeld }` or `{ acquired: false, holder }` naming the live
 * holder. `fs` replaces the calls that create, write and remove files, for tests.
 */
export async function acquireLock(lockPath, { pid = process.pid, isAlive = pidAlive, startTimeOf = processStartTime, now = Date.now, fs = nodeFs } = {}) {
  const token = newToken();
  const options = { isAlive, startTimeOf, now, fs };
  const attempt = async (remaining, holder) => {
    if (remaining === 0) return { acquired: false, holder };
    if (createExclusive(lockPath, ownerContent(pid, token), pid, fs)) {
      removeLeftovers(lockPath, options);
      return { acquired: true, token, release: () => releaseLock(lockPath, token, options), isHeld: () => holdsLock(lockPath, token) };
    }
    const current = readLock(lockPath);
    if (current?.pid && isAlive(current.pid)) return { acquired: false, holder: current };
    // Gone already, or stale and removed: try again at once. Otherwise another process is mid-takeover.
    if (current && !removeStaleLock(lockPath, current, options)) await sleep(RETRY_MS);
    return attempt(remaining - 1, current);
  };
  return attempt(ATTEMPTS, null);
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
  withTakeoverMarker(lockPath, (current) => current.token === token, options);
}
