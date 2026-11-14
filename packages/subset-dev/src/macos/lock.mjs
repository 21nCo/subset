// The per-app lock of subset install, update and uninstall (SET-231): one of them at a time works on an app (by bundle
// ID), from before recoverApps() (update.mjs) until its receipt is written or removed; subset list takes none. A
// command creates its own lock file, `<bundleId>.<pid>.<random>.lock` in ~/Library/Application Support/Subset/locks,
// exclusively, and only then looks at the others: when one belongs to a process that still runs, it removes its own
// and refuses, naming that pid. Of two commands that start together, at least the second to look sees the first's
// file, so two never both hold the lock (both may refuse; running one again then works). A lock file whose process no
// longer runs (a SIGKILL or a power loss) is ignored and removed, so nothing has to be taken over.
import { randomBytes } from 'node:crypto';
import { mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

/** Another subset is installing, updating or uninstalling the app, or the lock cannot be made: nothing was changed. */
export class LockError extends Error {}

/** Whether process `pid` still runs (a process of another user counts). */
export function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** The folder of the lock files. */
export const locksFolder = (home) => path.join(home, 'Library', 'Application Support', 'Subset', 'locks');

/**
 * Takes the lock of `app` ({ name, bundleId }) for this process and returns the function that releases it. Throws a
 * LockError when another subset that still runs holds it (or is taking it), or when the lock file cannot be made.
 * `running(pid)` tells whether a process runs.
 */
export function lockApp(app, { home, running = alive }) {
  const dir = locksFolder(home);
  const mine = `${app.bundleId}.${process.pid}.${randomBytes(6).toString('hex')}.lock`;
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileSync(path.join(dir, mine), `${process.pid}\n`, { flag: 'wx', mode: 0o600 });
  } catch (error) {
    throw new LockError(`its lock cannot be made in ${dir} (${error.code ?? error.message})`);
  }
  const release = () => rmSync(path.join(dir, mine), { force: true });
  const pattern = new RegExp(`^${escapeRegExp(app.bundleId)}\\.(\\d+)\\.[0-9a-f]{12}\\.lock$`);
  let names;
  try {
    names = readdirSync(dir);
  } catch (error) {
    release();
    throw new LockError(`its lock cannot be checked in ${dir} (${error.code ?? error.message})`);
  }
  for (const name of names) {
    const pid = Number(pattern.exec(name)?.[1]);
    if (name === mine || !pid) continue;
    if (running(pid)) {
      release();
      throw new LockError(`another subset (pid ${pid}) is installing, updating or uninstalling ${app.name}; run this again once it has finished (if no subset runs, remove ${path.join(dir, name)})`);
    }
    rmSync(path.join(dir, name), { force: true });
  }
  return release;
}
