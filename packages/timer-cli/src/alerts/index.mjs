import { accessSync, constants } from 'node:fs';
import { delimiter, isAbsolute, join } from 'node:path';
import { createLinuxSink } from './linux.mjs';
import { AFPLAY, OSASCRIPT, createMacosSink } from './macos.mjs';
import { defaultSpawn } from './process.mjs';
import { createSilentSink } from './silent.mjs';

export { createLinuxSink, createMacosSink, createSilentSink };

function isExecutable(path) {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function fileExists(path) {
  try {
    accessSync(path, constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

/** The absolute path of `name` in an absolute directory on `PATH`, or null. */
export function findOnPath(name, env, executable = isExecutable) {
  for (const directory of String(env.PATH ?? '').split(delimiter)) {
    if (!directory || !isAbsolute(directory)) continue;
    const candidate = join(directory, name);
    if (executable(candidate)) return candidate;
  }
  return null;
}

/**
 * The sink `daemon run` uses: macOS with `afplay` and `osascript`, Linux with `notify-send` or
 * `paplay` on `PATH`, else silent (`unavailable`). `SUBSET_TIMER_ALERTS=off` makes it silent (`off`).
 */
export function selectSink({ platform = process.platform, env = process.env, spawn = defaultSpawn, executable = isExecutable, soundExists = fileExists } = {}) {
  if (env.SUBSET_TIMER_ALERTS === 'off') return createSilentSink({ name: 'off' });
  if (platform === 'darwin' && executable(AFPLAY) && executable(OSASCRIPT)) return createMacosSink({ spawn });
  if (platform === 'linux') {
    const notifySend = findOnPath('notify-send', env, executable);
    const paplay = findOnPath('paplay', env, executable);
    if (notifySend || paplay) return createLinuxSink({ notifySend, paplay, spawn, soundExists });
  }
  return createSilentSink();
}
