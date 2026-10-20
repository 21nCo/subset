import { execFileSync } from 'node:child_process';
import { closeSync, fstatSync, fsyncSync, openSync, readFileSync, statSync, unlinkSync, writeSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';

/** A lock with no pid yet is being written by the daemon that created it, unless it is older than this. */
export const LOCK_WRITE_GRACE_MS = 2_000;
/** A takeover marker left by a process that crashed mid-takeover is removed after this. */
const TAKEOVER_STALE_MS = 10_000;
const ATTEMPTS = 50;
const RETRY_MS = 20;

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

const elapsedTimeOf = (pid) => execFileSync('ps', ['-o', 'etime=', '-p', String(pid)], { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' }, stdio: ['ignore', 'pipe', 'ignore'], timeout: 2_000 });

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
  const [, days = 0, hours = 0, minutes, seconds] = match.map((part) => (part === undefined ? undefined : Number(part)));
  return before - ((((days * 24 + hours) * 60 + minutes) * 60 + seconds) * 1_000 + 1_000);
}

function isCode(error, ...codes) {
  return error && codes.includes(error.code);
}

/** The lock's holder, or null when there is no lock file. `pid` is null when the file holds no valid pid. */
export function readLock(lockPath) {
  let fd;
  try {
    fd = openSync(lockPath, 'r');
  } catch (error) {
    if (isCode(error, 'ENOENT')) return null;
    throw error;
  }
  // Read the content and the inode from one open file, so both describe the same lock.
  let raw;
  let stat;
  try {
    stat = fstatSync(fd);
    raw = readFileSync(fd, 'utf8');
  } finally {
    closeSync(fd);
  }
  const pid = /^\d+\n?$/.test(raw) ? Number(raw.trim()) : null;
  return { pid: Number.isSafeInteger(pid) && pid > 0 ? pid : null, raw, ino: stat.ino, mtimeMs: stat.mtimeMs };
}

function createLock(lockPath, pid) {
  const fd = openSync(lockPath, 'wx', 0o600);
  try {
    writeSync(fd, `${pid}\n`);
    fsyncSync(fd);
    return fstatSync(fd).ino;
  } finally {
    closeSync(fd);
  }
}

/**
 * Removes `held`, the lock file seen earlier, if it is still the same file with the same content.
 * A `.takeover` marker, itself created exclusively, makes the check and the removal one step among
 * processes taking over at once, so none of them removes a lock another has just created.
 * Returns false when another process is mid-takeover.
 */
export function removeStaleLock(lockPath, held, { now = Date.now } = {}) {
  const marker = `${lockPath}.takeover`;
  try {
    closeSync(openSync(marker, 'wx', 0o600));
  } catch (error) {
    if (!isCode(error, 'EEXIST')) throw error;
    try {
      if (now() - statSync(marker).mtimeMs > TAKEOVER_STALE_MS) unlinkSync(marker);
    } catch (statError) {
      if (!isCode(statError, 'ENOENT')) throw statError;
    }
    return false;
  }
  try {
    const current = readLock(lockPath);
    if (current && current.ino === held.ino && current.raw === held.raw) unlinkSync(lockPath);
    return true;
  } finally {
    unlinkSync(marker);
  }
}

/**
 * Takes `daemon.lock`, created with O_EXCL and holding the pid. A lock whose pid is not alive, or
 * that has held no pid for longer than `LOCK_WRITE_GRACE_MS`, is stale and replaced. Resolves
 * `{ acquired: true, release, isHeld }` or `{ acquired: false, holder }` naming the live holder.
 */
export async function acquireLock(lockPath, { pid = process.pid, isAlive = pidAlive, now = Date.now } = {}) {
  let holder = null;
  for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
    try {
      const ino = createLock(lockPath, pid);
      return { acquired: true, ino, release: () => releaseLock(lockPath, pid, ino), isHeld: () => holdsLock(lockPath, pid, ino) };
    } catch (error) {
      if (!isCode(error, 'EEXIST')) throw error;
    }
    holder = readLock(lockPath);
    if (!holder) continue;
    if (holder.pid !== null && isAlive(holder.pid)) return { acquired: false, holder };
    // A lock created this instant has no pid yet; give its writer a moment before calling it stale.
    const stale = holder.pid !== null || now() - holder.mtimeMs > LOCK_WRITE_GRACE_MS;
    if (stale && removeStaleLock(lockPath, holder, { now })) continue;
    await sleep(RETRY_MS);
  }
  return { acquired: false, holder };
}

/** True while `daemon.lock` is still the file this holder created. */
export function holdsLock(lockPath, pid, ino) {
  const current = readLock(lockPath);
  return Boolean(current && current.ino === ino && current.pid === pid);
}

/** Removes the lock only while it is still the file this process created. */
export function releaseLock(lockPath, pid, ino) {
  if (holdsLock(lockPath, pid, ino)) {
    try {
      unlinkSync(lockPath);
    } catch (error) {
      if (!isCode(error, 'ENOENT')) throw error;
    }
  }
}
