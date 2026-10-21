import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { selectSink } from '../alerts/index.mjs';
import { resolveDataDir } from '../daemon/paths.mjs';
import { DaemonRunningError, runInForeground, startDaemon as startDaemonServer } from '../daemon/server.mjs';
import { CliError } from './shared.mjs';

/** How long `daemon stop` waits for the daemon to close its socket. */
const STOP_TIMEOUT_MS = 5_000;

/** The running daemon's `/v1/daemon` reply body, or null when none answers. Never starts one. */
async function runningDaemon(client) {
  try {
    const reply = await client.status();
    return reply.status === 200 ? reply.body : null;
  } catch {
    return null;
  }
}

export const daemonCommands = {
  'daemon run': {
    options: {},
    positionals: [0, 0],
    client: false,
    async run({ env, startDaemon = startDaemonServer, foreground = runInForeground }) {
      let daemon;
      try {
        daemon = await startDaemon({ dataDir: resolveDataDir(env), sink: selectSink({ env }) });
      } catch (error) {
        const reason = error instanceof DaemonRunningError ? `The Timer daemon is ${error.message}.` : `Could not start the Timer daemon: ${error.message}`;
        throw new CliError('daemon_unavailable', reason);
      }
      // Runs in the foreground until shutdown or the idle exit, then exits the process itself.
      await foreground(daemon);
      return null;
    }
  },
  'daemon status': {
    options: {},
    positionals: [0, 0],
    async run({ client }) {
      const status = await runningDaemon(client);
      if (!status) throw new CliError('daemon_unavailable', 'The Timer daemon is not running.');
      const text = [
        `pid: ${status.pid}`,
        `data dir: ${status.dataDir}`,
        `socket: ${status.socket}`,
        `alerts: ${status.alerts}`,
        `started: ${new Date(status.startedAt).toISOString()}`
      ].join('\n');
      return { json: status, text };
    }
  },
  'daemon stop': {
    options: {},
    positionals: [0, 0],
    async run({ client }) {
      if (!(await runningDaemon(client))) return { json: { stopped: false }, text: 'The Timer daemon is not running.' };
      try {
        await client.shutdown();
      } catch {
        // It may close the connection as it exits; the wait below tells.
      }
      const deadline = performance.now() + STOP_TIMEOUT_MS;
      while (await runningDaemon(client)) {
        if (performance.now() > deadline) throw new CliError('daemon_unavailable', `The Timer daemon did not stop within ${STOP_TIMEOUT_MS / 1000} s.`);
        await sleep(50);
      }
      return { json: { stopped: true }, text: 'Stopped the Timer daemon.' };
    }
  },
  'skill path': {
    options: {},
    positionals: [0, 0],
    client: false,
    async run({ packageRoot }) {
      const path = join(packageRoot, 'skills', 'subset-timer');
      return { json: { path }, text: path };
    }
  }
};
