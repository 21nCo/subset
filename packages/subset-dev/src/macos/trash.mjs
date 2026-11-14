// Moves an app bundle to the user's Trash (SET-231), as `<appName> <date> <time>.app` in ~/.Trash (SUBSET_TRASH_DIR,
// an absolute folder, stands in for it in tests). On the same volume the bundle is renamed there, which is atomic. On
// another volume (rename fails with EXDEV) it is first renamed to a hidden name beside it (hiddenName()), then copied
// there with ditto, and that hidden copy is removed only after the copy succeeded; a copy that fails or is interrupted
// is removed from the Trash and the app is renamed back. An app is never removed without a copy of it in the Trash, and
// what is removed is the copy that was copied, even if another subset install or update puts a new one at its path.
import { randomBytes } from 'node:crypto';
import { accessSync, chmodSync, constants, lstatSync, mkdirSync, renameSync, statSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { INSTALL_TOOLS, removeStaged } from './install.mjs';
import { runTool } from './verify.mjs';

const COPY_TIMEOUT_MS = 10 * 60 * 1000;
const MAX_NAMES = 100;
// rename(2) and mkdir(2) fail with these when the name is taken, so the next name is tried.
const TAKEN = new Set(['EEXIST', 'ENOTEMPTY', 'ENOTDIR', 'EISDIR']);

/**
 * The Trash cannot be used, or the app could not be moved there. `left`, when set, is where the app is now (a hidden
 * name beside its old path).
 */
export class TrashError extends Error {}

/**
 * A hidden name in `dir` for `<appName>.app` set aside by `kind` (update or trash):
 * `.<appName>.app.subset-<kind>-<pid>-<random>`, with the pid of this process, so that recoverApps() (update.mjs) can
 * tell a copy another subset is still working on from one an interrupted subset left behind.
 */
export const hiddenName = (dir, appName, kind) => path.join(dir, `.${appName}.app.subset-${kind}-${process.pid}-${randomBytes(6).toString('hex')}`);

/** The Trash folder: SUBSET_TRASH_DIR when set (tests only; it must be absolute), otherwise ~/.Trash. */
export function trashFolder({ env, home }) {
  const override = env.SUBSET_TRASH_DIR;
  if (override === undefined || override === '') return path.join(home, '.Trash');
  if (!path.isAbsolute(override)) throw new TrashError('SUBSET_TRASH_DIR must be an absolute folder');
  return override;
}

/**
 * Checks, before anything is changed, that the Trash is a folder this user can write to, creating ~/.Trash (mode 0700)
 * when it is missing. Throws a TrashError when it is not.
 */
export function prepareTrash(trash) {
  try {
    mkdirSync(trash, { recursive: true, mode: 0o700 });
    if (!statSync(trash).isDirectory()) throw Object.assign(new Error('not a folder'), { code: 'ENOTDIR' });
    accessSync(trash, constants.W_OK);
  } catch (error) {
    throw new TrashError(`the Trash ${trash} cannot be used (${error.code ?? error.message})`);
  }
}

const pad = (number) => String(number).padStart(2, '0');

/** The name of the `n`th candidate (from 1) for `<appName>.app` moved to the Trash at `date`, in local time. */
export function trashName(appName, date, n = 1) {
  const stamp = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}.${pad(date.getMinutes())}.${pad(date.getSeconds())}`;
  return `${appName} ${stamp}${n > 1 ? ` ${n}` : ''}.app`;
}

const reason = (error) => error.code ?? error.message;

/**
 * Renames `bundle` into the Trash under the first free name, synchronously. Resolves its new path, or undefined when
 * the Trash is on another volume (EXDEV). Throws a TrashError for anything else.
 */
export function renameIntoTrash(bundle, { trash, appName, now = new Date(), rename = renameSync }) {
  for (let n = 1; n <= MAX_NAMES; n += 1) {
    const candidate = path.join(trash, trashName(appName, now, n));
    try {
      rename(bundle, candidate);
      return candidate;
    } catch (error) {
      if (error.code === 'EXDEV') return undefined;
      if (!TAKEN.has(error.code)) throw new TrashError(`${bundle} cannot be moved to the Trash ${trash} (${reason(error)})`);
    }
  }
  throw new TrashError(`the Trash ${trash} already holds ${MAX_NAMES} copies named ${trashName(appName, now)}`);
}

// Copies `bundle` into a new folder in the Trash with ditto (aborted by `signal`) and resolves its path. A copy that
// fails is removed again; `bundle` is never changed.
async function copyIntoTrash(bundle, { trash, appName, now, tools, signal }) {
  let candidate;
  for (let n = 1; candidate === undefined; n += 1) {
    if (n > MAX_NAMES) throw new TrashError(`the Trash ${trash} already holds ${MAX_NAMES} copies named ${trashName(appName, now)}`);
    const name = path.join(trash, trashName(appName, now, n));
    try {
      mkdirSync(name, { mode: 0o700 });
      candidate = name;
    } catch (error) {
      if (!TAKEN.has(error.code)) throw new TrashError(`a folder cannot be made in the Trash ${trash} (${reason(error)})`);
    }
  }
  let failure;
  try {
    const copy = await runTool(tools.ditto, [bundle, candidate], { signal, timeout: COPY_TIMEOUT_MS });
    if (copy.code !== 0) failure = new TrashError(`ditto could not copy ${bundle} to the Trash on another volume (${copy.stderr.trim().split('\n').at(-1) || `exit ${copy.code}`})`);
    else chmodSync(candidate, lstatSync(bundle).mode & 0o7777);
  } catch (error) {
    failure = signal?.aborted ? signal.reason : new TrashError(`${bundle} cannot be copied to the Trash ${trash} (${reason(error)})`);
  }
  if (failure) {
    // Only the incomplete copy this made is removed; the original is untouched.
    await removeStaged(candidate, tools).catch(() => {});
    throw failure;
  }
  return candidate;
}

/**
 * Moves `bundle` (an app) to the Trash `trash` as `<appName> <date> <time>.app`: renamed when it is on the same volume,
 * otherwise renamed to a hidden name beside it, copied with ditto and then removed. `signal` aborts a copy, which is
 * then removed (and the app renamed back). Resolves the path in the Trash; rejects with a TrashError (or the abort
 * reason) leaving the app at `bundle`, or at the hidden name in `left` when it could not be renamed back, or when the
 * copy succeeded and the hidden copy could not be removed (the message says so).
 */
export async function moveToTrash(bundle, { trash, appName, now = new Date(), tools = INSTALL_TOOLS, signal, rename = renameSync }) {
  const renamed = renameIntoTrash(bundle, { trash, appName, now, rename });
  if (renamed !== undefined) return renamed;
  const aside = hiddenName(path.dirname(bundle), appName, 'trash');
  try {
    renameSync(bundle, aside);
  } catch (error) {
    throw new TrashError(`${bundle} cannot be set aside to copy it to the Trash (${reason(error)})`);
  }
  let copied;
  try {
    copied = await copyIntoTrash(aside, { trash, appName, now, tools, signal });
  } catch (error) {
    try {
      renameSync(aside, bundle);
    } catch (putBack) {
      if (error instanceof TrashError) error.message += `, and it could not be renamed back (${reason(putBack)}): it is at ${aside}`;
      if (error instanceof Error) error.left = aside;
    }
    throw error;
  }
  try {
    await removeStaged(aside, tools);
  } catch (error) {
    throw Object.assign(new TrashError(`${bundle} was copied to ${copied} in the Trash, but it could not be removed from ${aside} (${reason(error)}); remove it by hand`), { left: aside });
  }
  return copied;
}
