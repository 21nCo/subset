import { randomBytes } from 'node:crypto';
import * as nodeFs from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { emptyStore, parseStore } from '@subset/timer';

const TEMP_SUFFIX = /\.[0-9]+\.[0-9a-f]{8}\.tmp$/;
const MARKS_VERSION = 1;

const isTime = (value) => Number.isSafeInteger(value) && value >= 0;
const isMark = (mark) => typeof mark?.timerId === 'string' && isTime(mark.startedAt) && isTime(mark.base) && isTime(mark.through);

function isCode(error, ...codes) {
  return error && codes.includes(error.code);
}

/**
 * Writes `data` to a temp file beside `path`, fsyncs it, renames it over `path` and fsyncs the
 * directory, so a reader sees the old file or the new one, never a partial write. Once the rename
 * succeeded the new file is in place, so a failed directory fsync is logged rather than thrown.
 */
export function writeFileAtomic(path, data, { fs = nodeFs, log = () => {} } = {}) {
  const temp = `${path}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
  const fd = fs.openSync(temp, 'wx', 0o600);
  try {
    fs.writeSync(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  try {
    fs.renameSync(temp, path);
  } catch (error) {
    try {
      fs.unlinkSync(temp);
    } catch {
      // The temp file is removed at the next start.
    }
    throw error;
  }
  try {
    syncDirectory(dirname(path), fs);
  } catch (error) {
    log(`${basename(path)} was replaced, but its directory could not be synced: ${error.message}`);
  }
}

function syncDirectory(directory, fs) {
  let fd;
  try {
    fd = fs.openSync(directory, 'r');
    fs.fsyncSync(fd);
  } catch (error) {
    // Some file systems cannot fsync a directory; the rename itself is still atomic.
    if (!isCode(error, 'EISDIR', 'EINVAL', 'EPERM', 'ENOTSUP', 'EBADF')) throw error;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

/**
 * The daemon's persistent state in its data directory: `state.json` (the SET-74 store, schema
 * version 1) and `scheduler.json` (for each running stretch, the time through which its alerts were
 * handled). Only the daemon holding `daemon.lock` creates one.
 */
export function createStateStore(paths, { fs = nodeFs, log = () => {}, now = Date.now } = {}) {
  /** Removes temp files a crash left between a write and its rename. */
  function removeLeftovers() {
    for (const name of fs.readdirSync(paths.dataDir)) {
      if (!TEMP_SUFFIX.test(name)) continue;
      const target = name.replace(TEMP_SUFFIX, '');
      if (target !== basename(paths.state) && target !== basename(paths.scheduler)) continue;
      try {
        fs.unlinkSync(join(paths.dataDir, name));
      } catch (error) {
        if (!isCode(error, 'ENOENT')) throw error;
      }
    }
  }

  function moveAside(reason) {
    const stamp = now();
    let target = join(paths.dataDir, `state.corrupt-${stamp}.json`);
    for (let suffix = 1; fs.existsSync(target); suffix++) target = join(paths.dataDir, `state.corrupt-${stamp}-${suffix}.json`);
    fs.renameSync(paths.state, target);
    log(`state.json could not be read (${reason}); moved it to ${basename(target)} and started with no timers.`);
  }

  /** Reads the store. A missing file is an empty store; an unreadable one is moved aside first. */
  function load() {
    removeLeftovers();
    let text;
    try {
      text = fs.readFileSync(paths.state, 'utf8');
    } catch (error) {
      if (isCode(error, 'ENOENT')) return emptyStore();
      throw error;
    }
    let value;
    try {
      value = JSON.parse(text);
    } catch (error) {
      moveAside(`invalid JSON: ${error.message}`);
      return emptyStore();
    }
    const parsed = parseStore(value);
    if (!parsed.ok) {
      moveAside(parsed.error.message);
      return emptyStore();
    }
    return parsed.store;
  }

  function save(store) {
    writeFileAtomic(paths.state, `${JSON.stringify(store)}\n`, { fs, log });
  }

  /** The scheduler's marks (see `createScheduler`), or null when unknown. */
  function loadMarks() {
    let value;
    try {
      value = JSON.parse(fs.readFileSync(paths.scheduler, 'utf8'));
    } catch (error) {
      if (!isCode(error, 'ENOENT') && !(error instanceof SyntaxError)) throw error;
      return null;
    }
    if (value?.version !== MARKS_VERSION || !Array.isArray(value.marks)) return null;
    return value.marks.filter(isMark);
  }

  function saveMarks(marks) {
    writeFileAtomic(paths.scheduler, `${JSON.stringify({ version: MARKS_VERSION, marks })}\n`, { fs, log });
  }

  return { load, save, loadMarks, saveMarks };
}
