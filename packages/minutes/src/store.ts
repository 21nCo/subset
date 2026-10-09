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

/** Reads session records without changing anything. A missing state directory is an empty status. */
export async function readStatus(
  stateDirectory: string,
  options: { now?: Date; alive?: (pid: number) => boolean } = {},
): Promise<MinutesStatus> {
  const alive = options.alive ?? isProcessAlive;
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
    sessions: records.slice(0, STATUS_SESSION_LIMIT).map((record) => {
      // A finished session's pid may have been reused, so only an active record is checked.
      const active = !isTerminal(record.state);
      const running = active && alive(record.pid);
      return { ...record, alive: running, stale: active && !running };
    }),
    unreadable,
  };
}
