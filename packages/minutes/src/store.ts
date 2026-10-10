import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import {
  MINUTES_CONTRACT_VERSION,
  STATUS_SESSION_LIMIT,
  isSessionRecord,
  type MinutesStatus,
  type SessionRecord,
} from './contract.js';
import { isTerminal } from './session.js';

/** Writes a session record atomically as `<state dir>/<id>.json` (mode 0600). */
export async function writeSessionRecord(stateDirectory: string, record: SessionRecord): Promise<void> {
  if (!isSessionRecord(record)) throw new Error('Refusing to write an invalid session record.');
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
  const file = path.join(stateDirectory, `${record.id}.json`);
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
    await rename(temporary, file);
  } finally {
    await rm(temporary, { force: true }).catch(() => {});
  }
}

export function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM';
  }
}

/** When a process started, from `ps -o lstart=` (macOS and Linux), or null when unknown. */
export function processStartedAt(pid: number): Promise<Date | null> {
  return new Promise((resolve) => {
    execFile('/bin/ps', ['-o', 'lstart=', '-p', String(pid)], { timeout: 2_000, env: { ...process.env, LC_ALL: 'C' } }, (error, stdout) => {
      const time = error ? Number.NaN : Date.parse(stdout.trim());
      resolve(Number.isNaN(time) ? null : new Date(time));
    });
  });
}

/**
 * Whether the CLI that wrote `record` is still running. A pid can be reused after the CLI exits, so a
 * process that started after the session did is not the session's.
 */
export async function isSessionProcessAlive(record: SessionRecord): Promise<boolean> {
  if (!isProcessAlive(record.pid)) return false;
  const started = await processStartedAt(record.pid);
  return started === null || started.getTime() <= Date.parse(record.startedAt) + 60_000;
}

/** Reads session records without changing anything. A missing state directory is an empty status. */
export async function readStatus(
  stateDirectory: string,
  options: { now?: Date; alive?: (pid: number, record: SessionRecord) => boolean | Promise<boolean> } = {},
): Promise<MinutesStatus> {
  const alive = options.alive ?? ((_pid: number, record: SessionRecord) => isSessionProcessAlive(record));
  let names: string[] = [];
  try {
    names = (await readdir(stateDirectory)).filter((name) => /^[A-Za-z0-9_-]{1,64}\.json$/.test(name));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
  }

  const records: SessionRecord[] = [];
  let unreadable = 0;
  for (const name of names) {
    try {
      const value: unknown = JSON.parse(await readFile(path.join(stateDirectory, name), 'utf8'));
      if (isSessionRecord(value) && `${value.id}.json` === name) records.push(value);
      else unreadable += 1;
    } catch {
      unreadable += 1;
    }
  }

  records.sort((a, b) => b.startedAt.localeCompare(a.startedAt) || b.id.localeCompare(a.id));
  return {
    v: MINUTES_CONTRACT_VERSION,
    kind: 'minutes.status',
    observedAt: (options.now ?? new Date()).toISOString(),
    stateDirectory,
    sessions: await Promise.all(records.slice(0, STATUS_SESSION_LIMIT).map(async (record) => {
      // A finished session's pid may have been reused, so only an active record is checked.
      const active = !isTerminal(record.state);
      const running = active && (await alive(record.pid, record));
      return { ...record, alive: running, stale: active && !running };
    })),
    unreadable,
  };
}
