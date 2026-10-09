import { randomBytes } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import type { Platform } from './contract.js';

export interface PathEnvironment {
  platform: NodeJS.Platform;
  home: string;
  env: Record<string, string | undefined>;
}

const currentEnvironment = (): PathEnvironment => ({ platform: process.platform, home: os.homedir(), env: process.env });

/** Where Minutes keeps its Chrome profile and session records. Shared by the CLI and the macOS app. */
export function defaultDataDirectory(environment: PathEnvironment = currentEnvironment()): string {
  const { platform, home, env } = environment;
  if (env.SUBSET_MINUTES_DATA_DIR) return path.resolve(env.SUBSET_MINUTES_DATA_DIR);
  if (platform === 'darwin') return path.join(home, 'Library', 'Application Support', 'Subset Minutes');
  return path.join(env.XDG_DATA_HOME ? path.resolve(env.XDG_DATA_HOME) : path.join(home, '.local', 'share'), 'subset', 'minutes');
}

/** The bot's dedicated Chrome profile. Signing it in to Google lets the bot join Meet as a known user. */
export function defaultProfileDirectory(environment: PathEnvironment = currentEnvironment()): string {
  if (environment.env.SUBSET_MINUTES_PROFILE_DIR) return path.resolve(environment.env.SUBSET_MINUTES_PROFILE_DIR);
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
