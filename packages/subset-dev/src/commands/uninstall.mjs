// subset uninstall <app> [--quit]: moves every installed copy of a Subset Mac app (in /Applications and ~/Applications)
// to the user's Trash (macos/trash.mjs) and deletes its receipt. The app's data (preferences, Application Support,
// containers) stays. A running app is not moved: the command refuses, or with --quit quits it first.
import { rmSync } from 'node:fs';
import process from 'node:process';
import { CatalogInvalidError, CatalogUnavailableError, loadCatalog, printable } from '../feed.mjs';
import { ApplicationsFoldersError, applicationsFolders, detectApps, receiptFile } from '../macos/apps.mjs';
import { InterruptedError } from '../macos/install.mjs';
import { moveToTrash, prepareTrash, TrashError, trashFolder } from '../macos/trash.mjs';
import { pids, QUIT_TIMEOUT_MS, quitProcesses, RunningError, runningProcesses, UPDATE_TOOLS } from '../macos/update.mjs';
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

/**
 * Runs `subset uninstall <args>`, writing to `stdout` and `stderr`, and returns the exit code: 0 when every copy is in
 * the Trash and the receipt is gone, 1 when the app is not installed or a copy could not be moved (the receipt then
 * stays), 2 for a usage error, or 128 + the signal number when a signal stopped a copy to another volume's Trash.
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
  const [copies] = await detectApps([app], { folders, home, plutil: tools.plutil });
  if (copies.length === 0) return fail(`${app.name} is not installed in /Applications or ~/Applications.`);
  const notMoved = `${app.name} was not uninstalled`;

  const controller = new AbortController();
  const stop = (signal) => {
    if (!controller.signal.aborted) controller.abort(new InterruptedError(signal));
  };
  const handlers = Object.keys(SIGNALS).map((signal) => [signal, () => stop(signal)]);
  for (const [signal, handler] of handlers) signals.on(signal, handler);
  try {
    prepareTrash(trash);
    // Every copy is checked, and quit with --quit, before any is moved.
    for (const copy of copies) {
      const running = await runningProcesses(copy.path, { tools, signal: controller.signal });
      if (running.length === 0) continue;
      if (!options.quit) throw new RunningError(`${app.name} is running from ${copy.path} (${pids(running)}); quit it, or use subset uninstall ${app.id} --quit`);
      say(stderr, `Quitting ${app.name} (${pids(running)})`);
      const left = await quitProcesses(copy.path, running, { tools, timeoutMs: quitTimeoutMs, signal: controller.signal });
      if (left.length > 0) throw new RunningError(`${app.name} is still running ${quitTimeoutMs / 1000} seconds after it was asked to quit (${pids(left)})`);
    }
    for (const copy of copies) {
      const trashed = await moveToTrash(copy.path, { trash, appName: app.appName, now: new Date(clock()), tools, signal: controller.signal });
      say(stdout, `Moved ${app.name}${copy.version ? ` ${copy.version}` : ''} (${copy.folder}) to the Trash: ${trashed}`);
    }
  } catch (error) {
    if (error instanceof InterruptedError || controller.signal.aborted) {
      say(stderr, `subset: ${notMoved}: interrupted by ${controller.signal.reason.signal}.`);
      return 128 + SIGNALS[controller.signal.reason.signal];
    }
    if (error instanceof RunningError || error instanceof TrashError) return fail(`${notMoved}: ${error.message}.`);
    throw error;
  } finally {
    for (const [signal, handler] of handlers) signals.off(signal, handler);
  }
  try {
    rmSync(receiptFile(home, app.bundleId), { force: true });
  } catch (error) {
    say(stderr, `subset: warning: the receipt ${receiptFile(home, app.bundleId)} could not be removed (${error.code ?? error.message})`);
  }
  return 0;
}
