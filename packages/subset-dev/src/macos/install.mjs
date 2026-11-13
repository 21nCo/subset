// Installs one Subset Mac app from the catalog feed, only after proving it is ours (SET-230):
//   1. download the channel's DMG over HTTPS into a new private folder (mkdtemp, mode 0700) and check its SHA-256;
//   2. attach it read-only and hidden, and require exactly one .app at the image root, named <appName>.app;
//   3. copy it with ditto to a hidden staging name in the destination folder;
//   4. verify the staged copy (verify.mjs);
//   5. rename it to <appName>.app (never over an existing one) and write the receipt, then detach the image and remove
//      the private folder.
// Any failed step, and a SIGINT, SIGTERM or SIGHUP before step 5 (the caller aborts `signal`), removes the staged copy
// and writes no receipt. Step 5 is synchronous, so no signal handler runs between the rename and the receipt.
import { createHash, randomBytes } from 'node:crypto';
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, renameSync, rmdirSync, rmSync, writeFileSync } from 'node:fs';
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

/** A step refused the app or failed: `check` names it (download, checksum, image, copy, verify, install, receipt). */
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

// Detaches whatever is mounted in `mountRoot` (by `hdiutil attach -mountrandom`), forcing it when a plain detach fails.
// Returns true when nothing is left there.
async function detachAll(mountRoot, hdiutil) {
  let entries;
  try {
    entries = readdirSync(mountRoot);
  } catch (error) {
    return error.code === 'ENOENT';
  }
  let clean = true;
  for (const entry of entries) {
    const mountPoint = path.join(mountRoot, entry);
    const plain = await runTool(hdiutil, ['detach', mountPoint, '-quiet']).catch(() => ({ code: 1 }));
    if (plain.code === 0) continue;
    const forced = await runTool(hdiutil, ['detach', mountPoint, '-force', '-quiet']).catch(() => ({ code: 1 }));
    // A folder -mountrandom made but nothing was mounted on (an interrupted attach) cannot be detached: remove it.
    if (forced.code !== 0) {
      try {
        rmdirSync(mountPoint);
      } catch {
        clean = false;
      }
    }
  }
  return clean;
}

/**
 * Downloads, verifies and installs `app` (a feed app) from `release` (its live or beta channel) into the folder `dir`
 * as <appName>.app. `receipt` is { file, document } to write with the rename, or null. `signal` aborts the install
 * with its reason (an InterruptedError) before the rename. `log` gets progress lines and `warn` what could not be
 * cleaned up. Resolves { path }; rejects with an InstallError, a VerificationError (verify.mjs) or the abort reason,
 * leaving no staged copy and no receipt behind.
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
  let stagedCreated = false;
  let installed = false;
  let step = 'download';
  try {
    checkpoint();
    work = mkdtempSync(path.join(tmpdir(), 'subset-install-'));
    mountRoot = path.join(work, 'mnt');
    mkdirSync(mountRoot, { mode: 0o700 });
    const image = path.join(work, 'image.dmg');

    log(`Downloading ${app.name} ${release.version} from ${release.url}`);
    await downloadImage(release.url, image, release.sha256, { fetch, signal });
    checkpoint();

    step = 'image';
    const attach = await runTool(tools.hdiutil, ['attach', '-readonly', '-nobrowse', '-noautoopen', '-mountrandom', mountRoot, image], { signal });
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
    // world-writable.
    chmodSync(staged, lstatSync(source).mode & 0o755);

    step = 'verify';
    log(`Verifying ${app.appName}.app`);
    await verifyApp(staged, { bundleId: app.bundleId, version: release.version, build: beta ? release.build : undefined }, { tools, signal });

    // Step 5, synchronously: nothing else runs in this process until the app and its receipt are in place.
    step = 'install';
    checkpoint();
    if (exists(target)) throw alreadyThere();
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
    // An unexpected error (a folder that cannot be made or read) still names the step it stopped.
    if (error instanceof InstallError || error instanceof VerificationError || error === signal.reason) throw error;
    throw new InstallError(step, error.code ? `${error.code}: ${error.message}` : String(error?.message ?? error));
  } finally {
    if (stagedCreated && !installed) {
      try {
        rmSync(staged, { recursive: true, force: true });
      } catch (error) {
        warn(`the staged copy ${staged} could not be removed (${error.code ?? error.message}); remove it by hand`);
      }
    }
    if (work !== undefined) {
      const detached = await detachAll(mountRoot, tools.hdiutil);
      if (detached) rmSync(work, { recursive: true, force: true });
      else warn(`the disk image could not be detached; it stays mounted in ${mountRoot}`);
    }
  }
}
