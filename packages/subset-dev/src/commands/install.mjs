// subset install <app> [--beta] [--user] [--dir <folder>]: installs a Subset Mac app from the catalog feed after
// checking its checksum, signature, team, notarization, bundle ID, version and minimum macOS (macos/install.mjs). The
// destination is /Applications when it is writable, otherwise ~/Applications (created if missing); --user forces
// ~/Applications and --dir names a folder (for tests). Never asks for administrator rights.
import { accessSync, constants, existsSync, lstatSync, mkdirSync, statSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { CatalogInvalidError, CatalogUnavailableError, loadCatalog, printable, validateReceipt } from '../feed.mjs';
import { ApplicationsFoldersError, applicationsFolders, detectApps, receiptFile } from '../macos/apps.mjs';
import { INSTALL_TOOLS, InstallError, installApp, InterruptedError } from '../macos/install.mjs';
import { compareVersions, VerificationError } from '../macos/verify.mjs';

const USAGE = 'Usage: subset install <app> [--beta] [--user] [--dir <folder>]';
const SIGNALS = { SIGHUP: 1, SIGINT: 2, SIGTERM: 15 };
const VERSION = /^\d+\.\d+\.\d+$/;

/** The arguments of `subset install`: { app, beta, user, dir }, or { error } for anything else. */
export function parseInstallArgs(args) {
  const options = { app: undefined, beta: false, user: false, dir: undefined };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--beta') options.beta = true;
    else if (arg === '--user') options.user = true;
    else if (arg === '--dir') {
      const value = args[(index += 1)];
      if (value === undefined || value === '') return { error: `--dir needs a folder. ${USAGE}` };
      options.dir = value;
    } else if (arg.startsWith('-')) return { error: `subset install does not take the option "${printable(arg)}". ${USAGE}` };
    else if (options.app !== undefined) return { error: `subset install takes one app, not "${printable(options.app)}" and "${printable(arg)}". ${USAGE}` };
    else options.app = arg;
  }
  if (options.app === undefined) return { error: `subset install needs an app; subset list shows them. ${USAGE}` };
  if (options.user && options.dir !== undefined) return { error: `--user and --dir cannot be used together. ${USAGE}` };
  return options;
}

const writable = (dir) => {
  try {
    accessSync(dir, constants.W_OK);
    return statSync(dir).isDirectory();
  } catch {
    return false;
  }
};

const isLink = (file) => {
  try {
    return lstatSync(file).isSymbolicLink();
  } catch {
    return false;
  }
};

// Where the app goes: { dir, folder } where `folder` is the applicationsFolders() entry it is (null for a --dir
// elsewhere, which gets no receipt). Throws an InstallError('destination') when it cannot be used.
function destination(options, folders) {
  if (options.dir !== undefined) {
    const dir = path.resolve(options.dir);
    let isDir = false;
    try {
      isDir = statSync(dir).isDirectory();
    } catch {
      // Reported below.
    }
    if (!isDir) throw new InstallError('destination', `${dir} is not a folder`);
    return { dir, folder: folders.find((folder) => path.resolve(folder.dir) === dir) ?? null };
  }
  const [system, user] = folders;
  if (!options.user && writable(system.dir)) return { dir: system.dir, folder: system };
  try {
    mkdirSync(user.dir, { recursive: true, mode: 0o755 });
  } catch (error) {
    throw new InstallError('destination', `${user.dir} cannot be created (${error.code ?? error.message})`);
  }
  if (!writable(user.dir)) throw new InstallError('destination', `${user.dir} is not a writable folder`);
  return { dir: user.dir, folder: user };
}

// Why installing `release` would be a downgrade of one of the installed copies, or undefined.
function downgrade(copies, release, beta) {
  for (const copy of copies) {
    if (typeof copy.version !== 'string' || !VERSION.test(copy.version)) continue;
    const order = compareVersions(release.version, copy.version);
    const olderBuild = order === 0 && beta && /^\d+$/.test(copy.build ?? '') && Number(copy.build) > release.build;
    if (order < 0 || olderBuild) return `${copy.version}${olderBuild ? ` (build ${copy.build})` : ''} is installed in ${copy.folder}`;
  }
  return undefined;
}

// The subset.receipt@1 receipt for the install, or null when the destination is not /Applications or ~/Applications
// (or a path the receipt schema cannot hold, such as a home folder outside /Users).
function receiptFor({ app, release, beta, folder, home, now }) {
  if (folder === null) return null;
  const document = {
    schema: 'subset.receipt@1',
    channel: beta ? 'beta' : 'live',
    version: release.version,
    ...(beta ? { build: release.build } : {}),
    sha256: release.sha256,
    installedAt: new Date(now).toISOString().replace(/\.\d{3}Z$/, 'Z'),
    path: path.posix.join(folder.path, `${app.appName}.app`)
  };
  return validateReceipt(document).length === 0 ? { file: receiptFile(home, app.bundleId), document } : null;
}

const failure = (error) => {
  if (error instanceof VerificationError) return `the ${error.check} check failed: ${printable(error.message)}`;
  if (error instanceof InstallError) return `the ${error.check} step failed: ${printable(error.message)}`;
  return undefined;
};

/**
 * Runs `subset install <args>`, writing to `stdout` and `stderr`, and returns the exit code: 0 when the app is
 * installed, 1 when it is not, 2 for a usage error, or 128 + the signal number when a signal stopped it. `signals`
 * is where SIGINT, SIGTERM and SIGHUP are caught while the app is being installed (the process).
 */
export async function runInstall(args, { env, platform, home, stdout, stderr, fetch, now = Date.now(), tools = INSTALL_TOOLS, signals = process }) {
  const options = parseInstallArgs(args);
  if (options.error) {
    stderr.write(`subset: ${options.error}\n`);
    return 2;
  }
  const fail = (message) => {
    stderr.write(`subset: ${message}\n`);
    return 1;
  };
  if (platform !== 'darwin') return fail('Mac apps can be installed only on macOS.');

  let folders;
  let catalog;
  try {
    folders = applicationsFolders({ env, home });
    catalog = await loadCatalog({ env, platform, home, now, fetch });
  } catch (error) {
    if (!(error instanceof CatalogInvalidError || error instanceof CatalogUnavailableError || error instanceof ApplicationsFoldersError)) throw error;
    return fail(error.message);
  }
  if (catalog.warning) stderr.write(`subset: ${catalog.warning}\n`);
  const app = catalog.feed.apps.find((candidate) => candidate.id === options.app);
  if (!app) return fail(`there is no Subset Mac app "${printable(options.app)}"; subset list shows them.`);
  const release = options.beta ? app.channels.beta : app.channels.live;
  if (!release) return fail(options.beta ? `${app.name} has no beta.` : `${app.name} has no live release yet; try subset install ${app.id} --beta`);
  const label = options.beta ? `${app.name} ${release.version}-beta.${release.build}` : `${app.name} ${release.version}`;

  let where;
  try {
    where = destination(options, folders);
  } catch (error) {
    return fail(`${label} was not installed: ${failure(error)}`);
  }
  const target = path.join(where.dir, `${app.appName}.app`);
  if (existsSync(target) || isLink(target)) return fail(`${label} was not installed: ${target} already exists; use subset update to change its version.`);
  const [copies] = await detectApps([app], { folders, home, plutil: tools.plutil });
  const newer = downgrade(copies, release, options.beta);
  if (newer) return fail(`${label} was not installed: ${newer}, and subset install does not downgrade.`);

  const controller = new AbortController();
  const stop = (signal) => {
    if (!controller.signal.aborted) controller.abort(new InterruptedError(signal));
  };
  const handlers = Object.keys(SIGNALS).map((signal) => [signal, () => stop(signal)]);
  for (const [signal, handler] of handlers) signals.on(signal, handler);
  try {
    const receipt = receiptFor({ app, release, beta: options.beta, folder: where.folder, home, now });
    const installed = await installApp({
      app,
      release,
      beta: options.beta,
      dir: where.dir,
      receipt,
      signal: controller.signal,
      fetch,
      tools,
      log: (line) => stderr.write(`${line}\n`),
      warn: (line) => stderr.write(`subset: warning: ${line}\n`)
    });
    stdout.write(`Installed ${label} in ${installed.path}\n`);
    return 0;
  } catch (error) {
    if (error instanceof InterruptedError) {
      stderr.write(`subset: ${label} was not installed: interrupted by ${error.signal}.\n`);
      return 128 + SIGNALS[error.signal];
    }
    const message = failure(error);
    if (message === undefined) throw error;
    return fail(`${label} was not installed: ${message}`);
  } finally {
    for (const [signal, handler] of handlers) signals.off(signal, handler);
  }
}
