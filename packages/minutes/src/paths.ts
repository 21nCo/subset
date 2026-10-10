import { randomBytes } from 'node:crypto';
import { open } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import type { Platform } from './contract.js';

export interface PathEnvironment {
  platform: NodeJS.Platform;
  home: string;
  env: Record<string, string | undefined>;
}

const currentEnvironment = (): PathEnvironment => ({ platform: process.platform, home: os.homedir(), env: process.env });

/** Resolves a directory from the environment, expanding a leading `~` the shell did not expand. */
const resolveFromEnvironment = (value: string, home: string) =>
  path.resolve(value === '~' ? home : value.startsWith('~/') ? path.join(home, value.slice(2)) : value);

/** Where Minutes keeps its Chrome profile and session records. Shared by the CLI and the macOS app. */
export function defaultDataDirectory(environment: PathEnvironment = currentEnvironment()): string {
  const { platform, home, env } = environment;
  if (env.SUBSET_MINUTES_DATA_DIR) return resolveFromEnvironment(env.SUBSET_MINUTES_DATA_DIR, home);
  if (platform === 'darwin') return path.join(home, 'Library', 'Application Support', 'Subset Minutes');
  return path.join(env.XDG_DATA_HOME ? resolveFromEnvironment(env.XDG_DATA_HOME, home) : path.join(home, '.local', 'share'), 'subset', 'minutes');
}

/** The bot's dedicated Chrome profile. Signing it in to Google lets the bot join Meet as a known user. */
export function defaultProfileDirectory(environment: PathEnvironment = currentEnvironment()): string {
  if (environment.env.SUBSET_MINUTES_PROFILE_DIR) return resolveFromEnvironment(environment.env.SUBSET_MINUTES_PROFILE_DIR, environment.home);
  return path.join(defaultDataDirectory(environment), 'google-meet-bot-profile');
}

export function defaultStateDirectory(environment: PathEnvironment = currentEnvironment()): string {
  return path.join(defaultDataDirectory(environment), 'sessions');
}

export function defaultOutputDirectory(environment: PathEnvironment = currentEnvironment()): string {
  return path.join(environment.home, 'Documents', 'Minutes Recordings');
}

/** A sortable, unique session id: UTC time plus random suffix, e.g. `20261009T101500Z-a1b2c3`. */
export function createSessionId(now: Date = new Date(), random: () => string = () => randomBytes(3).toString('hex')): string {
  const stamp = now.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  return `${stamp}-${random()}`;
}

/**
 * The recording file name: `minutes-<platform>-<YYYY-MM-DD>T<HH-MM-SS>Z.webm` in UTC.
 * The meeting code is left out so a shared folder listing does not reveal which meeting it was.
 */
export function recordingFileName(platform: Platform, startedAt: Date, attempt = 0): string {
  const stamp = startedAt.toISOString().replace(/\.\d{3}Z$/, 'Z').replace(/:/g, '-');
  return `minutes-${platform}-${stamp}${attempt > 0 ? `-${attempt + 1}` : ''}.webm`;
}

/** Picks the first recording path in `directory` that `exists` reports as free. */
export async function resolveRecordingPath(
  directory: string,
  platform: Platform,
  startedAt: Date,
  exists: (file: string) => Promise<boolean>,
): Promise<string> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const candidate = path.join(directory, recordingFileName(platform, startedAt, attempt));
    if (!(await exists(candidate))) return candidate;
  }
  throw new Error(`Could not find a free recording file name in ${directory}.`);
}

/**
 * Creates the recording file (empty, mode 0600) under the first free name and returns its path. Creating
 * it with `wx` reserves the name atomically, so two sessions started in the same second never share a file.
 */
export async function reserveRecordingPath(directory: string, platform: Platform, startedAt: Date): Promise<string> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const candidate = path.join(directory, recordingFileName(platform, startedAt, attempt));
    try {
      await (await open(candidate, 'wx', 0o600)).close();
      return candidate;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
    }
  }
  throw new Error(`Could not find a free recording file name in ${directory}.`);
}
