// Moves an app bundle to the user's Trash (SET-231), as `<appName> <date> <time>.app` in ~/.Trash (SUBSET_TRASH_DIR,
// an absolute folder, stands in for it in tests). On the same volume the bundle is renamed there, which is atomic. On
// another volume (rename fails with EXDEV) it is copied there with ditto, and the original is removed only after the
// copy succeeded; a copy that fails or is interrupted is removed from the Trash and the original stays. An app is never
// removed without a copy of it in the Trash.
import { accessSync, chmodSync, constants, lstatSync, mkdirSync, renameSync, statSync } from 'node:fs';
import path from 'node:path';
import { INSTALL_TOOLS, removeStaged } from './install.mjs';
import { runTool } from './verify.mjs';

const COPY_TIMEOUT_MS = 10 * 60 * 1000;
const MAX_NAMES = 100;
// rename(2) and mkdir(2) fail with these when the name is taken, so the next name is tried.
const TAKEN = new Set(['EEXIST', 'ENOTEMPTY', 'ENOTDIR', 'EISDIR']);

/** The Trash cannot be used, or the app could not be moved there. */
export class TrashError extends Error {}

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

// Copies `bundle` into a new folder in the Trash with ditto (aborted by `signal`), then removes the original. A copy
// that fails is removed again, and the original stays.
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
  try {
    await removeStaged(bundle, tools);
  } catch (error) {
    throw new TrashError(`${bundle} was copied to ${candidate} in the Trash, but it could not be removed (${reason(error)}); remove it by hand`);
  }
  return candidate;
}

/**
 * Moves `bundle` (an app) to the Trash `trash` as `<appName> <date> <time>.app`: renamed when it is on the same volume,
 * otherwise copied with ditto and then removed. `signal` aborts a copy, which is then removed (the original stays).
 * Resolves the path in the Trash; rejects with a TrashError (or the abort reason) leaving the original in place, except
 * when the copy succeeded and the original could not be removed (the message says so).
 */
export async function moveToTrash(bundle, { trash, appName, now = new Date(), tools = INSTALL_TOOLS, signal, rename = renameSync }) {
  return renameIntoTrash(bundle, { trash, appName, now, rename }) ?? copyIntoTrash(bundle, { trash, appName, now, tools, signal });
}
