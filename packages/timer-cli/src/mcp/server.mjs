// The Timer MCP server (SET-79) over stdio. The daemon owns the timers, so they keep running after
// this server exits; the server holds no state of its own. Stdout carries only protocol frames.
import { defineMcpFnServer } from '@mcpfn/core';
import manifest from '../../package.json' with { type: 'json' };
import { timerTools } from './tools.mjs';

const INSTRUCTIONS = 'Timer runs countdowns, stopwatches and interval workouts in a daemon on this computer. Timers keep running after the conversation ends. Report each timer id and, while it runs, its end time. Run timer_reset, timer_remove and timer_preset_remove only at the user\'s explicit request.';

/**
 * The server declaration: name `subset-timer`, the package version and the 12 timer tools.
 * @param {object} options
 * @param {object} options.client A daemon client from `createClient`; it starts the daemon on the first call if needed.
 * @param {() => number} [options.now]
 * @param {(message: string) => void} [options.log]
 */
export function defineTimerMcpServer({ client, now, log }) {
  return defineMcpFnServer({
    info: { name: 'subset-timer', version: manifest.version, instructions: INSTRUCTIONS },
    transports: ['stdio'],
    tools: timerTools({ client, now, log })
  });
}

/** Writes one diagnostic line to stderr. */
export const stderrLog = (message) => process.stderr.write(`subset-timer mcp: ${message}\n`);

/**
 * Serves the tools on this process's stdin and stdout until stdin closes. Anything that would print
 * to stdout through `console` goes to stderr instead, so it cannot corrupt the protocol stream.
 * @param {object} options
 * @param {object} options.client
 * @param {(message: string) => void} [options.log]
 */
export async function serveStdio({ client, log = stderrLog }) {
  for (const method of ['log', 'info', 'debug']) console[method] = (...args) => console.error(...args);
  // A host that closes its end mid-reply makes stdout fail with EPIPE; that ends the session, not the process with a stack trace.
  process.stdout.on('error', (error) => log(`stdout: ${error.message}`));
  const stdinClosed = new Promise((resolve) => {
    process.stdin.once('end', resolve);
    process.stdin.once('close', resolve);
  });
  const server = defineTimerMcpServer({ client, log }).createServer();
  await server.serveStdio();
  log(`${manifest.version} serving on stdio`);
  await stdinClosed;
  await server.close();
}
