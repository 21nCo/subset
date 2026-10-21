import { execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import * as nodeFs from 'node:fs';
import { closeSync, openSync, readdirSync, readFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { writeAll } from './store.mjs';

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
/** A process birth as written in a lock or marker. */
const BIRTH = /^[!-~]{1,128}$/;

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

const startOf = (pid) => execFileSync(PS, ['-o', 'lstart=', '-p', String(pid)], { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C', TZ: 'UTC0' }, stdio: ['ignore', 'pipe', 'ignore'], timeout: 2_000 });

/**
 * The birth of the process with this pid: a string that stays the same for the life of that
 * process, whatever the wall clock does, and that a process later given the pid does not share.
 * Null when it cannot be told. On Linux it is the boot id and the start time in clock ticks since
 * boot (`/proc/<pid>/stat` field 22); elsewhere the start time `ps -o lstart` reports, which the
 * kernel records once at fork (to the second, in UTC).
 */
export function processBirth(pid, { platform = process.platform, readFile = readFileSync, lstartOf = startOf } = {}) {
  try {
    if (platform === 'linux') {
      const stat = readFile(`/proc/${pid}/stat`, 'utf8');
      // The command name in parentheses can hold spaces; field 22 is the 20th after it.
      const starttime = stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19];
      const bootId = readFile('/proc/sys/kernel/random/boot_id', 'utf8').trim();
      return /^\d+$/.test(starttime) && /^[0-9a-f-]{1,64}$/.test(bootId) ? `linux-${bootId}-${starttime}` : null;
    }
    const birth = `ps-${lstartOf(pid).trim().replaceAll(/\s+/g, '_')}`;
    return birth !== 'ps-' && BIRTH.test(birth) ? birth : null;
  } catch {
    return null;
  }
}

let ownBirth;
/** This process's birth, read once. */
const birthOfSelf = () => {
  ownBirth ??= { value: processBirth(process.pid) };
  return ownBirth.value;
};

function isCode(error, ...codes) {
  return error && codes.includes(error.code);
}

const newToken = () => randomBytes(16).toString('hex');

/**
 * What a holder writes: its pid, a token no other acquisition has, so its file is told apart from
 * any later one, and its birth when it can be told, so a process later given the pid is told apart
 * from it.
 */
const ownerContent = (context, token) => [context.pid, token, context.birth].filter((line) => line !== null).map((line) => `${line}\n`).join('');

/**
 * The holder of the lock (or of a takeover marker), or null when there is no such file. `raw` is
 * the whole content, unique to one acquisition; `pid` is null when the file holds no valid pid, and
 * `birth` when it names no birth.
 */
export function readLock(lockPath) {
  let fd;
  try {
    fd = openSync(lockPath, 'r');
  } catch (error) {
    if (isCode(error, 'ENOENT')) return null;
    throw error;
  }
  let raw;
  try {
    raw = readFileSync(fd, 'utf8');
  } finally {
    closeSync(fd);
  }
  const match = /^(\d+)\n(?:([0-9a-f]{32})\n(?:([!-~]{1,128})\n)?)?$/.exec(raw);
  const pid = match ? Number(match[1]) : null;
  return { pid: Number.isSafeInteger(pid) && pid > 0 ? pid : null, token: match?.[2] ?? null, birth: match?.[3] ?? null, raw };
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
 * True when the live process with the holder's pid is another process than the holder: the holder
 * named its birth, and the process with that pid now was born otherwise, so the holder is gone and
 * the system gave its pid away. The wall clock plays no part, so a step of it never makes a live
 * holder look gone. When either birth cannot be told, the holder is taken to be alive.
 */
export function isReusedPid(held, { birthOf = processBirth } = {}) {
  if (!held?.pid || held.birth === null) return false;
  const current = birthOf(held.pid);
  return current !== null && current !== held.birth;
}

/** True while the process that wrote `held` (a lock or marker) is alive. */
export function holderAlive(held, { isAlive = pidAlive, birthOf = processBirth } = {}) {
  return Boolean(held?.pid) && isAlive(held.pid) && !isReusedPid(held, { birthOf });
}

/**
 * A marker whose holder is gone is abandoned, including one whose pid now belongs to another
 * process. A live holder keeps its marker however long it is stopped, so no other process acts in
 * its place.
 */
function isAbandoned(held, context) {
  // The marker sections of this process are synchronous, so a marker naming it is left over.
  return held.pid === process.pid || !holderAlive(held, context);
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
    if (createExclusive(marker, ownerContent(context, newToken()), context.pid, context.fs)) {
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

/** `pid`, `birth`, `isAlive`, `birthOf` and `fs` replace this process's identity and its view of others, for tests. */
function contextOf(lockPath, { pid = process.pid, isAlive = pidAlive, birthOf = processBirth, birth, fs = nodeFs } = {}) {
  const ownBirth = pid === process.pid ? birthOfSelf() : birthOf(pid);
  return { lockPath, pid, isAlive, birthOf, birth: birth === undefined ? ownBirth : birth, fs };
}

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
 * Runs `removeLeftovers` once the lock is published. The sweep is housekeeping: failing the
 * acquisition there would leave a published lock that no handle can release, so its errors are
 * ignored and what it could not remove is left for a later sweep.
 */
function sweepLeftovers(lockPath, context) {
  try {
    removeLeftovers(lockPath, context);
  } catch {
    // Best effort; see above.
  }
}

/**
 * Takes `daemon.lock`, created exclusively and holding the pid, a token of this acquisition and the
 * process birth. A lock whose holder is gone (its pid is not alive or now belongs to a process born
 * otherwise), or that holds no valid pid, is stale and replaced. Resolves
 * `{ acquired: true, token, release, isHeld }`, or `{ acquired: false, holder }` naming the live
 * holder (null when another process kept removing a stale lock). `fs` replaces the calls that
 * create, write and remove files, for tests.
 */
export async function acquireLock(lockPath, options = {}) {
  const context = contextOf(lockPath, options);
  const token = newToken();
  for (let tries = 1; ; tries++) {
    if (createExclusive(lockPath, ownerContent(context, token), context.pid, context.fs)) {
      sweepLeftovers(lockPath, context);
      return { acquired: true, token, release: () => releaseLock(lockPath, token, options), isHeld: () => holdsLock(lockPath, token) };
    }
    const current = readLock(lockPath);
    if (current && holderAlive(current, context)) return { acquired: false, holder: current };
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
