import { constants } from 'node:fs';
import { access, lstat, readFile, readlink, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { MINUTES_CONTRACT_VERSION, type DoctorCheck, type MinutesDoctor } from './contract.js';
import { isProcessAlive } from './store.js';

export const MINIMUM_NODE_MAJOR = 22;

export interface DoctorProbe {
  nodeVersion: string;
  platform: NodeJS.Platform;
  home: string;
  env: Record<string, string | undefined>;
  isExecutable: (file: string) => Promise<boolean>;
  exists: (file: string) => Promise<boolean>;
  /** True for a directory this user can create files in (write and search permission). */
  isWritable: (directory: string) => Promise<boolean>;
  readText: (file: string) => Promise<string | null>;
  /** Symlink target, or null. Chrome's SingletonLock points at `<hostname>-<pid>`. */
  readLink?: (file: string) => Promise<string | null>;
  hostname?: string;
  isAlive?: (pid: number) => boolean;
}

export const systemProbe = (): DoctorProbe => ({
  nodeVersion: process.versions.node,
  platform: process.platform,
  home: os.homedir(),
  env: process.env,
  isExecutable: (file) => access(file, constants.X_OK).then(() => true, () => false),
  // lstat, so a dangling symlink such as Chrome's SingletonLock still counts.
  exists: (file) => lstat(file).then(() => true, () => false),
  isWritable: async (directory) => {
    const info = await stat(directory).catch(() => null);
    if (!info?.isDirectory()) return false;
    return access(directory, constants.W_OK | constants.X_OK).then(() => true, () => false);
  },
  readText: (file) => readFile(file, 'utf8').catch(() => null),
  readLink: (file) => readlink(file).catch(() => null),
  hostname: os.hostname(),
  isAlive: isProcessAlive,
});

/**
 * Whether Chrome holds the profile. A `SingletonLock` left by a crashed Chrome on this host, whose process
 * is gone, does not count: Chrome replaces it on the next launch.
 */
async function profileInUse(profileDirectory: string, probe: DoctorProbe): Promise<boolean> {
  const lock = path.join(profileDirectory, 'SingletonLock');
  if (!(await probe.exists(lock))) return false;
  const target = probe.readLink ? await probe.readLink(lock) : null;
  const match = target?.match(/^(.*)-(\d+)$/);
  if (!match || !probe.hostname || !probe.isAlive || match[1] !== probe.hostname) return true;
  return probe.isAlive(Number(match[2]));
}

export function chromeCandidates(platform: NodeJS.Platform, home: string): string[] {
  if (platform === 'darwin') {
    return [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      path.join(home, 'Applications/Google Chrome.app/Contents/MacOS/Google Chrome'),
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
    ];
  }
  if (platform === 'win32') {
    return [
      'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
      'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    ];
  }
  return ['/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser'];
}

/** `SUBSET_MINUTES_CHROME_PATH` wins; otherwise the first installed Chrome or Chromium. */
export async function findChrome(probe: DoctorProbe = systemProbe()): Promise<string | null> {
  const override = probe.env.SUBSET_MINUTES_CHROME_PATH;
  if (override) return (await probe.isExecutable(override)) ? path.resolve(override) : null;
  for (const candidate of chromeCandidates(probe.platform, probe.home)) {
    if (await probe.isExecutable(candidate)) return candidate;
  }
  return null;
}

/**
 * Whether Chrome's `Local State` lists a Google account for the profile's Default user. Only the
 * presence of a name is checked; the account itself is never returned or printed.
 */
export async function profileHasGoogleAccount(profileDirectory: string, probe: DoctorProbe): Promise<boolean> {
  const text = await probe.readText(path.join(profileDirectory, 'Local State'));
  if (!text) return false;
  try {
    const state = JSON.parse(text) as { profile?: { info_cache?: Record<string, { user_name?: unknown }> } };
    const userName = state.profile?.info_cache?.Default?.user_name;
    return typeof userName === 'string' && userName.length > 0;
  } catch {
    return false;
  }
}

async function nearestExisting(directory: string, probe: DoctorProbe): Promise<string> {
  let current = path.resolve(directory);
  while (!(await probe.exists(current))) {
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return current;
}

export interface DoctorOptions {
  profileDirectory: string;
  outputDirectory: string;
  now?: Date;
}

export async function runDoctor(options: DoctorOptions, probe: DoctorProbe = systemProbe()): Promise<MinutesDoctor> {
  const checks: DoctorCheck[] = [];
  const major = Number(probe.nodeVersion.split('.')[0]);
  checks.push({
    id: 'node',
    ok: major >= MINIMUM_NODE_MAJOR,
    required: true,
    detail: `Node.js ${probe.nodeVersion}`,
    fix: major >= MINIMUM_NODE_MAJOR ? null : `Install Node.js ${MINIMUM_NODE_MAJOR} or later.`,
  });

  const chromePath = await findChrome(probe);
  checks.push({
    id: 'chrome',
    ok: chromePath !== null,
    required: true,
    detail: chromePath ?? (probe.env.SUBSET_MINUTES_CHROME_PATH ? 'SUBSET_MINUTES_CHROME_PATH is not an executable file.' : 'Google Chrome or Chromium was not found.'),
    fix: chromePath ? null : 'Install Google Chrome from https://www.google.com/chrome/ or set SUBSET_MINUTES_CHROME_PATH.',
  });

  const profileExists = await probe.exists(options.profileDirectory);
  const signedIn = profileExists && (await profileHasGoogleAccount(options.profileDirectory, probe));
  checks.push({
    id: 'profile',
    ok: signedIn,
    required: false,
    detail: signedIn
      ? 'The bot profile has a Google account signed in (account not shown).'
      : profileExists
        ? 'The bot profile exists but no Google account is signed in. Meet will treat the bot as a guest.'
        : 'No bot profile yet. Meet will treat the bot as a guest. Zoom does not use it.',
    fix: signedIn ? null : 'Run `subset-minutes sign-in` and sign in with the bot\'s Google account, then quit that Chrome window.',
  });

  const locked = profileExists && (await profileInUse(options.profileDirectory, probe));
  checks.push({
    id: 'profile_lock',
    ok: !locked,
    required: false,
    detail: locked ? 'Chrome has the bot profile open, so a Meet join will fail.' : 'The bot profile is not in use.',
    fix: locked ? 'Quit the Chrome window that uses the bot profile (for example the sign-in window).' : null,
  });

  const existing = await nearestExisting(options.outputDirectory, probe);
  const writable = await probe.isWritable(existing);
  checks.push({
    id: 'output_directory',
    ok: writable,
    required: true,
    detail: writable ? `Recordings go to ${options.outputDirectory}.` : `${existing} is not a folder you can write to.`,
    fix: writable ? null : 'Choose another folder with --out.',
  });

  return {
    v: MINUTES_CONTRACT_VERSION,
    kind: 'minutes.doctor',
    observedAt: (options.now ?? new Date()).toISOString(),
    ok: checks.every((check) => check.ok || !check.required),
    chromePath,
    profileDirectory: options.profileDirectory,
    outputDirectory: options.outputDirectory,
    checks,
  };
}
