import { copyFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { main } from '../../src/commands/index.mjs';
import { createClient, createFakeClock } from '../../src/daemon/index.mjs';
import { startTestDaemon, tempDataDir } from '../daemon/helpers.mjs';

export const FIXTURES = fileURLToPath(new URL('../../../timer/fixtures/contract-v1/', import.meta.url));
/** `now` of every SET-74 contract fixture: 2026-10-19T09:00:00Z. */
export const FIXTURE_NOW = 1_792_400_400_000;
export const PACKAGE_ROOT = fileURLToPath(new URL('../../', import.meta.url));

/** A spawn that fails the test: a client bound to a running test daemon must never start another. */
export function refuseSpawn() {
  throw new Error('The client tried to spawn a daemon.');
}

/** An in-process daemon on a fake clock with a recording sink, optionally loaded with the SET-74 fixture store. */
export async function cliDaemon(t, { fixture = false, now = FIXTURE_NOW, ...options } = {}) {
  const dataDir = tempDataDir(t);
  if (fixture) {
    mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    copyFileSync(join(FIXTURES, 'store.json'), join(dataDir, 'state.json'));
  }
  const daemon = await startTestDaemon(t, { dataDir, clock: createFakeClock(now), ...options });
  const client = createClient({ dataDir, spawn: refuseSpawn });
  return { ...daemon, client, run: (argv, io) => runCli(argv, { client, now: () => daemon.clock.now(), ...io }) };
}

/** Runs `subset-timer <argv>` in-process and captures its exit status and output. */
export async function runCli(argv, io = {}) {
  let stdout = '';
  let stderr = '';
  const code = await main({
    argv,
    env: { SUBSET_TIMER_ALERTS: 'off' },
    stdout: (text) => {
      stdout += text;
    },
    stderr: (text) => {
      stderr += text;
    },
    cliPath: join(PACKAGE_ROOT, 'src/cli.mjs'),
    packageRoot: PACKAGE_ROOT,
    ...io
  });
  return { code, stdout, stderr, json: () => JSON.parse(stdout) };
}
