import { spawn } from 'node:child_process';
import { stat } from 'node:fs/promises';
import { join } from 'node:path';
import { DEFAULT_PORT, PortInUseError, startWebServer } from '../serve.mjs';
import { CliError, usageError } from './shared.mjs';

/** Opens `url` in the default browser. A missing opener only leaves the printed URL. */
export function openInBrowser(url) {
  const child = spawn(process.platform === 'darwin' ? 'open' : 'xdg-open', [url], { stdio: 'ignore', detached: true });
  child.on('error', () => {});
  child.unref();
}

/** Resolves on the first Ctrl-C (SIGINT) or SIGTERM. */
export function untilInterrupted() {
  return new Promise((resolveStop) => {
    const stop = () => {
      for (const signal of ['SIGINT', 'SIGTERM']) process.off(signal, stop);
      resolveStop();
    };
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, stop);
  });
}

function parsePort(value) {
  if (value === undefined) return null;
  const port = /^\d{1,5}$/.test(value) ? Number(value) : NaN;
  if (!(port >= 1 && port <= 65_535)) throw usageError(`--port needs a port from 1 to 65535, not "${value}".`);
  return port;
}

export const serveCommands = {
  serve: {
    options: { port: { type: 'string' }, 'no-open': { type: 'boolean' } },
    positionals: [0, 0],
    async run({ client, values, packageRoot, print, openUrl = openInBrowser, untilStopped = untilInterrupted }) {
      const port = parsePort(values.port);
      const webDir = join(packageRoot, 'web');
      if (!(await stat(join(webDir, 'index.html')).then(() => true, () => false))) {
        throw Object.assign(new CliError('internal', `The Timer web files are missing from ${webDir}. Run npm run build at the repository root.`), { exitCode: 1 });
      }
      let host;
      try {
        host = await startWebServer({ client, webDir, port: port ?? DEFAULT_PORT, strictPort: port !== null });
      } catch (error) {
        if (error instanceof PortInUseError) throw usageError(`${error.message} Choose another with --port, or leave it out to use the next free port.`);
        throw Object.assign(new CliError('internal', `Could not start the Timer web host: ${error.message}`), { exitCode: 1 });
      }
      print({ json: { url: host.url, port: host.port }, text: `Timer is at ${host.url}\nPress Ctrl-C to stop.` });
      if (!values['no-open']) openUrl(host.url);
      await untilStopped();
      await host.close();
      return null;
    }
  }
};
