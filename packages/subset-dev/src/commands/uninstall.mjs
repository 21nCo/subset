// subset uninstall <app> [--quit]: moves every installed copy of a Subset Mac app (in /Applications and ~/Applications)
// to the user's Trash (macos/trash.mjs) and deletes its receipt. The app's data (preferences, Application Support,
// containers) stays. A running app is not moved: the command refuses, or with --quit quits it first. It holds the app's
// lock (macos/lock.mjs) throughout, and moves only the copies it checked (by device and inode).
import { lstatSync, rmSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { CatalogInvalidError, CatalogUnavailableError, loadCatalog, printable } from '../feed.mjs';
import { ApplicationsFoldersError, applicationsFolders, detectApps, readInfoPlist, receiptFile } from '../macos/apps.mjs';
import { InterruptedError } from '../macos/install.mjs';
import { LockError, lockApp } from '../macos/lock.mjs';
import { moveToTrash, prepareTrash, removeLeftCopies, TrashError, trashFolder } from '../macos/trash.mjs';
import { pids, QUIT_TIMEOUT_MS, quitProcesses, recoverApps, RunningError, runningProcesses, UPDATE_TOOLS } from '../macos/update.mjs';
import { SIGNALS } from './install.mjs';

const USAGE = 'Usage: subset uninstall <app> [--quit]';

/** The arguments of `subset uninstall`: { app, quit }, or { error } for anything else. */
export function parseUninstallArgs(args) {
  const options = { app: undefined, quit: false };
  for (const arg of args) {
    if (arg === '--quit') options.quit = true;
    else if (arg.startsWith('-')) return { error: `subset uninstall does not take the option "${printable(arg)}". ${USAGE}` };
    else if (options.app !== undefined) return { error: `subset uninstall takes one app, not "${printable(options.app)}" and "${printable(arg)}". ${USAGE}` };
    else options.app = arg;
  }
  if (options.app === undefined) return { error: `subset uninstall needs an app; subset list shows them. ${USAGE}` };
  return options;
}

const statOf = (file) => {
  try {
    return lstatSync(file);
  } catch {
    return undefined;
  }
};

/**
 * Runs `subset uninstall <args>`, writing to `stdout` and `stderr`, and returns the exit code: 0 when every copy is in
 * the Trash and the receipt is gone (or a copy installed meanwhile keeps it), 1 when the app is not installed, another
 * subset is working on it, a copy could not be moved or one left in place may be the app (the receipt then stays) or the
 * receipt could not be removed, 2 for a usage error, or 128 + the signal number when a signal stopped it.
 */
export async function runUninstall(args, { env, platform, home, stdout, stderr, fetch, now = Date.now(), clock = Date.now, tools = UPDATE_TOOLS, signals = process, quitTimeoutMs = QUIT_TIMEOUT_MS }) {
  const options = parseUninstallArgs(args);
  if (options.error) {
    stderr.write(`subset: ${options.error}\n`);
    return 2;
  }
  const say = (stream, text) => stream.write(`${printable(text)}\n`);
  const fail = (message) => {
    say(stderr, `subset: ${message}`);
    return 1;
  };
  if (platform !== 'darwin') return fail('Mac apps can be uninstalled only on macOS.');

  let folders;
  let trash;
  let catalog;
  try {
    folders = applicationsFolders({ env, home });
    trash = trashFolder({ env, home });
    catalog = await loadCatalog({ env, platform, home, now, fetch });
  } catch (error) {
    if (!(error instanceof CatalogInvalidError || error instanceof CatalogUnavailableError || error instanceof ApplicationsFoldersError || error instanceof TrashError)) throw error;
    stderr.write(`subset: ${error.message}\n`);
    return 1;
  }
  if (catalog.warning) say(stderr, `subset: ${catalog.warning}`);
  const app = catalog.feed.apps.find((candidate) => candidate.id === options.app);
  if (!app) return fail(`there is no Subset Mac app "${printable(options.app)}"; subset list shows them.`);
  const notMoved = `${app.name} was not uninstalled`;
  // No other subset install, update or uninstall of the app runs until this one has finished.
  let unlock;
  try {
    unlock = lockApp(app, { home });
  } catch (error) {
    if (!(error instanceof LockError)) throw error;
    return fail(`${notMoved}: ${error.message}.`);
  }
  try {
    return await uninstallLocked({ app, options, folders, trash, home, clock, tools, signals, quitTimeoutMs, stdout, stderr, say, fail, notMoved });
  } finally {
    unlock();
  }
}

// The rest of subset uninstall, with the app's lock held.
async function uninstallLocked({ app, options, folders, trash, home, clock, tools, signals, quitTimeoutMs, stdout, stderr, say, fail, notMoved }) {
  // A copy an interrupted update or uninstall left under a hidden name is put back first, and so uninstalled too.
  for (const note of recoverApps([app], folders)) say(stderr, `subset: note: ${note}`);
  // So is an incomplete copy a killed subset left in the Trash on another volume.
  for (const note of await removeLeftCopies(app, trash, { tools })) say(stderr, `subset: note: ${note}`);
  // Each copy is identified (device and inode) before and after its Info.plist is read; only that copy is moved.
  const bundles = folders.map((folder) => path.join(folder.dir, `${app.appName}.app`));
  const before = new Map(bundles.map((bundle) => [bundle, statOf(bundle)]));
  const [copies] = await detectApps([app], { folders, home, plutil: tools.plutil });
  if (copies.length === 0) return fail(`${app.name} is not installed in /Applications or ~/Applications.`);
  for (const copy of copies) {
    const seen = before.get(copy.path);
    copy.identity = statOf(copy.path);
    if (!seen || !copy.identity || seen.dev !== copy.identity.dev || seen.ino !== copy.identity.ino) {
      return fail(`${notMoved}: ${copy.path} was replaced while its version was read (by another program?); run subset uninstall ${app.id} again.`);
    }
  }

  const controller = new AbortController();
  const stop = (signal) => {
    if (!controller.signal.aborted) controller.abort(new InterruptedError(signal));
  };
  const handlers = Object.keys(SIGNALS).map((signal) => [signal, () => stop(signal)]);
  for (const [signal, handler] of handlers) signals.on(signal, handler);
  // Refuses when the copy runs, or with --quit quits it (SIGTERM, then waits up to quitTimeoutMs).
  const quitOrRefuse = async (copy, again) => {
    const running = await runningProcesses(copy.path, { tools, signal: controller.signal });
    if (running.length === 0) return;
    if (!options.quit) {
      throw new RunningError(again ? `${app.name} is running from ${copy.path} again (${pids(running)}); quit it and run subset uninstall ${app.id} again` : `${app.name} is running from ${copy.path} (${pids(running)}); quit it, or use subset uninstall ${app.id} --quit`);
    }
    // The processes were found by path: they are quit only while that path is still the copy checked.
    const now = statOf(copy.path);
    if (!now || now.dev !== copy.identity.dev || now.ino !== copy.identity.ino) {
      throw new TrashError(`${copy.path} was replaced since it was checked (by another program?), so it was not quit or moved`);
    }
    say(stderr, `Quitting ${app.name} (${pids(running)})`);
    const left = await quitProcesses(copy.path, running, { tools, timeoutMs: quitTimeoutMs, signal: controller.signal });
    if (left.length > 0) throw new RunningError(`${app.name} is still running ${quitTimeoutMs / 1000} seconds after it was asked to quit (${pids(left)})`);
  };
  try {
    prepareTrash(trash);
    // Every copy is checked, and quit with --quit, before any is moved.
    for (const copy of copies) await quitOrRefuse(copy, false);
    for (const copy of copies) {
      // Checked again just before the copy is moved: it may have been started since, and a signal stops here.
      controller.signal.throwIfAborted();
      await quitOrRefuse(copy, true);
      const trashed = await moveToTrash(copy.path, { trash, appName: app.appName, identity: copy.identity, now: new Date(clock()), tools, signal: controller.signal });
      say(stdout, `Moved ${app.name}${copy.version ? ` ${copy.version}` : ''} (${copy.folder}) to the Trash: ${trashed}`);
    }
  } catch (error) {
    if (error instanceof InterruptedError || controller.signal.aborted) {
      // A TrashError says itself what happened to the copy (its Trash copy may be complete); otherwise one left set aside is
      // the installed copy, to be renamed back.
      const left = error instanceof TrashError ? ` ${error.message}.` : error?.left ? ` ${error.left} could not be renamed back to its place; rename it back by hand.` : '';
      say(stderr, `subset: ${notMoved}: interrupted by ${controller.signal.reason.signal}.${left}`);
      return 128 + SIGNALS[controller.signal.reason.signal];
    }
    if (error instanceof RunningError || error instanceof TrashError) return fail(`${notMoved}: ${error.message}.`);
    throw error;
  } finally {
    for (const [signal, handler] of handlers) signals.off(signal, handler);
  }
  // The receipt is decided from every folder's <appName>.app, each looked at once after the moves:
  // - absent (nothing there), or not this app: an entry there unchanged (device and inode) since the copies were
  //   identified that is another app of the same name, a link, a file, or a folder without a Contents/Info.plist, as
  //   detectApps() decided;
  // - installed again: something now at a moved copy's path, or new or changed there since the copies were identified,
  //   or replaced while it was looked into (it may be another subset install's copy);
  // - maybe this app: an unchanged bundle folder (not a link) that cannot be looked into (its folder or Contents not
  //   searchable, its Info.plist not readable) or whose Info.plist names this bundle ID.
  // The receipt is deleted only when every entry is absent or not this app. One that may be the app keeps it and exits 1
  // naming each; otherwise one installed again keeps it with a note and exits 0.
  const look = (file) => {
    try {
      return { stat: lstatSync(file) };
    } catch (error) {
      if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return {};
      return { error: error.code ?? error.message };
    }
  };
  // Why an unchanged entry may be this app, or undefined when it is not.
  const mayBeApp = async (bundle, stat) => {
    if (!stat.isDirectory()) return undefined;
    for (const [file, kind] of [[path.join(bundle, 'Contents'), 'isDirectory'], [path.join(bundle, 'Contents', 'Info.plist'), 'isFile']]) {
      const { stat: found, error } = look(file);
      if (error) return `${file} could not be looked into: ${error}`;
      if (!found?.[kind]()) return undefined;
    }
    const info = await readInfoPlist(bundle, tools.plutil);
    if (info === undefined) return 'its Info.plist could not be read';
    return info.CFBundleIdentifier === app.bundleId ? `its Info.plist names ${app.bundleId}` : undefined;
  };
  const changed = (seen, now) => !seen !== !now || (seen && (seen.dev !== now.dev || seen.ino !== now.ino));
  const moved = new Set(copies.map((copy) => copy.path));
  const again = [];
  const maybe = [];
  for (const bundle of bundles) {
    const { stat: current, error } = look(bundle);
    if (error) {
      maybe.push({ bundle, reason: `it could not be looked into: ${error}` });
      continue;
    }
    if (!current) continue;
    const seen = before.get(bundle);
    if (moved.has(bundle) || changed(seen, current)) {
      again.push(bundle);
      continue;
    }
    const reason = await mayBeApp(bundle, current);
    // Replaced while it was looked into: what is there now was not looked into.
    const after = look(bundle);
    if (after.error) maybe.push({ bundle, reason: `it could not be looked into: ${after.error}` });
    else if (changed(current, after.stat)) again.push(bundle);
    else if (reason) maybe.push({ bundle, reason });
  }
  for (const bundle of again) say(stderr, `subset: note: ${bundle} was installed again while ${app.name} was uninstalled, so its receipt stays.`);
  for (const { bundle, reason } of maybe) {
    say(stderr, `subset: ${bundle} was not uninstalled: it may be ${app.name} (${reason}), so the receipt ${receiptFile(home, app.bundleId)} stays; remove the receipt by hand if that is not ${app.name}.`);
  }
  if (maybe.length > 0) return 1;
  if (again.length > 0) return 0;
  try {
    rmSync(receiptFile(home, app.bundleId), { force: true });
  } catch (error) {
    // A name too long for the file system (a bundle ID near the catalog's 255 characters) is a receipt that cannot exist.
    if (error.code === 'ENAMETOOLONG') return 0;
    return fail(`${app.name} was moved to the Trash, but its receipt ${receiptFile(home, app.bundleId)} could not be removed (${error.code ?? error.message}); remove it by hand.`);
  }
  return 0;
}
