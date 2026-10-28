// The read-only usage MCP server (SET-104) over stdio. It answers from the same reads as `status` and
// the dashboard's history, and writes nothing: no identities, no default Claude account, no history,
// and never the local sign-ins preference. Stdout carries only protocol frames.
import diagnostics from 'node:diagnostics_channel';
import { defineMcpFnServer } from '@mcpfn/core';
import { USAGE_PROVIDERS, agentUsageResult } from '@subset.dev/usage-core';
import { providerMeta } from '@subset.dev/usage-core/present';

const HOUR_MS = 60 * 60_000;
const DEFAULT_HOURS = 48;
const MAX_HOURS = 168;
// After stdin closes, calls already received get this long to answer before the server exits.
const PENDING_LIMIT_MS = 10_000;
// How long a provider subprocess the server ended, and the call waiting on it, get to finish.
const CHILD_EXIT_LIMIT_MS = 2_000;

const LOCAL = 'The data is local: it comes from the subset-usage configuration on this computer, the quota snapshots its collectors saved and, only when the user turned on local sign-ins in the dashboard, the usage endpoints of the tools signed in here. Nothing is sent to Subset.';
const READING = 'Each account has a state, a source and observedAt. An observation older than 5 minutes is stale: say when it was observed. A status-line snapshot is the last value a CLI collected, not a live read. A null percentage or reset time is unavailable, not zero; never estimate it. A calculated-estimate remaining percentage (~ in the text) is derived from provider-reported usage. errors[] says why an account has no values; local_sign_ins_off means the user can turn on local sign-ins in the dashboard\'s Settings.';
const HISTORY_READING = 'Each point is [observation time, used percent] for one quota window. The last point is only as current as its time: if it is more than 5 minutes old, say when it was observed, and call usage_status for the current value. A window or account with no points in range is unavailable for that time, not zero use; never fill gaps.';
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

/** The `usage_history` result: the range read and, per account and window, `[epoch ms, used percent]` points. */
const historyOutputSchema = {
  type: 'object',
  required: ['schemaVersion', 'from', 'to', 'series'],
  additionalProperties: false,
  properties: {
    schemaVersion: { const: 1 },
    from: { type: 'string', format: 'date-time', description: 'Start of the range read, inclusive.' },
    to: { type: 'string', format: 'date-time', description: 'End of the range read (now), inclusive.' },
    series: {
      type: 'object',
      description: 'Per accountId, per window key (`limitId`, U+0000, label), the points in range, oldest first. Accounts and windows without points are left out.',
      additionalProperties: {
        type: 'object',
        additionalProperties: {
          type: 'array',
          minItems: 1,
          items: { type: 'array', items: { type: 'number' }, minItems: 2, maxItems: 2, description: '[observation time in epoch milliseconds, used percent]' },
        },
      },
    },
  },
};

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
 * One Claude account's identity period in a session that writes nothing. Status-line snapshots carry
 * no identity, so a snapshot shows under the signed-in email only if it was observed at or after the
 * start (`since`) of that email's current period. The session's knowledge only moves forward: a later
 * period the dashboard recorded in `claude-identities.json` applies, and a sign-in answer older than
 * what the session already observed starts no period. `observedAt` is when the latest observation
 * supporting the period was made (a `claude auth status` query's start, or a recorded period's start).
 * @typedef {{ email: string, since: number, observedAt: number }} IdentityPeriod
 * @param {IdentityPeriod | undefined} kept The session's period for the account.
 * @param {unknown} stored The account's entry in `claude-identities.json`, `{ email, since }`, read now.
 * @param {{ email: string, observedAt: number }} answer The signed-in email, and when it was queried.
 * @param {number} now
 * @returns {{ period: IdentityPeriod, current: boolean }} The period to keep, and whether the answer is
 * current; an out-of-date answer's snapshot is not shown under its email.
 */
export function claudeIdentityPeriod(kept, stored, answer, now) {
  let period = kept;
  const recorded = Number(stored?.since);
  if (typeof stored?.email === 'string' && Number.isFinite(recorded) && !(recorded <= period?.since)) {
    period = !period || stored.email === period.email || recorded > period.observedAt
      ? { email: stored.email, since: recorded, observedAt: Math.max(recorded, stored.email === period?.email ? period.observedAt : 0) }
      // The session saw its email after the recorded change to another: it was signed in again since.
      : { ...period, since: Math.max(period.since, period.observedAt) };
  }
  // A first sighting adopts the snapshots already collected.
  if (!period) return { period: { email: answer.email, since: 0, observedAt: answer.observedAt }, current: true };
  if (answer.email === period.email) return { period: { ...period, observedAt: Math.max(period.observedAt, answer.observedAt) }, current: true };
  // A newer answer is a sign-in change, and its period starts when the session observes it.
  if (answer.observedAt > period.observedAt) return { period: { email: answer.email, since: now, observedAt: answer.observedAt }, current: true };
  // An older answer that arrives late changes nothing, unless it was queried after the period started:
  // then the account was signed in elsewhere in between, so the period restarts at the latest observation.
  return { period: answer.observedAt > period.since ? { ...period, since: Math.max(period.since, period.observedAt) } : period, current: false };
}

/** The identity periods one MCP session keeps in memory, for `status({ identitySession })`. */
export function identitySession() {
  const periods = new Map();
  return {
    /** Applies one read's sign-in answer synchronously, so overlapping reads share each period. */
    bind(id, stored, answer, now = Date.now()) {
      const { period, current } = claudeIdentityPeriod(periods.get(id), stored, answer, now);
      periods.set(id, period);
      return { since: period.since, current };
    },
  };
}

/**
 * The tool definitions for `@mcpfn/core`.
 * @param {object} options
 * @param {() => Promise<import('@subset.dev/usage-core').UsageStatus>} options.readStatus Reads every account without writing.
 * @param {() => Promise<import('@subset.dev/usage-core/history').UsageHistory>} options.readHistory The stored history, as `/api/history` returns it.
 * @param {string[] | null} options.providers The configured providers, or null when the configuration could not be read.
 * @param {() => number} [options.now]
 * @param {(message: string) => void} [options.log]
 * @param {Set<Promise<unknown>>} [options.pending] Receives each running call until it settles.
 */
export function usageTools({ readStatus, readHistory, providers, now = Date.now, log = () => {}, pending }) {
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
        return { content: [{ type: 'text', text }], structuredContent };
      },
    },
    {
      name: 'usage_history',
      title: 'Usage history',
      description: `The used percentage over time for each account (accountId from usage_status) and quota window, as the dashboard recorded it: observation time in epoch milliseconds and used percent, over the number of hours given (1 to ${MAX_HOURS}, default ${DEFAULT_HOURS}). It holds no labels, plans or errors. The data is local: the dashboard on this computer records it only while it is open and keeps 8 days, so gaps mean it was closed, not that nothing was used. ${providersText(providers)} ${HISTORY_READING}`,
      inputSchema: objectSchema({
        hours: { type: 'integer', minimum: 1, maximum: MAX_HOURS, description: `How many hours back to read; default ${DEFAULT_HOURS}.` },
        accountId: { type: 'string', pattern: '^[a-zA-Z0-9_-]{1,64}$', description: 'Only this account, by its id from usage_status.' },
      }),
      outputSchema: historyOutputSchema,
      // Reads only the history file, but its points came from the same provider reads as usage_status.
      annotations: { readOnlyHint: true, openWorldHint: true },
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
    handler(args) {
      const call = (async () => {
        try {
          return await definition.handler(args);
        } catch (error) {
          // The detail can name paths; it stays on stderr.
          log(`${definition.name} failed: ${error?.stack ?? error}`);
          return toolError('usage_unavailable', definition.name === 'usage_history'
            ? 'Could not read the stored usage history. Open the dashboard (subset-usage) to record it again.'
            : 'Could not read the usage configuration. Open the dashboard (subset-usage) to check the accounts.');
        }
      })();
      pending?.add(call);
      call.finally(() => pending?.delete(call));
      return call;
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

const running = (child) => child.pid !== undefined && child.exitCode === null && child.signalCode === null;

/**
 * Ends the provider subprocesses still running (reads, so nothing is left half-written) and waits,
 * up to a limit, until they have exited.
 * @param {Set<import('node:child_process').ChildProcess>} children
 */
async function endChildren(children) {
  const live = [...children].filter(running);
  if (!live.length) return;
  let timer;
  const limit = new Promise((resolveLimit) => { timer = setTimeout(resolveLimit, CHILD_EXIT_LIMIT_MS); });
  await Promise.race([Promise.all(live.map((child) => {
    const exited = new Promise((resolveExit) => child.once('exit', resolveExit));
    child.kill('SIGKILL');
    return running(child) ? exited : undefined;
  })), limit]);
  clearTimeout(timer);
}

/**
 * Serves the tools on this process's stdin and stdout until stdin closes, SIGTERM or SIGINT. Anything
 * that would print to stdout through `console` goes to stderr instead, so it cannot corrupt the
 * protocol stream. No provider subprocess a read started outlives it.
 * @param {Parameters<typeof defineUsageMcpServer>[0]} options
 */
export async function serveStdio({ log = stderrLog, ...options }) {
  for (const method of ['log', 'info', 'debug']) console[method] = (...args) => console.error(...args);
  // Provider readers start subprocesses (claude auth status, amp usage, codex app-server, sqlite3) and
  // end them with their own timers, which do not survive this process. Every one is tracked here.
  const children = new Set();
  diagnostics.subscribe('child_process', ({ process: child }) => {
    children.add(child);
    child.once('exit', () => children.delete(child));
  });
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => {
    log(`${signal}; stopping`);
    void endChildren(children).finally(() => process.exit(0));
  });
  // A host that closes its end mid-reply makes stdout fail with EPIPE; that ends the session, not the process with a stack trace.
  process.stdout.on('error', (error) => log(`stdout: ${error.message}`));
  const stdinClosed = new Promise((resolve) => {
    process.stdin.once('end', resolve);
    process.stdin.once('close', resolve);
  });
  const pending = new Set();
  const server = defineUsageMcpServer({ ...options, log, pending }).createServer();
  await server.serveStdio();
  log(`${options.version} serving on stdio`);
  await stdinClosed;
  // Requests in the last chunk start their handlers after `end` is emitted; let them start, then
  // answer every call already received, unless a read takes longer than the limit.
  await new Promise((resolveTick) => setImmediate(resolveTick));
  let timer;
  const limit = new Promise((resolveLimit) => { timer = setTimeout(resolveLimit, PENDING_LIMIT_MS); });
  const settled = await Promise.race([Promise.allSettled(pending).then(() => true), limit.then(() => false)]);
  clearTimeout(timer);
  if (!settled) {
    log(`stdin closed; ending the provider reads still running after ${PENDING_LIMIT_MS / 1000} s`);
    // A read whose subprocess ended reports that provider's error, and its call is answered.
    await endChildren(children);
    const answered = await Promise.race([Promise.allSettled(pending).then(() => true), new Promise((resolveWait) => { timer = setTimeout(() => resolveWait(false), CHILD_EXIT_LIMIT_MS); })]);
    clearTimeout(timer);
    if (!answered) log(`${pending.size} call(s) were not answered`);
  }
  // A subprocess a settled read left behind ends too.
  await endChildren(children);
  // The protocol sends each reply after its handler settles.
  await new Promise((resolveTick) => setImmediate(resolveTick));
  await server.close();
}
