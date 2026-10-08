import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { chmod, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { dirname, extname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createUsageStatus } from '@subset/usage';
import { readCodexProfile } from '@subset/usage/codex';
import { readSnapshotProfile } from '@subset/usage/snapshots';
import { readCursorProfile } from '@subset/usage/cursor';
import { claudeBuiltInConfigDir, readClaudeAuthStatus, withClaudeAuth } from '@subset/usage/claude';
import { readClaudeOAuthUsage } from '@subset/usage/claude-oauth';
import { readAntigravityEmail } from '@subset/usage/local-auth';
import { readFactoryProfile } from '@subset/usage/factory';
import { readAmpProfile } from '@subset/usage/amp';
import { readCursorLocalProfile } from '@subset/usage/cursor-local';
import { readDevinProfile } from '@subset/usage/devin';
import { listStoredLogins, memoizedStoredLogins, readStoredLoginProfile, storedLoginAccount } from '@subset/usage/stored-logins';
import { consumeCodexResetCredit } from '@subset/usage/codex';
import { emptyUsageHistory, isUsageHistory, recordUsageHistory, removeHistoryAccount } from '@subset/usage/history';
import { createAccounts } from './accounts.mjs';

// Source (src/server.mjs) and bundle (dist/cli.mjs) both sit one level below the package root.
const packageRoot = fileURLToPath(new URL('..', import.meta.url));
const webOption = process.argv.indexOf('--web-dir');
const web = resolve(webOption > 0 && process.argv[webOption + 1] ? process.argv[webOption + 1] : process.env.SUBSET_USAGE_WEB_DIR ?? resolve(packageRoot, 'web'));
const profilesFile = resolve(process.env.SUBSET_USAGE_PROFILES_FILE ?? process.env.SUBSET_CODEX_PROFILES_FILE ?? resolve(homedir(), '.config/subset/codex-profiles.json'));
const dataDirectory = process.env.SUBSET_USAGE_DATA_DIR ? resolve(process.env.SUBSET_USAGE_DATA_DIR) : null;
// `claude auth status` can take seconds; reuse each directory's answer briefly. The live Claude
// read is throttled to five minutes anyway, so a token refresh by the CLI is never far behind.
const authCache = new Map();
function claudeAuth(configDir) {
  const entry = authCache.get(configDir);
  if (entry && Date.now() - entry.at < 60_000) return entry.value;
  const value = readClaudeAuthStatus(configDir);
  authCache.set(configDir, { at: Date.now(), value });
  value.catch(() => authCache.delete(configDir));
  return value;
}
const accounts = createAccounts({ profilesFile, readClaudeAuth: claudeAuth, ...(dataDirectory ? {
  managedRoot: resolve(dataDirectory, 'codex-accounts'),
  snapshotRoot: resolve(dataDirectory, 'usage-snapshots'),
} : {}) });

const dataRoot = dataDirectory ?? resolve(homedir(), '.local/share/subset');
// Usage history holds only observation times and percentages for trend charts.
const historyFile = resolve(dataRoot, 'usage-history.json');
let historyQueue = Promise.resolve();
async function loadHistory() {
  try { const value = JSON.parse(await readFile(historyFile, 'utf8')); return isUsageHistory(value) ? value : emptyUsageHistory(); }
  catch { return emptyUsageHistory(); }
}
function recordHistory(current) { return updateHistory((history) => recordUsageHistory(history, current)); }
function updateHistory(change) {
  historyQueue = historyQueue.then(async () => {
    const next = change(await loadHistory());
    await mkdir(dirname(historyFile), { recursive: true, mode: 0o700 });
    const temporary = `${historyFile}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, JSON.stringify(next), { mode: 0o600, flag: 'wx' });
      await rename(temporary, historyFile);
    } finally { await rm(temporary, { force: true }).catch(() => {}); }
  }).catch(() => {});
  return historyQueue;
}

// Live reads of undocumented usage endpoints are rate-limited by their providers. Reuse a recent good
// result, and after a 429 keep showing the last values (with their original observation time) until
// the provider's Retry-After, or five minutes, has passed.
const liveCache = new Map();
// Reads already in flight are shared, so concurrent refreshes call each provider once.
const inFlight = new Map();
async function throttled(key, minIntervalMs, read) {
  const now = Date.now();
  const entry = liveCache.get(key);
  if (entry?.account && now - entry.at < minIntervalMs) return entry.account;
  if (entry?.cooldownUntil > now) return entry.account ?? entry.error;
  if (inFlight.has(key)) return inFlight.get(key);
  const pending = read().finally(() => inFlight.delete(key));
  inFlight.set(key, pending);
  const result = await pending;
  const limited = result.errors?.some((error) => /rate_limited$/.test(error.code));
  if (limited) {
    liveCache.set(key, { ...entry, error: result, cooldownUntil: now + (result.retryAfterMs ?? 5 * 60_000) });
    return entry?.account ?? result;
  }
  if (result.observedAt && ['ok', 'partial'].includes(result.state)) liveCache.set(key, { account: result, at: now });
  else liveCache.delete(key);
  return result;
}
// Readers attach retryAfterMs for the throttle and workspaceId for login matching; neither is sent.
const publicAccount = ({ retryAfterMs: _retry, workspaceId: _workspace, ...account }) => account;
const needsLocalSignIns = (profile, tool) => ({
  id: profile.id, label: profile.label, provider: profile.provider, source: `${tool} sign-in`, plan: null, observedAt: null, state: 'unauthorized', windows: [], resetCredits: null,
  errors: [{ code: 'local_sign_ins_off', message: `Turn on local sign-ins in Settings to read ${tool}'s stored login.` }],
});

// Claude status-line snapshots carry no identity. The host remembers which email each Claude
// account was signed in as; a snapshot observed before a sign-in change belongs to the previous
// account and is not shown under the new one.
const identitiesFile = resolve(dataRoot, 'claude-identities.json');
let identityQueue = Promise.resolve();
async function claudeIdentities() {
  try { const value = JSON.parse(await readFile(identitiesFile, 'utf8')); return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
  catch { return {}; }
}

/**
 * Reads every account. `persist: false` (the `status` command) writes nothing: the default
 * Claude account is shown without being saved, and sign-in changes are tracked in memory only.
 */
async function status({ persist = true } = {}) {
  // A missing or failed Claude CLI must not hide the other accounts.
  let configured;
  if (persist) {
    await accounts.ensureDefaultClaude().catch(() => null);
    configured = await accounts.profiles();
  } else {
    const candidate = await accounts.defaultClaudeCandidate().catch(() => null);
    configured = [...await accounts.profiles(), ...(candidate ? [candidate] : [])];
  }
  const identities = await claudeIdentities();
  let identitiesChanged = false;
  const boundToIdentity = (profile, snapshot, auth) => {
    const email = auth?.email?.toLowerCase();
    if (!email) return snapshot;
    const known = identities[profile.id];
    if (!known || known.email !== email) {
      // First sighting adopts existing snapshots; a change starts a new identity period.
      identities[profile.id] = { email, since: known ? Date.now() : 0 };
      identitiesChanged = true;
    }
    const since = identities[profile.id].since;
    if (!snapshot.observedAt || Date.parse(snapshot.observedAt) >= since) return snapshot;
    return { ...snapshot, observedAt: null, state: 'unavailable', windows: [],
      errors: [{ code: 'claude_identity_changed', message: 'This Claude account signed in as someone else since the last snapshot. Quota appears after the next response in a CLI session.' }] };
  };
  const { localCredentials } = await accounts.usagePreferences();
  // Each tool's login store is read once per status read.
  const entries = memoizedStoredLogins();
  const harnessNames = { pi: 'Pi', opencode: 'OpenCode', omp: 'omp', hermes: 'Hermes' };
  const isStoredLogin = (profile) => Object.hasOwn(harnessNames, profile.provider);
  const isHarnessLogin = (profile) => isStoredLogin(profile) && (profile.login === 'chatgpt' || profile.login === 'claude');
  // Cached live results are keyed by the stored login's identity hash (account, workspace, and
  // token), so replacing or signing out a login never shows the previous login's usage.
  const logins = new Map(await Promise.all(configured.filter(isStoredLogin).map(async (profile) =>
    [profile.id, localCredentials ? await storedLoginAccount(profile, entries).catch(() => null) : null])));

  const readOne = async (profile) => {
    if (profile.provider === 'cursor') return readCursorProfile(profile);
    if (profile.provider === 'factory-droid') return publicAccount(await throttled(`factory:${profile.id}:${localCredentials}`, 60_000, () => readFactoryProfile(profile, { localCredentials })));
    if (profile.provider === 'cursor-local') {
      if (!localCredentials) return needsLocalSignIns(profile, 'Cursor');
      return publicAccount(await throttled(`cursor-local:${profile.id}`, 120_000, () => readCursorLocalProfile(profile)));
    }
    if (profile.provider === 'amp') return publicAccount(await throttled(`amp:${profile.id}`, 60_000, () => readAmpProfile(profile)));
    if (profile.provider === 'devin') return publicAccount(await throttled(`devin:${profile.id}:${localCredentials}`, 60_000, () => readDevinProfile(profile, { localCredentials })));
    if (isStoredLogin(profile)) {
      if (!localCredentials) return needsLocalSignIns(profile, harnessNames[profile.provider]);
      return publicAccount(await throttled(`${profile.provider}:${profile.id}:${logins.get(profile.id)?.identity ?? 'none'}`, 120_000, () => readStoredLoginProfile(profile, { entries })));
    }
    if (profile.provider === 'claude-code' && profile.claudeConfigDir) {
      // `claude auth status` runs first so Claude Code can refresh its own token before a live read.
      const auth = await claudeAuth(profile.claudeConfigDir);
      const snapshot = boundToIdentity(profile, await readSnapshotProfile(profile), auth);
      // The sign-in wrapper rewrites a missing snapshot's message; keep the identity-change reason.
      const identityError = snapshot.errors.find((error) => error.code === 'claude_identity_changed');
      const authed = withClaudeAuth(snapshot, auth);
      const fallback = identityError && auth?.loggedIn ? { ...authed, errors: [identityError] } : authed;
      if (!localCredentials || auth?.loggedIn === false) return fallback;
      const live = await throttled(`claude:${profile.id}:${auth?.email ?? ''}`, 300_000, async () => {
        const result = await readClaudeOAuthUsage(profile, { isDefault: profile.claudeConfigDir === claudeBuiltInConfigDir() });
        if (result.kind === 'ok') return result.account;
        if (result.kind === 'no-credential') return { noCredential: true, errors: [] };
        return { liveError: result, errors: [{ code: result.code, message: result.message }], retryAfterMs: result.retryAfterMs };
      });
      // A live read without windows does not replace collected snapshot windows.
      if (live.observedAt && (live.windows.length || !snapshot.windows.length)) return withClaudeAuth({ ...live, plan: live.plan ?? snapshot.plan }, auth);
      if (live.observedAt || live.noCredential) return fallback;
      const failure = live.liveError;
      // Keep any collected snapshot, and say why the live read failed.
      return { ...fallback, state: fallback.windows.length ? fallback.state : failure.state,
        errors: [{ code: failure.code, message: failure.message }, ...fallback.errors.filter((error) => error.code !== 'claude_awaiting_snapshot')] };
    }
    if (profile.provider === 'antigravity') {
      // The status line carries no identity; with local sign-ins on, show the CLI's signed-in email.
      const account = await readSnapshotProfile(profile);
      const email = localCredentials ? await readAntigravityEmail() : null;
      return email ? { ...account, email } : account;
    }
    if (profile.provider === 'claude-code') return readSnapshotProfile(profile);
    return readCodexProfile(profile);
  };

  // One account signed in to several harnesses gets one card: the direct ChatGPT or Claude
  // account (or the first harness) is read, and the others are listed in `alsoIn`. Another
  // harness is read only as a fallback when the main read has no usage, and never over an
  // explicit access denial.
  const results = new Map();
  await Promise.all(configured.filter((profile) => !isHarnessLogin(profile)).map(async (profile) => { results.set(profile.id, await readOne(profile)); }));
  const owners = new Map();
  for (const [id, account] of results) {
    if ((account.provider === 'codex-chatgpt' || account.provider === 'claude-code') && account.email) owners.set(`${account.provider}|${account.email.toLowerCase()}`, id);
  }
  // Harness logins group by email and workspace, so a Personal and a Team workspace under one
  // email stay separate cards. A group joins a direct account only when the email matches and the
  // plans agree (or the email has a single workspace and either plan is unknown).
  const groups = new Map();
  const workspacesByEmail = new Map();
  for (const profile of configured.filter(isHarnessLogin)) {
    const login = logins.get(profile.id);
    const service = profile.login === 'chatgpt' ? 'codex-chatgpt' : 'claude-code';
    const email = login?.email?.toLowerCase();
    const key = email ? `${service}|${email}|${login.workspace ?? ''}` : `profile|${profile.id}`;
    if (!groups.has(key)) groups.set(key, { service, email, plan: login?.plan ?? null, workspace: login?.workspace ?? null, members: [] });
    groups.get(key).members.push(profile);
    if (email) workspacesByEmail.set(`${service}|${email}`, new Set([...(workspacesByEmail.get(`${service}|${email}`) ?? []), login.workspace ?? '']));
  }
  const samePlan = (a, b) => a.toLowerCase().replace(/[^a-z0-9]/g, '') === b.toLowerCase().replace(/[^a-z0-9]/g, '');
  const ownerFor = (group) => {
    if (!group.email) return undefined;
    const ownerId = owners.get(`${group.service}|${group.email}`);
    if (!ownerId) return undefined;
    // Workspace IDs, when both sides report one, decide; plans are only a fallback heuristic.
    const owner = results.get(ownerId);
    if (owner?.workspaceId && group.workspace) return owner.workspaceId === group.workspace ? ownerId : undefined;
    const ownerPlan = owner?.plan ?? null;
    if (ownerPlan && group.plan) return samePlan(ownerPlan, group.plan) ? ownerId : undefined;
    return (workspacesByEmail.get(`${group.service}|${group.email}`)?.size ?? 0) <= 1 ? ownerId : undefined;
  };
  const merged = new Set();
  const usable = (account) => account.windows.length > 0 && ['ok', 'partial'].includes(account.state);
  await Promise.all([...groups.values()].map(async (group) => {
    const { members } = group;
    let ownerId = ownerFor(group);
    let rest = members;
    if (!ownerId) {
      ownerId = members[0].id;
      rest = members.slice(1);
      results.set(ownerId, await readOne(members[0]));
    }
    for (const profile of rest) {
      merged.add(profile.id);
      const owner = results.get(ownerId);
      if (!usable(owner) && owner.state !== 'blocked') {
        const fallback = await readOne(profile);
        if (fallback.windows.length) {
          // The main read's errors stay visible next to the fallback values.
          results.set(ownerId, { ...owner, windows: fallback.windows, state: fallback.state, observedAt: fallback.observedAt, plan: owner.plan ?? fallback.plan,
            source: `${owner.source}, read through ${harnessNames[profile.provider]}`, errors: owner.errors });
        }
      }
      const current = results.get(ownerId);
      if (profile.provider !== current.provider) results.set(ownerId, { ...current, alsoIn: [...new Set([...(current.alsoIn ?? []), profile.provider])] });
    }
  }));
  if (persist && identitiesChanged) {
    // Atomic and serialized: a torn file would reset identities and re-attribute old snapshots.
    identityQueue = identityQueue.then(async () => {
      await mkdir(dirname(identitiesFile), { recursive: true, mode: 0o700 });
      const current = await claudeIdentities();
      const temporary = `${identitiesFile}.${randomUUID()}.tmp`;
      try {
        await writeFile(temporary, JSON.stringify({ ...current, ...identities }), { mode: 0o600, flag: 'wx' });
        await rename(temporary, identitiesFile);
      } finally { await rm(temporary, { force: true }).catch(() => {}); }
    }).catch(() => {});
    await identityQueue;
  }
  return createUsageStatus(configured.filter((profile) => !merged.has(profile.id)).map((profile) => publicAccount(results.get(profile.id))));
}

function runStatusLine(command, input) {
  return new Promise((resolveExit) => {
    // The platform shell (sh, or cmd on Windows) runs the previous status line as the CLI would.
    const child = spawn(command, { shell: true, stdio: ['pipe', 'inherit', 'inherit'] });
    child.on('error', () => resolveExit(1));
    child.on('close', (code) => resolveExit(code ?? 1));
    child.stdin.on('error', () => {});
    child.stdin.end(input);
  });
}

const shellQuote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
const claudeSetup = (profile) => {
  const command = collectCommand(profile.id);
  const configDir = profile.claudeConfigDir;
  return {
    collectCommand: command,
    ...(configDir ? {
      claudeSettingsFile: resolve(configDir, 'settings.json'),
      claudeLaunchCommand: configDir === claudeBuiltInConfigDir() ? 'claude' : `CLAUDE_CONFIG_DIR=${shellQuote(configDir)} claude`,
    } : {}),
  };
};
// Installed status lines call a stable shim rather than this file, so moving, upgrading, or
// reinstalling the CLI never breaks them. `serve` rewrites the shim for the current install.
// One shim per configuration: a server started with another profiles file in the same data
// directory gets its own shim instead of redirecting this configuration's collectors.
const customProfiles = !!(process.env.SUBSET_USAGE_PROFILES_FILE || process.env.SUBSET_CODEX_PROFILES_FILE);
const collectorShim = resolve(dataRoot, 'bin', customProfiles
  ? `subset-usage-collect-${createHash('sha256').update(profilesFile).digest('hex').slice(0, 10)}` : 'subset-usage-collect');
const collectCommand = (id) => `${shellQuote(collectorShim)} --account ${shellQuote(id)}`;
async function writeCollectorShim() {
  const env = [
    ...(customProfiles ? [`SUBSET_USAGE_PROFILES_FILE=${shellQuote(profilesFile)}`] : []),
    ...(dataDirectory ? [`SUBSET_USAGE_DATA_DIR=${shellQuote(dataDirectory)}`] : []),
  ];
  const body = ['#!/bin/sh', '# Written by subset-usage serve. Collects usage for an installed CLI status line.',
    ...env.map((line) => `export ${line}`), `exec ${shellQuote(process.execPath)} ${shellQuote(fileURLToPath(import.meta.url))} collect "$@"`, ''].join('\n');
  await mkdir(dirname(collectorShim), { recursive: true, mode: 0o700 });
  const temporary = `${collectorShim}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, body, { mode: 0o700, flag: 'wx' });
    await chmod(temporary, 0o700);
    await rename(temporary, collectorShim);
  } finally { await rm(temporary, { force: true }).catch(() => {}); }
  // Collectors installed before the shim existed, or by an older install, are pointed at it.
  await accounts.migrateCollectors(collectCommand);
}

async function readJson(request) {
  if (!request.headers['content-type']?.startsWith('application/json')) throw new Error('Expected a JSON request.');
  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > 8192) throw new Error('Request is too large.');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new Error('Invalid JSON request.'); }
}

function json(response, code, value) {
  response.setHeader('Content-Type', 'application/json; charset=utf-8');
  response.writeHead(code).end(JSON.stringify(value));
}

const publicErrors = new Set([
  'Expected a JSON request.', 'Request is too large.', 'Invalid JSON request.',
  'The current Codex home is not signed in with a ChatGPT account.', 'The dashboard already has 20 accounts.',
  'Enter an account name of at most 80 characters.', 'Finish or cancel the current sign-in first.',
  'Invalid account ID.', 'Account was not found.', 'Sign-in was not found.', 'No active sign-in was found.',
  'Could not start ChatGPT sign-in.', 'Could not read Codex profiles configuration.',
  'Invalid Codex profile configuration.', 'Duplicate Codex profile configuration.',
  'Codex profiles configuration must contain at most 20 profiles.',
  'Could not read usage profiles configuration.', 'Invalid usage profile configuration.',
  'Duplicate usage profile configuration.', 'Usage profiles configuration must contain at most 20 profiles.',
  'Unsupported usage provider.', 'Invalid usage account configuration.',
  'Enter the Claude Code config directory as an absolute or ~/ path.',
  'Another Claude Code account already uses this config directory.',
  'The default Claude Code config directory is not signed in.',
  'Could not read the CLI settings file.', 'The CLI settings file is too large to update safely.',
  'The CLI settings file is not valid JSON. Fix it or set up the collector manually.',
  'Set a Claude Code config directory for this account to install its collector automatically.',
  'The CLI settings directory was not found. Start the CLI once with this account, then try again.',
  'Could not back up the CLI settings file.',
  'Enter the Factory home as an absolute or ~/ path.', 'Invalid settings.',
  'Choose which stored login to read.', 'Invalid reset request.', 'Codex could not use a reset.',
  "Another account's collector uses this CLI's status line. Uninstall it from that account first.",
  'Could not restore the CLI status line for this account. Fix its settings.json, then remove the account again.',
]);

const usage = `Usage: subset-usage [serve|status|collect] [options]

  serve                 Open the local usage dashboard (default)
    --port <number>     Port on 127.0.0.1 (default 4174, or the next free one)
    --no-open           Do not open a browser
    --web-dir <path>    Serve the dashboard from another build (development)
  status                Print current usage as JSON
  collect --account <id>
                        Save a quota snapshot from a CLI status line (used by installed collectors)
  --help, --version
`;
const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name) => { const index = args.indexOf(name); return index >= 0 ? args[index + 1] : undefined; };
const command = args[0] && !args[0].startsWith('-') ? args[0] : 'serve';
if (flag('--help') || flag('-h')) {
  process.stdout.write(usage);
} else if (flag('--version') || flag('-v')) {
  const manifest = JSON.parse(await readFile(resolve(packageRoot, 'package.json'), 'utf8').catch(() => '{}'));
  process.stdout.write(`${manifest.version ?? 'unknown'}\n`);
} else if (command === 'status') {
  try { process.stdout.write(`${JSON.stringify(await status({ persist: false }))}\n`); }
  catch { process.stderr.write('Could not read usage configuration.\n'); process.exitCode = 1; }
} else if (command === 'collect') {
  const id = args.length === 3 && args[1] === '--account' ? args[2] : null;
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > 1024 * 1024) break;
    chunks.push(chunk);
  }
  const input = Buffer.concat(chunks);
  // An installed collector replaces the CLI's status line, so it runs the previous one with the same input.
  const chained = id ? await accounts.chainedStatusLine(id).catch(() => null) : null;
  const previous = chained ? runStatusLine(chained, input) : null;
  try {
    if (!id) throw new Error('Invalid collector arguments.');
    if (input.length > 65536) throw new Error('Snapshot is too large.');
    await accounts.captureSnapshot(id, JSON.parse(input.toString('utf8')), { env: process.env });
  } catch (error) {
    // Startup payloads arrive before quota exists; stay quiet while the previous status line renders.
    if (!previous) {
      process.stderr.write(/different Claude Code config directory/.test(error?.message ?? '')
        ? `${error.message} Check which settings.json contains this collector.\n`
        : 'Could not collect this account quota snapshot. Check the account ID and CLI payload.\n');
      process.exitCode = 1;
    }
  }
  if (previous) process.exitCode = await previous;
} else if (command === 'serve') {
  const requested = option('--port') ?? process.env.SUBSET_USAGE_PORT;
  let port = Number(requested ?? 4174);
  if (!Number.isInteger(port) || port < 1 || port > 65535) { process.stderr.write('Invalid port.\n'); process.exit(2); }
  try { await readFile(resolve(web, 'index.html')); }
  catch { process.stderr.write(`The dashboard files were not found in ${web}. Build the web app first.\n`); process.exit(1); }
  await writeCollectorShim().catch(() => process.stderr.write('Could not write the collector shim; installed status lines may not collect.\n'));
  const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.woff2': 'font/woff2' };
  const server = createServer(async (request, response) => {
    const host = request.headers.host;
    if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}`) { response.writeHead(403).end(); return; }
    const origin = request.headers.origin;
    if (origin && origin !== `http://${host}`) { response.writeHead(403).end(); return; }
    const path = new URL(request.url ?? '/', `http://${host}`).pathname;
    // API calls need the dashboard's own header, which a cross-site page cannot send without a
    // CORS preflight this server never approves; browsers that report the request site are checked too.
    if (path.startsWith('/api/') && (request.headers['x-subset-request'] !== '1' || ['cross-site', 'same-site'].includes(request.headers['sec-fetch-site']))) {
      response.writeHead(403).end(); return;
    }
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Content-Security-Policy', "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'self' http://127.0.0.1:* http://localhost:*");
    try {
      if (path === '/api/status' && request.method === 'GET') {
        const current = await status();
        await recordHistory(current);
        json(response, 200, current); return;
      }
      if (path === '/api/stored-logins' && request.method === 'GET') {
        // Names of the logins the tools hold, never their values, and nothing while local sign-ins are off.
        const { localCredentials } = await accounts.usagePreferences();
        const [pi, opencode, omp, hermes] = localCredentials
          ? await Promise.all(['pi', 'opencode', 'omp', 'hermes'].map((tool) => listStoredLogins(tool)))
          : [[], [], [], []];
        json(response, 200, { pi, opencode, omp, hermes }); return;
      }
      if (path === '/api/preferences' && request.method === 'GET') { json(response, 200, await accounts.usagePreferences()); return; }
      if (path === '/api/history' && request.method === 'GET') { json(response, 200, await loadHistory()); return; }
      if (path === '/api/profiles' && request.method === 'GET') {
        await accounts.ensureDefaultClaude().catch(() => null);
        const profiles = await Promise.all((await accounts.list()).map(async (profile) => {
          if (profile.provider === 'factory-droid') {
            return { ...profile, factoryLaunchCommand: profile.factoryHome === homedir() ? 'droid' : `FACTORY_HOME_OVERRIDE=${shellQuote(profile.factoryHome)} droid` };
          }
          if (profile.provider !== 'claude-code' && profile.provider !== 'antigravity') return profile;
          const command = collectCommand(profile.id);
          return { ...profile, ...(profile.provider === 'claude-code' ? claudeSetup(profile) : { collectCommand: command }),
            collector: await accounts.collectorStatus(profile, command) };
        }));
        json(response, 200, { profiles }); return;
      }
      if (path.startsWith('/api/')) {
        if (request.method !== 'GET' && request.headers.origin !== `http://${host}`) { response.writeHead(403).end(); return; }
        if (path === '/api/profiles' && request.method === 'POST') {
          const body = await readJson(request);
          json(response, 201, await accounts.addProvider(body)); return;
        }
        if (path === '/api/profiles/current' && request.method === 'POST') { json(response, 201, await accounts.addCurrent()); return; }
        if (path === '/api/profiles/claude-default' && request.method === 'POST') { json(response, 201, await accounts.ensureDefaultClaude({ force: true })); return; }
        if (path === '/api/preferences' && request.method === 'PUT') { json(response, 200, await accounts.setUsagePreferences(await readJson(request))); return; }
        if (path === '/api/history' && request.method === 'DELETE') {
          historyQueue = historyQueue.then(() => rm(historyFile, { force: true })).catch(() => {});
          await historyQueue;
          json(response, 200, { cleared: true }); return;
        }
        const resetMatch = path.match(/^\/api\/profiles\/([a-zA-Z0-9_-]{1,64})\/reset$/);
        if (resetMatch && request.method === 'POST') {
          const body = await readJson(request);
          if (typeof body?.idempotencyKey !== 'string' || !/^[0-9a-f-]{36}$/i.test(body.idempotencyKey)) throw new Error('Invalid reset request.');
          const profile = (await accounts.profiles()).find((item) => item.id === resetMatch[1] && item.provider === 'codex-chatgpt');
          if (!profile) throw new Error('Account was not found.');
          try { json(response, 200, { outcome: await consumeCodexResetCredit(profile, { idempotencyKey: body.idempotencyKey }) }); }
          catch { throw new Error('Codex could not use a reset.'); }
          return;
        }
        const collectorMatch = path.match(/^\/api\/profiles\/([a-zA-Z0-9_-]{1,64})\/collector$/);
        if (collectorMatch && request.method === 'POST') { json(response, 200, await accounts.installCollector(collectorMatch[1], collectCommand(collectorMatch[1]))); return; }
        if (collectorMatch && request.method === 'DELETE') { json(response, 200, await accounts.uninstallCollector(collectorMatch[1])); return; }
        const profileMatch = path.match(/^\/api\/profiles\/([a-zA-Z0-9_-]{1,64})$/);
        if (profileMatch && request.method === 'PATCH') {
          const body = await readJson(request);
          if (!body || typeof body !== 'object' || Object.keys(body).some((key) => key !== 'label')) throw new Error('Invalid usage account configuration.');
          json(response, 200, await accounts.renameProfile(profileMatch[1], body.label ?? '')); return;
        }
        if (profileMatch && request.method === 'DELETE') {
          const body = await readJson(request);
          if (body?.confirmation !== profileMatch[1]) throw new Error('Invalid account ID.');
          const removed = await accounts.removeProfile(profileMatch[1]);
          await updateHistory((history) => removeHistoryAccount(history, profileMatch[1]));
          json(response, 200, removed); return;
        }
        if (path === '/api/connections' && request.method === 'POST') {
          const body = await readJson(request);
          json(response, 201, await accounts.startLogin(body?.label)); return;
        }
        if (path === '/api/connections/active' && request.method === 'GET') { json(response, 200, { connection: accounts.activeConnection() }); return; }
        const connectionMatch = path.match(/^\/api\/connections\/([a-zA-Z0-9_-]{1,64})$/);
        if (connectionMatch && request.method === 'GET') { json(response, 200, accounts.connection(connectionMatch[1])); return; }
        const cancelMatch = path.match(/^\/api\/connections\/([a-zA-Z0-9_-]{1,64})\/cancel$/);
        if (cancelMatch && request.method === 'POST') { json(response, 200, await accounts.cancelLogin(cancelMatch[1])); return; }
        response.writeHead(404).end(); return;
      }
      if (request.method !== 'GET') { response.writeHead(405).end(); return; }
    } catch (error) {
      json(response, 400, { error: publicErrors.has(error?.message) ? error.message : 'Could not update usage accounts. Check the connection configuration.' });
      return;
    }
    const target = resolve(web, `.${path === '/' ? '/index.html' : path}`);
    if (target !== web && !target.startsWith(web + sep)) { response.writeHead(404).end(); return; }
    try { const body = await readFile(target); response.setHeader('Content-Type', mime[extname(target)] ?? 'application/octet-stream'); response.writeHead(200).end(body); }
    catch { response.writeHead(404).end(); }
  });
  // An explicit port must be free; the default moves to the next free port.
  for (let attempt = 0; ; attempt++) {
    const error = await new Promise((resolveListen) => {
      server.once('error', resolveListen);
      server.listen(port, '127.0.0.1', () => { server.off('error', resolveListen); resolveListen(null); });
    });
    if (!error) break;
    if (error.code !== 'EADDRINUSE' || requested !== undefined || attempt >= 20) {
      process.stderr.write(error.code === 'EADDRINUSE' ? `Port ${port} is in use. Choose another with --port.\n` : 'Could not start the dashboard server.\n');
      process.exit(1);
    }
    port++;
  }
  const url = `http://127.0.0.1:${port}`;
  process.stdout.write(`Subset usage listening on ${url}\nPress Ctrl-C to stop.\n`);
  if (!flag('--no-open') && !process.env.SUBSET_USAGE_NO_OPEN) {
    const [opener, openerArgs] = process.platform === 'darwin' ? ['open', [url]] : process.platform === 'win32' ? ['cmd', ['/c', 'start', '', url]] : ['xdg-open', [url]];
    const child = spawn(opener, openerArgs, { stdio: 'ignore', detached: true });
    child.on('error', () => {});
    child.unref();
  }
  let stopping = false;
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
    if (stopping) process.exit(1);
    stopping = true;
    // Browser keep-alive connections would otherwise hold the process open after Ctrl-C.
    server.close();
    server.closeAllConnections();
    setTimeout(() => process.exit(1), 5000).unref();
    void accounts.close().finally(() => process.exit(0));
  });
} else {
  process.stderr.write(usage);
  process.exitCode = 2;
}
