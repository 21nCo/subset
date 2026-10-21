import { chmodSync, lstatSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, join, resolve } from 'node:path';

/** The longest Unix socket path every supported platform accepts (macOS allows 103 bytes plus the terminator). */
export const MAX_SOCKET_PATH_BYTES = 103;

/** `SUBSET_TIMER_DATA_DIR`, else `~/.local/share/subset/timer`. */
export function resolveDataDir(env = process.env) {
  const override = env.SUBSET_TIMER_DATA_DIR;
  if (override) return isAbsolute(override) ? override : resolve(override);
  return join(homedir(), '.local', 'share', 'subset', 'timer');
}

/** Every file the daemon owns in its data directory. */
export function daemonPaths(dataDir) {
  return {
    dataDir,
    state: join(dataDir, 'state.json'),
    scheduler: join(dataDir, 'scheduler.json'),
    lock: join(dataDir, 'daemon.lock'),
    socket: join(dataDir, 'daemon.sock'),
    log: join(dataDir, 'daemon.log')
  };
}

export class DataDirError extends Error {
  constructor(message) {
    super(message);
    this.name = 'DataDirError';
  }
}

/** Throws `DataDirError` when `dataDir` puts `daemon.sock` beyond `MAX_SOCKET_PATH_BYTES`. */
export function checkSocketPath(dataDir) {
  const { socket } = daemonPaths(dataDir);
  if (Buffer.byteLength(socket) > MAX_SOCKET_PATH_BYTES) {
    throw new DataDirError(`The socket path ${socket} is longer than ${MAX_SOCKET_PATH_BYTES} bytes; set SUBSET_TIMER_DATA_DIR to a shorter directory.`);
  }
}

/**
 * Creates the data directory with mode 0700, or tightens an existing one to 0700. Refuses a
 * directory another user owns, a symbolic link, or a path too long for its socket, so only the
 * owning user can reach `daemon.sock`.
 */
export function ensureDataDir(dataDir) {
  checkSocketPath(dataDir);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const stat = lstatSync(dataDir);
  if (!stat.isDirectory()) throw new DataDirError(`${dataDir} is not a directory.`);
  if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
    throw new DataDirError(`${dataDir} belongs to another user.`);
  }
  if ((stat.mode & 0o777) !== 0o700) chmodSync(dataDir, 0o700);
  return daemonPaths(dataDir);
}
