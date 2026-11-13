// Installs one Subset Mac app from the catalog feed, only after proving it is ours (SET-230):
//   1. download the channel's DMG over HTTPS into a new private folder (mkdtemp, mode 0700) and check its SHA-256;
//   2. attach it read-only and hidden, and require exactly one .app at the image root, named <appName>.app;
//   3. copy it with ditto to a hidden staging name in the destination folder;
//   4. verify the staged copy (verify.mjs);
//   5. rename it to <appName>.app (never over an existing one) and write the receipt, then detach the image and remove
//      the private folder.
// Any failed step, and a SIGINT, SIGTERM or SIGHUP before step 5 (the caller aborts `signal`), removes the staged copy
// and writes no receipt. Step 5 is synchronous, so no signal handler runs between the rename and the receipt. A tool
// that is running when the install is aborted is stopped, and the cleanup starts only once it has exited (runTool).
// The cleanup itself is never aborted: it detaches the image by its device, found both in hdiutil attach's output and
// in hdiutil info (an attach stopped part-way prints nothing), and removes the private folder only when the image is
// no longer attached.
import { createHash, randomBytes } from 'node:crypto';
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, renameSync, rmdirSync, rmSync, writeFileSync } from 'node:fs';
import { open } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { runTool, VerificationError, VERIFY_TOOLS, verifyApp } from './verify.mjs';

/** Every download URL starts with this (catalog decision); the feed schema enforces it too. */
export const DOWNLOAD_PREFIX = 'https://github.com/21nCo/subset/releases/download/';
export const INSTALL_TOOLS = Object.freeze({ ...VERIFY_TOOLS, hdiutil: '/usr/bin/hdiutil', ditto: '/usr/bin/ditto' });
export const MAX_IMAGE_BYTES = 1024 ** 3;
const MAX_REDIRECTS = 5;
const STALL_MS = 60_000;
const COPY_TIMEOUT_MS = 10 * 60 * 1000;
const REDIRECTS = new Set([301, 302, 303, 307, 308]);
const DETACH_ATTEMPTS = 3;
const DETACH_RETRY_MS = 1000;

/**
 * A step refused the app or failed: `check` names it (destination, download, checksum, image, copy, verify, install,
 * receipt).
 */
export class InstallError extends Error {
  constructor(check, message) {
    super(message);
    this.check = check;
  }
}

/** The install was stopped by a signal before anything was installed. */
export class InterruptedError extends Error {
  constructor(signal) {
    super(`interrupted by ${signal}`);
    this.signal = signal;
  }
}

const exists = (file) => {
  try {
    lstatSync(file);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
};

// Streams the image at `url` into `file` (created, mode 0600), following at most 5 redirects, each to an https: URL,
// and checks that its SHA-256 is `sha256`. Stops when a read stalls for 60 s or the image passes MAX_IMAGE_BYTES.
async function downloadImage(url, file, sha256, { fetch, signal }) {
  if (!url.startsWith(DOWNLOAD_PREFIX)) throw new InstallError('download', `the feed's download URL is not a ${DOWNLOAD_PREFIX} URL`);
  const stall = new AbortController();
  let timer;
  const wait = () => {
    clearTimeout(timer);
    timer = setTimeout(() => stall.abort(new InstallError('download', `no data for ${STALL_MS / 1000} seconds`)), STALL_MS);
  };
  const both = AbortSignal.any([signal, stall.signal]);
  const failed = (error) => {
    if (signal.aborted) return signal.reason;
    if (stall.signal.aborted) return stall.signal.reason;
    return error instanceof InstallError ? error : new InstallError('download', error?.cause?.code ?? error?.message ?? String(error));
  };
  const handle = await open(file, 'wx', 0o600);
  try {
    let current = new URL(url);
    let response;
    for (let hop = 0; ; hop += 1) {
      wait();
      response = await fetch(current, { redirect: 'manual', signal: both, headers: { accept: 'application/octet-stream' } });
      if (!REDIRECTS.has(response.status)) break;
      await response.body?.cancel().catch(() => {});
      const location = response.headers.get('location');
      const next = location ? new URL(location, current) : undefined;
      if (hop >= MAX_REDIRECTS) throw new InstallError('download', `more than ${MAX_REDIRECTS} redirects`);
      if (next?.protocol !== 'https:') throw new InstallError('download', `redirected to a URL that is not https: (${next?.protocol ?? 'none'})`);
      current = next;
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw new InstallError('download', `HTTP ${response.status}`);
    }
    const hash = createHash('sha256');
    let size = 0;
    for await (const chunk of response.body ?? []) {
      wait();
      size += chunk.byteLength;
      if (size > MAX_IMAGE_BYTES) throw new InstallError('download', `the image is larger than ${MAX_IMAGE_BYTES} bytes`);
      hash.update(chunk);
      await handle.write(chunk);
    }
    const digest = hash.digest('hex');
    if (digest !== sha256) throw new InstallError('checksum', `the download's SHA-256 is ${digest}, not ${sha256} as the feed lists`);
  } catch (error) {
    throw failed(error);
  } finally {
    clearTimeout(timer);
    await handle.close();
  }
}

// The one volume the image mounted in `mountRoot`, and in it the one app, which must be `<appName>.app`.
function findApp(mountRoot, appName) {
  const volumes = readdirSync(mountRoot);
  if (volumes.length !== 1) throw new InstallError('image', `the image mounted ${volumes.length} volumes, not one`);
  const volume = path.join(mountRoot, volumes[0]);
  const apps = readdirSync(volume).filter((name) => name.toLowerCase().endsWith('.app'));
  const expected = `${appName}.app`;
  if (apps.length !== 1) throw new InstallError('image', `the image holds ${apps.length} apps at its root, not exactly one (${expected})`);
  if (apps[0] !== expected) throw new InstallError('image', `the image holds ${JSON.stringify(apps[0])}, not ${expected}`);
  const source = path.join(volume, expected);
  if (!lstatSync(source).isDirectory()) throw new InstallError('image', `${expected} in the image is not a folder`);
  return source;
}

// The whole-disk devices (/dev/diskN) in hdiutil's output: attach's table, or one image's section of `hdiutil info`.
const wholeDisks = (text) => [...text.matchAll(/^(\/dev\/disk\d+)\s/gm)].map((match) => match[1]);

// The devices `hdiutil info` lists for the image file named by any of `imagePaths` (the path it was attached with and
// its real path), or undefined when hdiutil info fails.
async function devicesOf(imagePaths, hdiutil) {
  const info = await runTool(hdiutil, ['info']).catch(() => undefined);
  if (info?.code !== 0) return undefined;
  const devices = [];
  for (const section of info.stdout.split(/^=+$/m)) {
    const named = [...section.matchAll(/^image-(?:path|alias)\s*:\s*(.*)$/gm)].map((match) => match[1].trim());
    if (named.some((name) => imagePaths.has(name))) devices.push(...wholeDisks(section));
  }
  return devices;
}

// Detaches the image file named by `imagePaths` wherever it is attached, by device: first the devices hdiutil attach
// reported, then whatever hdiutil info still lists for it, plainly and then forced, up to DETACH_ATTEMPTS times.
// Returns true when hdiutil info lists none of its devices any more.
async function detachImage(imagePaths, attached, hdiutil) {
  let devices = attached;
  for (let attempt = 0; ; attempt += 1) {
    for (const device of new Set(devices)) {
      const plain = await runTool(hdiutil, ['detach', device, '-quiet']).catch(() => ({ code: 1 }));
      if (plain.code !== 0) await runTool(hdiutil, ['detach', device, '-force', '-quiet']).catch(() => {});
    }
    devices = await devicesOf(imagePaths, hdiutil);
    if (devices?.length === 0) return true;
    if (attempt + 1 >= DETACH_ATTEMPTS) return false;
    await new Promise((resolve) => setTimeout(resolve, DETACH_RETRY_MS));
    devices ??= [];
  }
}

// Removes the private folder once nothing is attached from it: the mount folders hdiutil made (each must be empty, so
// nothing still mounted is touched), then the rest. Returns why it could not, or undefined.
function removeWork(work, mountRoot) {
  try {
    const entries = exists(mountRoot) ? readdirSync(mountRoot) : [];
    for (const entry of entries) rmdirSync(path.join(mountRoot, entry));
    rmSync(work, { recursive: true, force: true });
    return undefined;
  } catch (error) {
    return error.code ?? error.message;
  }
}

// Removes the installer's staged copy. ditto keeps the image's permissions, so a folder in it can be read-only, and
// removing what is in a folder needs write permission on it: each folder (never a symbolic link) is first made
// writable by its owner. Throws when it cannot be removed.
function removeStaged(staged) {
  const pending = [staged];
  while (pending.length > 0) {
    const dir = pending.pop();
    let stat;
    try {
      stat = lstatSync(dir);
    } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    if (!stat.isDirectory()) continue;
    if ((stat.mode & 0o700) !== 0o700) chmodSync(dir, (stat.mode & 0o7777) | 0o700);
    for (const name of readdirSync(dir)) pending.push(path.join(dir, name));
  }
  rmSync(staged, { recursive: true, force: true });
}

/**
 * Downloads, verifies and installs `app` (a feed app) from `release` (its live or beta channel) into the folder `dir`
 * as <appName>.app. `receipt` is { file, document } to write with the rename, or null. `signal` aborts the install
 * with its reason (an InterruptedError) before the rename; once the app is renamed into place, an abort changes nothing
 * and the install resolves. `log` gets progress lines and `warn` what could not be cleaned up. Resolves { path };
 * rejects with an InstallError, a VerificationError (verify.mjs) or the abort reason, leaving no staged copy and no
 * receipt behind.
 */
export async function installApp({ app, release, beta, dir, receipt, signal, fetch = globalThis.fetch, tools = INSTALL_TOOLS, log = () => {}, warn = () => {} }) {
  const checkpoint = () => {
    if (signal.aborted) throw signal.reason;
  };
  const target = path.join(dir, `${app.appName}.app`);
  const staged = path.join(dir, `.${app.appName}.app.subset-install-${randomBytes(6).toString('hex')}`);
  const alreadyThere = () => new InstallError('install', `${target} already exists; use subset update to change its version`);
  let work;
  let mountRoot;
  let image;
  let imagePaths;
  let attached = [];
  let stagedCreated = false;
  let installed = false;
  let step = 'download';
  try {
    checkpoint();
    work = mkdtempSync(path.join(tmpdir(), 'subset-install-'));
    mountRoot = path.join(work, 'mnt');
    mkdirSync(mountRoot, { mode: 0o700 });
    image = path.join(work, 'image.dmg');
    // hdiutil info names an image by the path it was attached with, and by its real path (/private/var/... for /var/...).
    imagePaths = new Set([image, path.join(realpathSync(work), 'image.dmg')]);

    log(`Downloading ${app.name} ${release.version} from ${release.url}`);
    await downloadImage(release.url, image, release.sha256, { fetch, signal });
    checkpoint();

    step = 'image';
    const attach = await runTool(tools.hdiutil, ['attach', '-readonly', '-nobrowse', '-noautoopen', '-mountrandom', mountRoot, image], { signal });
    attached = wholeDisks(attach.stdout);
    checkpoint();
    if (attach.code !== 0) throw new InstallError('image', `hdiutil could not attach the image (${attach.stderr.trim().split('\n').at(-1) || `exit ${attach.code}`})`);
    const source = findApp(mountRoot, app.appName);

    step = 'copy';
    if (exists(target)) throw alreadyThere();
    mkdirSync(staged, { mode: 0o700 });
    stagedCreated = true;
    const copy = await runTool(tools.ditto, [source, staged], { signal, timeout: COPY_TIMEOUT_MS });
    checkpoint();
    if (copy.code !== 0) throw new InstallError('copy', `ditto could not copy ${app.appName}.app into ${dir} (${copy.stderr.trim().split('\n').at(-1) || `exit ${copy.code}`})`);
    // ditto keeps the staging folder's 0700; the installed app gets the image's permissions, never group- or
    // world-writable, once it has passed verification (a read-only copy would be harder to remove).
    const mode = lstatSync(source).mode & 0o755;

    step = 'verify';
    log(`Verifying ${app.appName}.app`);
    await verifyApp(staged, { bundleId: app.bundleId, version: release.version, build: beta ? release.build : undefined }, { tools, signal });

    // Step 5, synchronously: nothing else runs in this process until the app and its receipt are in place.
    step = 'install';
    checkpoint();
    if (exists(target)) throw alreadyThere();
    chmodSync(staged, mode);
    let receiptTemporary;
    if (receipt) {
      try {
        mkdirSync(path.dirname(receipt.file), { recursive: true });
        receiptTemporary = `${receipt.file}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
        writeFileSync(receiptTemporary, `${JSON.stringify(receipt.document, null, 2)}\n`, { mode: 0o644, flag: 'wx' });
      } catch (error) {
        if (receiptTemporary) rmSync(receiptTemporary, { force: true });
        throw new InstallError('receipt', `the receipt ${receipt.file} cannot be written (${error.code ?? error.message})`);
      }
    }
    try {
      // rename(2) fails when the target is a file or a folder that is not empty, so a concurrent install that renamed
      // its copy first wins and this one fails.
      renameSync(staged, target);
    } catch (error) {
      if (receiptTemporary) rmSync(receiptTemporary, { force: true });
      if (['EEXIST', 'ENOTEMPTY', 'ENOTDIR', 'EISDIR'].includes(error.code)) throw alreadyThere();
      throw new InstallError('install', `${app.appName}.app cannot be renamed into place (${error.code ?? error.message})`);
    }
    installed = true;
    if (receiptTemporary) {
      try {
        renameSync(receiptTemporary, receipt.file);
      } catch (error) {
        // Put the app back where it was staged, so the finally block removes it: no app without its receipt.
        rmSync(receiptTemporary, { force: true });
        let rolledBack = true;
        try {
          renameSync(target, staged);
          installed = false;
        } catch {
          rolledBack = false;
        }
        const reason = `the receipt ${receipt.file} cannot be written (${error.code ?? error.message})`;
        throw new InstallError('receipt', rolledBack ? reason : `${reason}, and ${target} could not be taken back out; remove it by hand`);
      }
    }
    return { path: target };
  } catch (error) {
    // Whatever check saw a tool stopped by the abort, an abort before the app is in place is the interruption.
    if (signal.aborted && !installed) throw signal.reason;
    // An unexpected error (a folder that cannot be made or read) still names the step it stopped.
    if (error instanceof InstallError || error instanceof VerificationError || error === signal.reason) throw error;
    throw new InstallError(step, error.code ? `${error.code}: ${error.message}` : String(error?.message ?? error));
  } finally {
    // A signal from here on changes nothing: the caller's handlers stay in place, and the tools below are not aborted.
    if (stagedCreated && !installed) {
      try {
        removeStaged(staged);
      } catch (error) {
        warn(`the staged copy ${staged} could not be removed (${error.code ?? error.message}); remove it by hand`);
      }
    }
    if (work !== undefined) {
      const detached = imagePaths === undefined || (await detachImage(imagePaths, attached, tools.hdiutil));
      if (!detached) warn(`the disk image ${image} could not be detached; it stays attached, with the folder ${work}`);
      else {
        const failed = removeWork(work, mountRoot);
        if (failed) warn(`the folder ${work} could not be removed (${failed}); remove it by hand`);
      }
    }
  }
}
