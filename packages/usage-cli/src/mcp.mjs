// The read-only usage MCP server (SET-104) over stdio. It answers from the same reads as `status` and
// the dashboard's history, and writes nothing: no identities, no default Claude account, no history,
// and never the local sign-ins preference. Stdout carries only protocol frames.
import { defineMcpFnServer } from '@mcpfn/core';
import { USAGE_PROVIDERS, agentUsageResult } from '@subset.dev/usage-core';
import { providerMeta } from '@subset.dev/usage-core/present';

const HOUR_MS = 60 * 60_000;
const DEFAULT_HOURS = 48;
const MAX_HOURS = 168;

const LOCAL = 'The data is local: it comes from the subset-usage configuration on this computer, the quota snapshots its collectors saved and, only when the user turned on local sign-ins in the dashboard, the usage endpoints of the tools signed in here. Nothing is sent to Subset.';
const READING = 'Each account has a state, a source and observedAt. An observation older than 5 minutes is stale: say when it was observed. A status-line snapshot is the last value a CLI collected, not a live read. A null percentage or reset time is unavailable, not zero; never estimate it. A calculated-estimate remaining percentage (~ in the text) is derived from provider-reported usage. errors[] says why an account has no values; local_sign_ins_off means the user can turn on local sign-ins in the dashboard\'s Settings.';
const INSTRUCTIONS = 'Subset usage reports AI subscription usage (quota left, reset times, spend and balances) for the accounts set up in the subset-usage dashboard on this computer. Both tools only read. Always give the observation time with a value, and call stale or unavailable values what they are.';

/** `ChatGPT (codex-chatgpt), Claude (claude-code)` for the providers the configuration names, once each. */
function providersText(providers) {
  if (providers === null) return 'The usage configuration could not be read when this server started; usage_status reports why.';
  const names = [...new Set(providers)].map((provider) => `${providerMeta[provider]?.name ?? provider} (${provider})`);
  // `status` also shows the signed-in default Claude Code account without it being configured.
  const claude = providers.includes('claude-code') ? '' : ' Claude Code\'s default sign-in on this computer appears too, if there is one.';
  return `${names.length ? `Providers configured when this server started: ${names.join(', ')}.` : 'No accounts were configured when this server started.'}${claude} Call usage_status for the current accounts.`;
}

const objectSchema = (properties) => ({ type: 'object', properties, additionalProperties: false });

/** `isError` with the code and message in the text and in `structuredContent.error`. */
function toolError(code, message, details = {}) {
  return { content: [{ type: 'text', text: `${code}: ${message}` }], structuredContent: { error: { code, message, ...details } }, isError: true };
}

/** mcpfn's JSON Schema issues as `invalid_input` issues, with dotted paths (`hours`, not `/hours`). */
function invalidInput(issues) {
  const mapped = issues.map((issue) => {
    const path = issue.instancePath.replace(/^\//, '').split('/').filter(Boolean);
    if (issue.missingProperty) path.push(issue.missingProperty);
    if (issue.rejectedProperty) path.push(issue.rejectedProperty);
    return { path: path.join('.'), message: issue.rejectedProperty ? 'is not a known field' : issue.message };
  });
  const message = mapped.map((issue) => (issue.path ? `${issue.path}: ${issue.message}` : issue.message)).join('; ');
  return toolError('invalid_input', message || 'The arguments do not match the tool schema.', { issues: mapped });
}

/** One account's, or every account's, stored points from `start` to `end`. Built with fromEntries, so an ID such as `__proto__` stays an ordinary key. */
function historyInRange(history, start, end, accountId) {
  return Object.fromEntries(Object.entries(history.series)
    .filter(([id]) => accountId === undefined || id === accountId)
    .map(([id, windows]) => [id, Object.fromEntries(Object.entries(windows)
      .map(([key, points]) => [key, points.filter(([time]) => time >= start && time <= end)])
      .filter(([, points]) => points.length))])
    .filter(([, windows]) => Object.keys(windows).length));
}

const iso = (time) => new Date(time).toISOString();

function historyText(series, hours, accountId) {
  const lines = Object.entries(series).flatMap(([id, windows]) => Object.entries(windows).map(([key, points]) => {
    // Window keys are `${limitId}\u0000${label}`; the label is what the dashboard shows.
    const [limitId, label] = key.split('\u0000');
    const used = points.map(([, percent]) => percent);
    const [first, last] = [points[0], points.at(-1)];
    return `${id} ${label || limitId}: ${points.length} point${points.length === 1 ? '' : 's'}; used ${first[1]}% at ${iso(first[0])}, ${last[1]}% at ${iso(last[0])} (lowest ${Math.min(...used)}%, highest ${Math.max(...used)}%)`;
  }));
  const scope = `${accountId === undefined ? '' : ` for account ${accountId}`} in the last ${hours} hour${hours === 1 ? '' : 's'}`;
  if (!lines.length) return `No usage history${scope}. History is recorded only while the subset-usage dashboard is open; no points means nothing was recorded, not zero usage.`;
  return `Used percentage history${scope} (recorded while the dashboard was open):\n${lines.join('\n')}`;
}

/**
 * The tool definitions for `@mcpfn/core`.
 * @param {object} options
 * @param {() => Promise<import('@subset.dev/usage-core').UsageStatus>} options.readStatus Reads every account without writing.
 * @param {() => Promise<import('@subset.dev/usage-core/history').UsageHistory>} options.readHistory The stored history, as `/api/history` returns it.
 * @param {string[] | null} options.providers The configured providers, or null when the configuration could not be read.
 * @param {() => number} [options.now]
 * @param {(message: string) => void} [options.log]
 */
export function usageTools({ readStatus, readHistory, providers, now = Date.now, log = () => {} }) {
  const definitions = [
    {
      name: 'usage_status',
      title: 'Usage status',
      description: `Current AI subscription usage for each account: quota windows with remaining percentage and reset time, plan, spend and balances, and errors. Give provider to read only that provider's accounts. ${LOCAL} ${providersText(providers)} ${READING}`,
      inputSchema: objectSchema({
        provider: { type: 'string', enum: [...USAGE_PROVIDERS], description: 'Only accounts of this provider: read through it, for its subscription, or also signed in through it.' },
      }),
      // A read may call a provider's usage endpoint when local sign-ins are on.
      annotations: { readOnlyHint: true, openWorldHint: true },
      async handler({ provider }) {
        const status = await readStatus();
        const accounts = provider === undefined ? status.accounts
          : status.accounts.filter((account) => account.provider === provider || account.service === provider || account.alsoIn?.includes(provider));
        const { structuredContent, text } = agentUsageResult({ ...status, accounts });
        // usageText says no accounts are configured at all; with a filter, say which provider has none.
        const shown = provider !== undefined && !accounts.length && status.accounts.length ? `No ${providerMeta[provider].name} (${provider}) accounts are configured.` : text;
        return { content: [{ type: 'text', text: shown }], structuredContent };
      },
    },
    {
      name: 'usage_history',
      title: 'Usage history',
      description: `The used percentage over time for each account (accountId from usage_status) and quota window, as the dashboard recorded it: observation time in epoch milliseconds and used percent, over the number of hours given (1 to ${MAX_HOURS}, default ${DEFAULT_HOURS}). It holds no labels, plans or errors. The data is local: the dashboard on this computer records it only while it is open and keeps 8 days, so gaps mean it was closed, not that nothing was used.`,
      inputSchema: objectSchema({
        hours: { type: 'integer', minimum: 1, maximum: MAX_HOURS, description: `How many hours back to read; default ${DEFAULT_HOURS}.` },
        accountId: { type: 'string', pattern: '^[a-zA-Z0-9_-]{1,64}$', description: 'Only this account, by its id from usage_status.' },
      }),
      // Reads only the history file; it calls no provider.
      annotations: { readOnlyHint: true, openWorldHint: false },
      async handler({ hours = DEFAULT_HOURS, accountId }) {
        const end = now();
        const start = end - hours * HOUR_MS;
        const series = historyInRange(await readHistory(), start, end, accountId);
        return { content: [{ type: 'text', text: historyText(series, hours, accountId) }], structuredContent: { schemaVersion: 1, from: iso(start), to: iso(end), series } };
      },
    },
  ];
  return definitions.map((definition) => ({
    ...definition,
    async handler(args) {
      try {
        return await definition.handler(args);
      } catch (error) {
        // The configuration's own messages name no paths or tokens; anything else stays on stderr.
        log(`${definition.name} failed: ${error?.stack ?? error}`);
        return toolError('usage_unavailable', 'Could not read the usage configuration or history. Open the dashboard (subset-usage) to check the accounts.');
      }
    },
    handleInvalidArguments: (_args, issues) => invalidInput(issues),
  }));
}

/**
 * The server declaration: name `subset-usage`, the package version, and the two read-only tools.
 * @param {Parameters<typeof usageTools>[0] & { version: string }} options
 */
export function defineUsageMcpServer({ version, ...options }) {
  return defineMcpFnServer({
    info: { name: 'subset-usage', version, instructions: INSTRUCTIONS },
    transports: ['stdio'],
    tools: usageTools(options),
  });
}

/** Writes one diagnostic line to stderr. */
export const stderrLog = (message) => process.stderr.write(`subset-usage mcp: ${message}\n`);

/**
 * Serves the tools on this process's stdin and stdout until stdin closes. Anything that would print
 * to stdout through `console` goes to stderr instead, so it cannot corrupt the protocol stream.
 * @param {Parameters<typeof defineUsageMcpServer>[0]} options
 */
export async function serveStdio({ log = stderrLog, ...options }) {
  for (const method of ['log', 'info', 'debug']) console[method] = (...args) => console.error(...args);
  // A host that closes its end mid-reply makes stdout fail with EPIPE; that ends the session, not the process with a stack trace.
  process.stdout.on('error', (error) => log(`stdout: ${error.message}`));
  const stdinClosed = new Promise((resolve) => {
    process.stdin.once('end', resolve);
    process.stdin.once('close', resolve);
  });
  const server = defineUsageMcpServer({ ...options, log }).createServer();
  await server.serveStdio();
  log(`${options.version} serving on stdio`);
  await stdinClosed;
  await server.close();
}
