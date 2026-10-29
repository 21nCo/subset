// The read-only usage MCP server (SET-104) over stdio. It answers from the same reads as `status` and
// the dashboard's history, and writes nothing: no identities, no default Claude account, no history,
// and never the local sign-ins preference. Stdout carries only protocol frames.
import diagnostics from 'node:diagnostics_channel';
import { basename } from 'node:path';
import { defineMcpFnServer } from '@mcpfn/core';
import { USAGE_PROVIDERS, agentUsageResult } from '@subset.dev/usage-core';
import { providerMeta } from '@subset.dev/usage-core/present';

const HOUR_MS = 60 * 60_000;
const DEFAULT_HOURS = 48;
const MAX_HOURS = 168;
// After stdin closes, calls already received get this long to answer before the server exits.
const PENDING_LIMIT_MS = 10_000;
// When the server stops, how long a provider subprocess has after SIGTERM, and then after SIGKILL, to exit.
const TERM_GRACE_MS = 1_000;
// How long stopping may take in all, ending subprocesses and answering the calls waiting on them.
const STOP_LIMIT_MS = 5_000;
// After that limit, how long the subprocesses still running then, and their calls, have after a final SIGKILL.
const FINAL_WAIT_MS = 500;

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

/**
 * One account's, or every account's, stored points from `start` to `end`, oldest first whatever order
 * the file holds them in. Built with fromEntries, so an ID such as `__proto__` stays an ordinary key.
 */
function historyInRange(history, start, end, accountId) {
  return Object.fromEntries(Object.entries(history.series)
    .filter(([id]) => accountId === undefined || id === accountId)
    .map(([id, windows]) => [id, Object.fromEntries(Object.entries(windows)
      .map(([key, points]) => [key, points.filter(([time]) => time >= start && time <= end).sort(([a], [b]) => a - b)])
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
 * Only no record (no file, or no entry for the account) is a first sighting, which adopts the snapshots
 * already collected. A record the session cannot use (one that cannot be read, is not in the form the
 * dashboard writes, or starts later than `now`, as when the clock was set back or the file was edited)
 * is unknown, not absent: it keeps the session's period, and without one the period starts at `now`
 * (`unknown: true`), so the snapshots collected before stay hidden and those collected after show.
 * @typedef {{ email: string, since: number, observedAt: number, unknown?: true }} IdentityPeriod
 * @param {IdentityPeriod | undefined} kept The session's period for the account.
 * @param {unknown} stored The account's entry in `claude-identities.json`, `{ email, since }`, read now:
 * `undefined` when the file has none or does not exist, and anything else that is not such an entry
 * (`null` for a file that cannot be read or parsed) when it is unknown.
 * @param {{ email: string, observedAt: number }} answer The signed-in email, and when it was queried.
 * @param {number} now
 * @returns {{ period: IdentityPeriod | undefined, current: boolean }} The period to keep, and whether the
 * answer is current; an out-of-date answer's snapshot is not shown under its email.
 */
export function claudeIdentityPeriod(kept, stored, answer, now) {
  let period = kept;
  if (usableRecord(stored, now) && !(stored.since <= period?.since)) {
    period = !period || stored.email === period.email || stored.since > period.observedAt
      ? { email: stored.email, since: stored.since, observedAt: Math.max(stored.since, stored.email === period?.email ? period.observedAt : 0) }
      // The session saw its email after the recorded change to another: it was signed in again since.
      : restarted(period, period.observedAt);
  }
  if (!period) {
    // A first sighting adopts the snapshots already collected; an unknown record adopts none.
    return { period: stored === undefined ? { email: answer.email, since: 0, observedAt: answer.observedAt } : { email: answer.email, since: now, observedAt: answer.observedAt, unknown: true }, current: true };
  }
  if (answer.email === period.email) return { period: { ...period, observedAt: Math.max(period.observedAt, answer.observedAt) }, current: true };
  // A newer answer is a sign-in change, and its period starts when the session observes it.
  if (answer.observedAt > period.observedAt) return { period: { email: answer.email, since: now, observedAt: answer.observedAt }, current: true };
  // An older answer that arrives late changes nothing, unless it was queried after the period started:
  // then the account was signed in elsewhere in between, so the period restarts at the latest observation.
  return { period: answer.observedAt > period.since ? restarted(period, period.observedAt) : period, current: false };
}

/**
 * Whether a stored entry is a period as the persist path writes it: a non-empty lowercase email, and a
 * start from 0 to `now`. Any other entry cannot be the dashboard's record, so it is unknown.
 */
const usableRecord = (stored, now) => typeof stored?.email === 'string' && stored.email !== '' && stored.email === stored.email.toLowerCase()
  && Number.isFinite(stored.since) && stored.since >= 0 && stored.since <= now;

/** The period, starting no earlier than `since`; a later start is known, not `unknown`. */
const restarted = (period, since) => (since > period.since ? { email: period.email, since, observedAt: period.observedAt } : period);

/** The identity periods one MCP session keeps in memory, for `status({ identitySession })`. */
export function identitySession() {
  const periods = new Map();
  return {
    /** Applies one read's sign-in answer synchronously, so overlapping reads share each period. */
    bind(id, stored, answer, now = Date.now()) {
      const { period, current } = claudeIdentityPeriod(periods.get(id), stored, answer, now);
      periods.set(id, period);
      return { since: period.since, current, unknown: period.unknown === true };
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
      description: `Current AI subscription usage for each account: quota windows with remaining percentage and reset time, plan, spend and balances, and errors. Give provider to return only that provider's accounts; every account is still read, so the call takes as long as an unfiltered one. ${LOCAL} ${providersText(providers)} ${READING}`,
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
/** Resolves with `value` after `ms`, without keeping the process alive for it. */
const after = (ms, value) => new Promise((resolveAfter) => { setTimeout(resolveAfter, ms, value).unref(); });
/** Resolves once every child in `list` has exited, or after `ms`. */
const exited = (list, ms) => Promise.race([Promise.all(list.map((child) => running(child) && new Promise((resolveExit) => child.once('exit', resolveExit)))), after(ms)]);

/**
 * The provider subprocesses this process starts (claude auth status, amp usage, codex app-server,
 * sqlite3, keychain reads). Their readers end them with timers of their own, which do not survive
 * this process, so the server ends them when it stops.
 */
export function providerProcesses(log) {
  const children = new Set();
  let stopping = false;
  // Once set, a subprocess that starts gets SIGKILL, as no later pass would escalate a SIGTERM.
  let final = false;
  const track = ({ process: child }) => {
    children.add(child);
    // A subprocess that failed to start (a provider CLI that is not installed) emits error and
    // close, never exit.
    child.once('exit', () => children.delete(child));
    child.once('close', () => children.delete(child));
    // A read that goes on after its subprocess was ended (an auth or keychain check, then the
    // provider) gets each later subprocess ended as it starts. The channel publishes before the
    // spawn, when kill() would signal PID 0, this whole process group; so it waits for the PID.
    if (stopping) child.once('spawn', () => {
      log(`stopping; ending ${basename(String(child.spawnfile))} (PID ${child.pid}), which a read started meanwhile`);
      child.kill(final ? 'SIGKILL' : 'SIGTERM');
    });
  };
  diagnostics.subscribe('child_process', track);
  const live = () => [...children].filter(running);
  const killAll = () => {
    final = true;
    for (const child of live()) child.kill('SIGKILL');
  };
  return {
    get stopping() { return stopping; },
    /** The number of subprocesses tracked, running or not yet closed. */
    get tracked() { return children.size; },
    /** Ends every running subprocess at once (a second signal), and every one that starts after. */
    kill: killAll,
    /** Stops tracking the subprocesses this process starts. */
    close() { diagnostics.unsubscribe('child_process', track); },
    /**
     * Ends every subprocess, including those the reads in `pending` start meanwhile, until no
     * subprocess runs and every call has settled, or the limit passes. SIGTERM comes first, so a
     * launcher (a shell or Node entrypoint) can end the provider it started; SIGKILL follows for any
     * still running after the grace period. Any still running at the limit, including one started just
     * before it, gets SIGKILL and a short wait. Returns the number of calls still unanswered.
     * @param {Set<Promise<unknown>>} pending
     * @param {{ limit?: number, now?: () => number }} [options] `now` is the clock the limit is measured on.
     */
    async end(pending, { limit = STOP_LIMIT_MS, now = Date.now } = {}) {
      stopping = true;
      const deadline = now() + limit;
      while (now() < deadline) {
        const list = live();
        if (list.length) {
          for (const child of list) child.kill('SIGTERM');
          await exited(list, Math.min(TERM_GRACE_MS, deadline - now()));
          for (const child of list.filter(running)) child.kill('SIGKILL');
          await exited(list, Math.max(0, Math.min(TERM_GRACE_MS, deadline - now())));
        } else if (pending.size) {
          // A call whose subprocess ended answers with that provider's error, or starts another subprocess.
          await Promise.race([Promise.allSettled(pending), after(50)]);
        } else break;
      }
      killAll();
      const finalDeadline = Date.now() + FINAL_WAIT_MS;
      await exited(live(), FINAL_WAIT_MS);
      await Promise.race([Promise.allSettled(pending), after(Math.max(0, finalDeadline - Date.now()))]);
      const left = live();
      if (left.length) log(`${left.length} provider subprocess(es) did not exit`);
      return pending.size;
    },
  };
}

/**
 * Serves the tools on this process's stdin and stdout until stdin closes, SIGTERM or SIGINT. Anything
 * that would print to stdout through `console` goes to stderr instead, so it cannot corrupt the
 * protocol stream. When stdin closes, the calls already received are answered; reads still running
 * after the pending limit, or at a signal, have their subprocesses ended and answer with that
 * provider's error. No provider subprocess a read started outlives the server, except a process
 * started by a launcher that does not pass SIGTERM on to it (it ignores SIGTERM, or dies of it
 * without forwarding): SIGTERM or SIGKILL then ends only the launcher.
 * @param {Parameters<typeof defineUsageMcpServer>[0]} options
 */
export async function serveStdio({ log = stderrLog, ...options }) {
  for (const method of ['log', 'info', 'debug']) console[method] = (...args) => console.error(...args);
  const processes = providerProcesses(log);
  const signalled = new Promise((resolveSignal) => {
    for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
      // A second signal, or one while stopping, does not wait for the grace period.
      if (processes.stopping) processes.kill();
      resolveSignal(signal);
    });
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
  let reason = await Promise.race([stdinClosed.then(() => null), signalled]);
  if (reason === null) {
    // Requests in the last chunk start their handlers after `end` is emitted; let them start, then
    // answer every call already received, unless a read takes longer than the limit.
    await new Promise((resolveTick) => setImmediate(resolveTick));
    reason = await Promise.race([Promise.allSettled(pending).then(() => null), after(PENDING_LIMIT_MS, 'limit'), signalled]);
  }
  if (reason) log(reason === 'limit' ? `stdin closed; ending the provider reads still running after ${PENDING_LIMIT_MS / 1000} s` : `${reason}; stopping`);
  // A subprocess a settled read left behind ends too.
  const unanswered = await processes.end(pending);
  if (unanswered) log(`${unanswered} call(s) were not answered`);
  // The protocol sends each reply after its handler settles.
  await new Promise((resolveTick) => setImmediate(resolveTick));
  await server.close();
}
