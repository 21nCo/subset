// The Timer MCP server (SET-79) over stdio. The daemon owns the timers, so they keep running after
// this server exits; the server holds no state of its own. Stdout carries only protocol frames.
import { defineMcpFnServer } from '@mcpfn/core';
import manifest from '../../package.json' with { type: 'json' };
import { boardHtmlFile, boardResource } from './app.mjs';
import { timerTools } from './tools.mjs';

const INSTRUCTIONS = 'Timer runs countdowns, stopwatches and interval workouts in a daemon on this computer. Timers keep running after the conversation ends. Report each timer id and, while it runs, its end time. Run timer_reset, timer_remove and timer_preset_remove only at the user\'s explicit request.';

const NO_BOARD = () => {
  throw new Error('The Timer board view is not available from this server.');
};

/**
 * The server declaration: name `subset-timer`, the package version, the 12 timer tools and the board
 * view (`ui://subset-timer/board@1`).
 * @param {object} options
 * @param {object} options.client A daemon client from `createClient`; it starts the daemon on the first call if needed.
 * @param {() => number} [options.now]
 * @param {(message: string) => void} [options.log]
 * @param {() => string | Promise<string>} [options.boardHtml] The built view's HTML, for `resources/read`.
 */
export function defineTimerMcpServer({ client, now, log, boardHtml = NO_BOARD }) {
  return defineMcpFnServer({
    info: { name: 'subset-timer', version: manifest.version, instructions: INSTRUCTIONS },
    transports: ['stdio'],
    tools: timerTools({ client, now, log }),
    resources: [boardResource(boardHtml)]
  });
}

/** Writes one diagnostic line to stderr. */
export const stderrLog = (message) => process.stderr.write(`subset-timer mcp: ${message}\n`);

/**
 * Serves the tools on this process's stdin and stdout until stdin closes. Anything that would print
 * to stdout through `console` goes to stderr instead, so it cannot corrupt the protocol stream.
 * @param {object} options
 * @param {object} options.client
 * @param {string} options.packageRoot The installed package, which holds `mcp-app/board.html`.
 * @param {(message: string) => void} [options.log]
 */
export async function serveStdio({ client, packageRoot, log = stderrLog }) {
  for (const method of ['log', 'info', 'debug']) console[method] = (...args) => console.error(...args);
  // A host that closes its end mid-reply makes stdout fail with EPIPE; that ends the session, not the process with a stack trace.
  process.stdout.on('error', (error) => log(`stdout: ${error.message}`));
  const stdinClosed = new Promise((resolve) => {
    process.stdin.once('end', resolve);
    process.stdin.once('close', resolve);
  });
  const server = defineTimerMcpServer({ client, log, boardHtml: boardHtmlFile(packageRoot) }).createServer();
  await server.serveStdio();
  log(`${manifest.version} serving on stdio`);
  await stdinClosed;
  await server.close();
}
