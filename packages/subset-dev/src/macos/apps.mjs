// Which Subset Mac apps are installed (decision D2 of SET-224): for each app in the catalog feed, `<appName>.app` at the
// top level of /Applications and ~/Applications, accepted only when its Info.plist's CFBundleIdentifier is the feed's
// bundleId. Its version is CFBundleShortVersionString and its build CFBundleVersion. An install receipt
// (~/Library/Application Support/Subset/receipts/<bundleId>.json, subset.receipt@1) is advisory: when it is valid and
// describes that copy, its channel is shown. Apps elsewhere (another folder, a subfolder, a symbolic link) are not
// detected.
import { execFile } from 'node:child_process';
import { lstat } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import { readBounded, validateReceipt } from '../feed.mjs';

const run = promisify(execFile);
export const PLUTIL = '/usr/bin/plutil';
const PLUTIL_TIMEOUT_MS = 10_000;
const MAX_PLIST_JSON_BYTES = 1024 * 1024;
const MAX_RECEIPT_BYTES = 64 * 1024;

/** SUBSET_APPLICATIONS_DIRS is not two absolute folders. */
export class ApplicationsFoldersError extends Error {}

/**
 * The folders apps are looked for in, in this order: { label, path, dir }. `path` is the folder as receipts name it
 * (/Applications, <home>/Applications) and `dir` the one searched. SUBSET_APPLICATIONS_DIRS (tests only) replaces the
 * two searched folders with two absolute folders separated by the path delimiter, which stand in for them.
 */
export function applicationsFolders({ env, home }) {
  const folders = [
    { label: '/Applications', path: '/Applications' },
    { label: '~/Applications', path: path.posix.join(home, 'Applications') }
  ];
  const override = env.SUBSET_APPLICATIONS_DIRS;
  if (override === undefined || override === '') return folders.map((folder) => ({ ...folder, dir: folder.path }));
  const dirs = override.split(path.delimiter);
  if (dirs.length !== 2 || !dirs.every((dir) => path.isAbsolute(dir))) {
    throw new ApplicationsFoldersError(`SUBSET_APPLICATIONS_DIRS must be two absolute folders separated by "${path.delimiter}"`);
  }
  return folders.map((folder, index) => ({ ...folder, dir: dirs[index] }));
}

/** Where the install receipt of an app is kept. The bundle ID comes from a validated feed, so it has no / or .. part. */
export const receiptFile = (home, bundleId) => path.join(home, 'Library', 'Application Support', 'Subset', 'receipts', `${bundleId}.json`);

// A valid receipt, or undefined when there is none or it is unreadable or invalid (a receipt never blocks anything).
function readReceipt(file) {
  try {
    const bytes = readBounded(file, MAX_RECEIPT_BYTES);
    if (bytes.byteLength > MAX_RECEIPT_BYTES) return undefined;
    const receipt = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    return validateReceipt(receipt).length === 0 ? receipt : undefined;
  } catch {
    return undefined;
  }
}

// The receipt's channel when it describes this copy: the same .app path, version and, for a beta, build.
function channelOf(receipt, logicalPath, copy) {
  if (!receipt || receipt.path !== logicalPath || receipt.version !== copy.version) return null;
  if (receipt.channel === 'beta' && String(receipt.build) !== copy.build) return null;
  return receipt.channel;
}

/**
 * The Info.plist of an app bundle as JSON, or undefined when the bundle, its Contents folder or its Info.plist is not a
 * plain directory, directory and file (a symbolic link at any of them could name a plist outside the bundle), or plutil
 * cannot read it. `subset install` reads the staged copy's with it too (verify.mjs).
 */
export async function readInfoPlist(bundle, plutil) {
  try {
    if (!(await lstat(bundle)).isDirectory()) return undefined;
    const contents = path.join(bundle, 'Contents');
    if (!(await lstat(contents)).isDirectory()) return undefined;
    const file = path.join(contents, 'Info.plist');
    if (!(await lstat(file)).isFile()) return undefined;
    const { stdout } = await run(plutil, ['-convert', 'json', '-o', '-', file], { encoding: 'utf8', timeout: PLUTIL_TIMEOUT_MS, maxBuffer: MAX_PLIST_JSON_BYTES });
    const info = JSON.parse(stdout);
    return typeof info === 'object' && info !== null && !Array.isArray(info) ? info : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The installed copies of each feed app, as an array per app in feed order: [{ path, folder, version, build, channel }],
 * where `folder` is /Applications or ~/Applications, `version` and `build` come from Info.plist (null when missing) and
 * `channel` is live or beta from a matching receipt, otherwise null.
 */
export async function detectApps(apps, { folders, home, plutil = PLUTIL }) {
  return Promise.all(
    apps.map(async (app) => {
      const receipt = readReceipt(receiptFile(home, app.bundleId));
      const copies = await Promise.all(
        folders.map(async (folder) => {
          const bundle = path.join(folder.dir, `${app.appName}.app`);
          const info = await readInfoPlist(bundle, plutil);
          if (info?.CFBundleIdentifier !== app.bundleId) return undefined;
          const text = (value) => (typeof value === 'string' ? value : null);
          const copy = { path: bundle, folder: folder.label, version: text(info.CFBundleShortVersionString), build: text(info.CFBundleVersion) };
          return { ...copy, channel: channelOf(receipt, path.posix.join(folder.path, `${app.appName}.app`), copy) };
        })
      );
      return copies.filter(Boolean);
    })
  );
}
