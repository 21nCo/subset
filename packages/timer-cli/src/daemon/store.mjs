import { randomBytes } from 'node:crypto';
import * as nodeFs from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { emptyStore, parseStore } from '@subset.dev/timer-core';

const TEMP_SUFFIX = /\.\d+\.[0-9a-f]{8}\.tmp$/;
const MARKS_VERSION = 1;
const PLAYS_VERSION = 1;
/** The parts of an alert a sink or a handler plays (alerts/process.mjs `playParts`). */
export const ALERT_PART = /^(notification|sound:[0-9]{1,2})$/;

const isTime = (value) => Number.isSafeInteger(value) && value >= 0;
const isMark = (mark) => typeof mark?.timerId === 'string' && isTime(mark.startedAt) && isTime(mark.base) && isTime(mark.through);
const isObject = (value) => typeof value === 'object' && value !== null && !Array.isArray(value);
const isHandoff = (handoff) =>
  typeof handoff?.alertId === 'string' && isObject(handoff.alert) && typeof handoff.alert.timerId === 'string' && typeof handoff.alert.kind === 'string' && isObject(handoff.timer);
const isParts = (value) => Array.isArray(value) && value.every((part) => typeof part === 'string' && ALERT_PART.test(part));
const isAcknowledged = (entry) => isHandoff(entry) && typeof entry.subscriberId === 'string' && (entry.played === undefined || isParts(entry.played));
const isPlay = (entry) =>
  isHandoff(entry) &&
  (entry.subscriberId === undefined || typeof entry.subscriberId === 'string') &&
  Array.isArray(entry.keys) &&
  entry.keys.every((key) => typeof key === 'string') &&
  isParts(entry.played) &&
  typeof entry.finished === 'boolean';

function isCode(error, ...codes) {
  return error && codes.includes(error.code);
}

/** Writes all of `bytes`, as one write(2) may take only part of them, for example on a full disk. */
export function writeAll(fs, fd, bytes) {
  for (let offset = 0; offset < bytes.length;) {
    const written = fs.writeSync(fd, bytes, offset, bytes.length - offset);
    if (typeof written !== 'number' || written <= 0) throw Object.assign(new Error('The file system took none of the remaining bytes.'), { code: 'EIO' });
    offset += written;
  }
}

function removeTemp(temp, fs) {
  try {
    fs.unlinkSync(temp);
  } catch {
    // The temp file is removed at the next start.
  }
}

/**
 * Writes `data` to a temp file beside `path`, fsyncs it, renames it over `path` and fsyncs the
 * directory, so a reader sees the old file or the new one, never a partial write. A failure before
 * the rename removes the temp file and throws, leaving `path` as it was. Once the rename succeeded
 * the new file is in place, so a failed directory fsync is logged rather than thrown.
 */
export function writeFileAtomic(path, data, { fs = nodeFs, log = () => {} } = {}) {
  const temp = `${path}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
  const fd = fs.openSync(temp, 'wx', 0o600);
  try {
    try {
      writeAll(fs, fd, Buffer.from(data, 'utf8'));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temp, path);
  } catch (error) {
    removeTemp(temp, fs);
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
 * version 1), `scheduler.json` (for each running stretch, the time through which its alerts were
 * handled, the alerts handed to the alert handler that it has not yet acknowledged, and those it
 * acknowledged whose answer it may not have received, with the parts it started playing) and
 * `plays.json` (the play journal, see `createPlayJournal`). Only the daemon holding `daemon.lock`
 * creates one.
 */
export function createStateStore(paths, { fs = nodeFs, log = () => {}, now = Date.now } = {}) {
  /** Removes temp files a crash left between a write and its rename. */
  function removeLeftovers() {
    for (const name of fs.readdirSync(paths.dataDir)) {
      if (!TEMP_SUFFIX.test(name)) continue;
      const target = name.replace(TEMP_SUFFIX, '');
      if (![paths.state, paths.scheduler, paths.plays].some((path) => target === basename(path))) continue;
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
    let suffix = 0;
    while (fs.existsSync(target)) {
      suffix += 1;
      target = join(paths.dataDir, `state.corrupt-${stamp}-${suffix}.json`);
    }
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

  /**
   * The alert checkpoint `saveMarks` recorded (see `createAlertHandlers`): `{ handoffs, acknowledged }`,
   * each empty when unknown.
   */
  function loadAlerts() {
    let value;
    try {
      value = JSON.parse(fs.readFileSync(paths.scheduler, 'utf8'));
    } catch (error) {
      if (!isCode(error, 'ENOENT') && !(error instanceof SyntaxError)) throw error;
      return { handoffs: [], acknowledged: [] };
    }
    const list = (key, valid) => (value?.version === MARKS_VERSION && Array.isArray(value[key]) ? value[key].filter((item) => valid(item)) : []);
    return { handoffs: list('handoffs', isHandoff), acknowledged: list('acknowledged', isAcknowledged) };
  }

  /** Saves the marks and, in the same write, the alert checkpoint: handoffs and remembered acknowledgements. */
  function saveMarks(marks, { handoffs = [], acknowledged = [] } = {}) {
    const value = { version: MARKS_VERSION, marks };
    if (handoffs.length) value.handoffs = handoffs;
    if (acknowledged.length) value.acknowledged = acknowledged;
    writeFileAtomic(paths.scheduler, `${JSON.stringify(value)}\n`, { fs, log });
  }

  /** The play journal's entries (see `createPlayJournal`); none when the file is missing or unreadable. */
  function loadPlays() {
    let value;
    try {
      value = JSON.parse(fs.readFileSync(paths.plays, 'utf8'));
    } catch (error) {
      if (!isCode(error, 'ENOENT') && !(error instanceof SyntaxError)) throw error;
      if (error instanceof SyntaxError) log(`plays.json could not be read (${error.message}); no play is resumed.`);
      return [];
    }
    if (value?.version !== PLAYS_VERSION || !Array.isArray(value.plays)) return [];
    return value.plays.filter(isPlay);
  }

  function savePlays(plays) {
    writeFileAtomic(paths.plays, `${JSON.stringify({ version: PLAYS_VERSION, plays })}\n`, { fs, log });
  }

  return { load, save, loadMarks, loadAlerts, saveMarks, loadPlays, savePlays };
}
