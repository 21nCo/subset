// Moves an app bundle to the user's Trash (SET-231), as `<appName> <date> <time>.app` in ~/.Trash (SUBSET_TRASH_DIR,
// an absolute folder, stands in for it in tests). The bundle is first renamed to a hidden name beside it (hiddenName(),
// kind `trash`), and must then be the copy that was checked (the same device and inode), otherwise it is renamed back
// and refused. On the same volume it is then renamed into the Trash. On another volume (rename fails with EXDEV) it is
// copied with ditto into a private hidden folder in the Trash, which is renamed to its Trash name once complete; then
// the hidden copy beside the app is renamed to kind `old` and only then removed. A copy that fails or is interrupted is
// removed from the Trash and the app is renamed back. An app is never removed without a copy of it in the Trash, what
// is removed is the copy that was copied, even if something new is put at its path, a copy that is (even partly)
// removed never carries a name recoverApps() (update.mjs) puts back, and nothing already in the Trash (an empty folder
// included) is replaced or removed.
import { randomBytes } from 'node:crypto';
import { accessSync, chmodSync, constants, lstatSync, mkdirSync, renameSync, statSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { INSTALL_TOOLS, removeStaged } from './install.mjs';
import { runTool } from './verify.mjs';

const COPY_TIMEOUT_MS = 10 * 60 * 1000;
const MAX_NAMES = 100;
// rename(2) fails with these when the name is taken, so the next name is tried.
const TAKEN = new Set(['EEXIST', 'ENOTEMPTY', 'ENOTDIR', 'EISDIR']);

/**
 * The Trash cannot be used, or the app could not be moved there. `left`, when set, is where the app is now (a hidden
 * name beside its old path).
 */
export class TrashError extends Error {}

/**
 * A hidden name in `dir` for `<appName>.app` set aside by this process: `.<appName>.app.subset-<kind>-<pid>-<random>`,
 * with the pid of this process, so that recoverApps() (update.mjs) can tell a copy another subset is still working on
 * from one an interrupted subset left behind. `kind` says what the copy is:
 *   update  the installed copy, between the two renames of an update's swap;
 *   trash   the installed copy, set aside by an uninstall until it is in the Trash (on another volume, until its copy
 *           there is complete);
 *   old     a copy that is no longer the installed one: replaced by an update, or already copied to the Trash. It is
 *           never put back, only named, since it may be an old version or partly removed;
 *   copy    (in the Trash) a copy being made there with ditto, renamed to its Trash name once complete.
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
    accessSync(trash, constants.W_OK | constants.X_OK);
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

const lstatOrUndefined = (file) => {
  try {
    return lstatSync(file);
  } catch {
    return undefined;
  }
};
// Whether anything is at `file`, a broken link or an empty folder too (rename(2) would replace an empty folder).
const taken = (file) => lstatOrUndefined(file) !== undefined;

/**
 * Renames `bundle` into the Trash under the first free name (one where nothing is, not even an empty folder),
 * synchronously. Resolves its new path, or undefined when the Trash is on another volume (EXDEV). Throws a TrashError
 * for anything else.
 */
export function renameIntoTrash(bundle, { trash, appName, now = new Date(), rename = renameSync }) {
  for (let n = 1; n <= MAX_NAMES; n += 1) {
    const candidate = path.join(trash, trashName(appName, now, n));
    if (taken(candidate)) continue;
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

// Copies `bundle` with ditto (aborted by `signal`) into a private hidden folder in the Trash, which only this removes,
// renames that to the first free Trash name once complete and resolves its path. A copy that fails is removed again
// (or named, when it cannot be); `bundle` is never changed.
async function copyIntoTrash(bundle, { trash, appName, now, tools, signal }) {
  const copy = hiddenName(trash, appName, 'copy');
  try {
    mkdirSync(copy, { mode: 0o700 });
  } catch (error) {
    throw new TrashError(`a folder cannot be made in the Trash ${trash} (${reason(error)})`);
  }
  let failure;
  let placed;
  try {
    const run = await runTool(tools.ditto, [bundle, copy], { signal, timeout: COPY_TIMEOUT_MS });
    if (run.code !== 0) failure = new TrashError(`ditto could not copy ${bundle} to the Trash on another volume (${run.stderr.trim().split('\n').at(-1) || `exit ${run.code}`})`);
    else {
      chmodSync(copy, lstatSync(bundle).mode & 0o7777);
      placed = renameIntoTrash(copy, { trash, appName, now });
    }
  } catch (error) {
    failure = signal?.aborted ? signal.reason : error instanceof TrashError ? error : new TrashError(`${bundle} cannot be copied to the Trash ${trash} (${reason(error)})`);
  }
  if (failure) {
    // Only the incomplete copy this made is removed; the original is untouched.
    await removeStaged(copy, tools).catch((error) => {
      if (failure instanceof TrashError) failure.message += `, and the incomplete copy at ${copy} could not be removed (${reason(error)})`;
    });
    throw failure;
  }
  return placed;
}

/**
 * Moves `bundle` (an app) to the Trash `trash` as `<appName> <date> <time>.app`: it is renamed to a hidden name beside
 * it, which must be `identity` ({ dev, ino }, when given), then renamed into the Trash when it is on the same volume,
 * otherwise copied with ditto, renamed to an `old` hidden name and then removed. `setAside: false` is for a bundle that
 * is already at a hidden `old` name of this process (an update's replaced copy): it is moved from where it is.
 * `signal` aborts a copy, which is then removed (and the app renamed back). Resolves the path in the Trash; rejects
 * with a TrashError (or the abort reason) leaving the app at `bundle`, or at the hidden name in `left` when it could
 * not be renamed back, or when the copy succeeded and the hidden copy could not be removed (the message says so).
 */
export async function moveToTrash(bundle, { trash, appName, identity, now = new Date(), tools = INSTALL_TOOLS, signal, rename = renameSync, setAside = true }) {
  if (!setAside) {
    const renamed = renameIntoTrash(bundle, { trash, appName, now, rename });
    if (renamed !== undefined) return renamed;
    const copied = await copyIntoTrash(bundle, { trash, appName, now, tools, signal });
    try {
      await removeStaged(bundle, tools);
    } catch (error) {
      throw Object.assign(new TrashError(`${bundle} was copied to ${copied} in the Trash, but it could not be removed (${reason(error)}); remove it by hand`), { left: bundle });
    }
    return copied;
  }
  const aside = hiddenName(path.dirname(bundle), appName, 'trash');
  try {
    renameSync(bundle, aside);
  } catch (error) {
    throw new TrashError(error.code === 'ENOENT' ? `${bundle} was removed since it was checked` : `${bundle} cannot be set aside to move it to the Trash (${reason(error)})`);
  }
  // Renames the copy set aside back to `bundle` after `error`, and throws it.
  const giveBack = (error) => {
    try {
      renameSync(aside, bundle);
    } catch (putBack) {
      if (error instanceof TrashError) error.message += `, and it could not be renamed back (${reason(putBack)}): it is at ${aside}`;
      if (error instanceof Error) error.left = aside;
    }
    throw error;
  };
  const moved = lstatOrUndefined(aside);
  if (identity && !(moved && moved.dev === identity.dev && moved.ino === identity.ino)) {
    giveBack(new TrashError(`${bundle} was replaced since it was checked (by another subset install or update?), so it was left in place`));
  }
  let copied;
  try {
    copied = renameIntoTrash(aside, { trash, appName, now, rename });
    if (copied !== undefined) return copied;
    copied = await copyIntoTrash(aside, { trash, appName, now, tools, signal });
  } catch (error) {
    giveBack(error);
  }
  // The copy in the Trash is complete: the hidden copy is no longer the installed one, so it gets a name that is never
  // put back before its removal starts (a removal stopped half-way leaves a broken app).
  const old = hiddenName(path.dirname(bundle), appName, 'old');
  try {
    renameSync(aside, old);
  } catch (error) {
    throw Object.assign(new TrashError(`${bundle} was copied to ${copied} in the Trash, but the copy at ${aside} could not be renamed for its removal (${reason(error)}); remove it by hand`), { left: aside });
  }
  try {
    await removeStaged(old, tools);
  } catch (error) {
    throw Object.assign(new TrashError(`${bundle} was copied to ${copied} in the Trash, but it could not be removed from ${old} (${reason(error)}); remove it by hand`), { left: old });
  }
  return copied;
}
