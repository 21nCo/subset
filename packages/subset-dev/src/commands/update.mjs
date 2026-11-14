// subset update [<app>...] [--beta] [--quit]: updates the named Subset Mac apps, or every one installed, to the newest
// artifact of the live channel (the beta with --beta), with the download and checks of `subset install`
// (macos/update.mjs). A running app is not replaced: the command refuses, or with --quit quits it first and reopens it
// afterwards. With no apps named it also says when a newer subset.dev is on npm.
import { lstatSync, readFileSync } from 'node:fs';
import process from 'node:process';
import { CatalogInvalidError, CatalogUnavailableError, download, loadCatalog, MAX_FEED_BYTES, printable } from '../feed.mjs';
import { ApplicationsFoldersError, applicationsFolders, detectApps } from '../macos/apps.mjs';
import { InterruptedError } from '../macos/install.mjs';
import { prepareTrash, TrashError, trashFolder } from '../macos/trash.mjs';
import { decideUpdate, pids, QUIT_TIMEOUT_MS, quitProcesses, reopenApp, RunningError, runningProcesses, UPDATE_TOOLS, updateApp } from '../macos/update.mjs';
import { compareVersions } from '../macos/verify.mjs';
import { failure, receiptFor, SIGNALS } from './install.mjs';

const USAGE = 'Usage: subset update [<app>...] [--beta] [--quit]';
const { version: LAUNCHER_VERSION } = JSON.parse(readFileSync(new URL('../../package.json', import.meta.url), 'utf8'));
/** Where the launcher's latest version is asked for: the npm registry's `latest` of subset.dev. */
export const NPM_LATEST_URL = 'https://registry.npmjs.org/subset.dev/latest';

/** The arguments of `subset update`: { apps, beta, quit }, or { error } for anything else. */
export function parseUpdateArgs(args) {
  const options = { apps: [], beta: false, quit: false };
  for (const arg of args) {
    if (arg === '--beta') options.beta = true;
    else if (arg === '--quit') options.quit = true;
    else if (arg.startsWith('-')) return { error: `subset update does not take the option "${printable(arg)}". ${USAGE}` };
    else if (!options.apps.includes(arg)) options.apps.push(arg);
  }
  return options;
}

/**
 * The version of subset.dev on npm when it is newer than `current` (a release is newer than a prerelease of the same
 * version), otherwise undefined. Best-effort: any failure (no network, an HTTP error, an odd answer) is undefined.
 */
export async function newerLauncher({ fetch, current = LAUNCHER_VERSION }) {
  try {
    const bytes = await download(new URL(NPM_LATEST_URL), fetch);
    if (bytes.byteLength > MAX_FEED_BYTES) return undefined;
    const latest = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes))?.version;
    const core = /^(\d+\.\d+\.\d+)(?:-[0-9A-Za-z.-]+)?$/.exec(current)?.[1];
    if (typeof latest !== 'string' || !/^\d+\.\d+\.\d+$/.test(latest) || core === undefined) return undefined;
    const order = compareVersions(latest, core);
    return order > 0 || (order === 0 && core !== current) ? latest : undefined;
  } catch {
    return undefined;
  }
}

// A version as `subset list` shows it: 0.1.0, or 0.1.1-beta.4 for a beta.
const releaseLabel = (release, beta) => (beta ? `${release.version}-beta.${release.build}` : release.version);
const statOf = (file) => {
  try {
    return lstatSync(file);
  } catch {
    return undefined;
  }
};
const copyLabel = (copy) => (copy.channel === 'beta' ? `${copy.version}-beta.${copy.build}` : (copy.version ?? 'unknown version'));

/**
 * Runs `subset update <args>`, writing to `stdout` and `stderr`, and returns the exit code: 0 when every app asked for
 * is updated or up to date, 1 when one is not, 2 for a usage error, or 128 + the signal number when a SIGINT, SIGTERM
 * or SIGHUP (caught on `signals`) stopped it. `quitTimeoutMs` is how long --quit waits for an app to exit.
 */
export async function runUpdate(args, { env, platform, home, stdout, stderr, fetch, now = Date.now(), clock = Date.now, tools = UPDATE_TOOLS, signals = process, quitTimeoutMs = QUIT_TIMEOUT_MS, launcherVersion = LAUNCHER_VERSION }) {
  const options = parseUpdateArgs(args);
  if (options.error) {
    stderr.write(`subset: ${options.error}\n`);
    return 2;
  }
  const say = (stream, text) => stream.write(`${printable(text)}\n`);
  const all = options.apps.length === 0;
  let failed = false;
  const fail = (message) => {
    say(stderr, `subset: ${message}`);
    failed = true;
  };
  // Something that cannot be done: a failure for an app named, only a note when every installed app is updated.
  const skip = (message) => (all ? say(stderr, `subset: note: ${message}`) : fail(message));
  const launcher = async () => {
    const latest = all ? await newerLauncher({ fetch, current: launcherVersion }) : undefined;
    if (latest) say(stdout, `subset.dev ${latest} is available (this is ${launcherVersion}); update it with: npm install -g subset.dev@latest`);
  };
  if (platform !== 'darwin') {
    await launcher();
    fail('Mac apps can be updated only on macOS.');
    return 1;
  }

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
  const apps = all ? catalog.feed.apps : options.apps.map((id) => catalog.feed.apps.find((app) => app.id === id) ?? id);
  const unknown = apps.find((app) => typeof app === 'string');
  if (unknown !== undefined) {
    fail(`there is no Subset Mac app "${printable(unknown)}"; subset list shows them.`);
    return 1;
  }

  // What to do with each installed copy, decided from its Info.plist and receipt before anything is downloaded.
  const installed = await detectApps(apps, { folders, home, plutil: tools.plutil });
  const channel = options.beta ? 'beta' : 'live';
  const updates = [];
  apps.forEach((app, index) => {
    if (installed[index].length === 0 && !all) fail(`${app.name} is not installed; subset install ${app.id} installs it.`);
    for (const copy of installed[index]) {
      const decision = decideUpdate(copy, app, options.beta);
      const where = copy.folder;
      if (decision.action === 'current') say(stdout, `${app.name} ${copyLabel(copy)} is up to date (${where}).`);
      else if (decision.action === 'no-release') skip(`${app.name} has no ${channel} release${options.beta ? '' : `; subset update ${app.id} --beta updates it to the beta`}.`);
      else if (decision.action === 'unknown') skip(`${app.name} in ${where} was not updated: its version ${JSON.stringify(copy.version)} is not x.y.z, so it cannot be compared.`);
      else if (decision.action === 'ahead') {
        skip(`${app.name} in ${where} was not updated: ${copyLabel(copy)} is newer than the ${channel} ${releaseLabel(decision.release, options.beta)}, and subset update does not downgrade.`);
      } else {
        // The copy checked, by device and inode: the swap refuses to replace anything else.
        const identity = statOf(copy.path);
        if (identity) updates.push({ app, copy, release: decision.release, identity });
        else fail(`${app.name} in ${where} was not updated: ${copy.path} is gone.`);
      }
    }
  });
  if (all && installed.every((copies) => copies.length === 0)) say(stdout, 'No Subset Mac apps are installed.');
  if (updates.length > 0) {
    try {
      prepareTrash(trash);
    } catch (error) {
      fail(`nothing was updated: ${error.message}.`);
      updates.length = 0;
    }
  }

  const controller = new AbortController();
  const stop = (signal) => {
    if (!controller.signal.aborted) controller.abort(new InterruptedError(signal));
  };
  const handlers = Object.keys(SIGNALS).map((signal) => [signal, () => stop(signal)]);
  for (const [signal, handler] of handlers) signals.on(signal, handler);
  try {
    for (const { app, copy, release, identity } of updates) {
      const from = copyLabel(copy);
      const to = releaseLabel(release, options.beta);
      const notUpdated = `${app.name} in ${copy.folder} was not updated to ${to}`;
      let quit = false;
      // Refused before the download when the app runs and --quit is not given; checked again, and quit with --quit,
      // once the new copy is verified, just before the swap.
      const ready = async () => {
        const running = await runningProcesses(copy.path, { tools, signal: controller.signal });
        if (running.length === 0) return;
        if (!options.quit) throw new RunningError(`${app.name} is running (${pids(running)}); quit it, or use subset update --quit to quit and reopen it`);
        quit = true;
        say(stderr, `Quitting ${app.name} (${pids(running)})`);
        const left = await quitProcesses(copy.path, running, { tools, timeoutMs: quitTimeoutMs, signal: controller.signal });
        if (left.length > 0) throw new RunningError(`${app.name} is still running ${quitTimeoutMs / 1000} seconds after it was asked to quit (${pids(left)})`);
      };
      try {
        if (!options.quit) {
          const running = await runningProcesses(copy.path, { tools, signal: controller.signal });
          if (running.length > 0) throw new RunningError(`${app.name} is running (${pids(running)}); quit it, or use subset update --quit to quit and reopen it`);
        }
        const folder = folders.find((candidate) => candidate.label === copy.folder);
        const receipt = receiptFor({ app, release, beta: options.beta, folder, home, now, clock });
        const result = await updateApp({
          app,
          release,
          beta: options.beta,
          target: copy.path,
          identity,
          receipt,
          trash,
          signal: controller.signal,
          fetch,
          tools,
          ready,
          now: () => new Date(clock()),
          log: (line) => say(stderr, line),
          warn: (line) => say(stderr, `subset: warning: ${line}`)
        });
        say(stdout, `Updated ${app.name} ${from} to ${to} in ${result.path}`);
        if (result.trashed) say(stderr, `Moved ${app.name} ${from} to the Trash: ${result.trashed}`);
      } catch (error) {
        if (error instanceof InterruptedError || controller.signal.aborted) {
          say(stderr, `subset: ${notUpdated}: interrupted by ${controller.signal.reason.signal}.`);
          return 128 + SIGNALS[controller.signal.reason.signal];
        }
        if (error instanceof RunningError) fail(`${notUpdated}: ${error.message}.`);
        else {
          const message = failure(error);
          if (message === undefined) throw error;
          fail(`${notUpdated}: ${message}`);
        }
      } finally {
        if (quit) {
          const why = await reopenApp(app.bundleId, { tools });
          if (why) say(stderr, `subset: warning: ${app.name} could not be reopened (open -b ${app.bundleId}: ${why})`);
        }
      }
    }
  } finally {
    for (const [signal, handler] of handlers) signals.off(signal, handler);
  }
  await launcher();
  return failed ? 1 : 0;
}
