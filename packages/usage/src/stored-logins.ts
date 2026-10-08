import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fetchClaudeUsage } from './claude-oauth.js';
import { isEmail, type UsageAccount, type UsageWindow } from './index.js';
import { fetchJson, jwtClaims, readSmallFile } from './local-auth.js';

/**
 * Subscription usage for logins that Pi and OpenCode keep in their own auth.json (opt-in local
 * sign-ins only). Each tool refreshes its own tokens; Subset only reads them, so an expired token
 * asks the user to open the tool. ChatGPT and OpenCode Go usage come from endpoints those tools'
 * makers do not document; Claude usage reuses the Claude reader.
 */
export type StoredLoginTool = 'pi' | 'opencode' | 'omp' | 'hermes';
export type StoredLoginKind = 'chatgpt' | 'claude' | 'opencode-go';
/** `entryId` selects one of several stored logins of the same kind (omp keeps one row per login). */
export interface StoredLoginProfile { id: string; label: string; provider: StoredLoginTool; login: StoredLoginKind; dataDir?: string; entryId?: string }
/** What a store holds, without secrets: offered when adding an account. */
export interface StoredLoginOption { kind: StoredLoginKind; entryId?: string; email?: string }
export interface StoredEntry extends StoredLoginOption { token: string | null; accountId: string | null; expires: number | null; reloginRequired: boolean }
/** The subscription service whose quota a stored login reads. */
export const STORED_LOGIN_SERVICE: Partial<Record<StoredLoginKind, 'codex-chatgpt' | 'claude-code'>> = { chatgpt: 'codex-chatgpt', claude: 'claude-code' };

const object = (value: unknown): Record<string, unknown> | null => value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
const text = (value: unknown, max = 16_384): string | null => typeof value === 'string' && value.length > 0 && value.length <= max ? value : null;
const percent = (value: unknown): number | null => typeof value === 'number' && Number.isFinite(value) ? Math.min(100, Math.max(0, Math.round(value * 10) / 10)) : null;
const TOOL_NAME: Record<StoredLoginTool, string> = { pi: 'Pi', opencode: 'OpenCode', omp: 'omp', hermes: 'Hermes' };
// Store keys per tool: Pi names its ChatGPT login openai-codex; OpenCode names it openai.
const KEYS: Record<StoredLoginTool, Partial<Record<StoredLoginKind, string[]>>> = {
  pi: { chatgpt: ['openai-codex'], claude: ['anthropic'] },
  opencode: { chatgpt: ['openai'], claude: ['anthropic'], 'opencode-go': ['opencode-go', 'opencode'] },
  omp: { chatgpt: ['openai-codex'], claude: ['anthropic'] },
  hermes: { chatgpt: ['openai-codex'], claude: ['anthropic'] },
};

export function storedLoginFile(tool: StoredLoginTool, dataDir?: string, env: NodeJS.ProcessEnv = process.env): string {
  if (dataDir) return join(dataDir, tool === 'omp' ? 'agent.db' : 'auth.json');
  if (tool === 'pi') return join(env.PI_CODING_AGENT_DIR || join(homedir(), '.pi', 'agent'), 'auth.json');
  if (tool === 'hermes') return join(env.HERMES_HOME || join(homedir(), '.hermes'), 'auth.json');
  if (tool === 'omp') return join(homedir(), '.omp', 'agent', 'agent.db');
  return join(env.XDG_DATA_HOME || join(homedir(), '.local', 'share'), 'opencode', 'auth.json');
}

/** Reads omp's credential rows through the system sqlite3, read-only. */
function readOmpRows(file: string): Promise<Array<{ id: string; provider: string; data: unknown }>> {
  return new Promise((resolve) => {
    execFile('/usr/bin/sqlite3', ['-readonly', file, "select json_object('id', id, 'provider', provider, 'data', data) from auth_credentials where disabled_cause is null and provider in ('openai-codex', 'anthropic') limit 50;"], {
      encoding: 'utf8', timeout: 5000, maxBuffer: 512 * 1024, killSignal: 'SIGKILL', env: { PATH: '/usr/bin:/bin' },
    }, (error, stdout) => {
      if (error) { resolve([]); return; }
      resolve(stdout.split('\n').filter(Boolean).map((line) => object(safeJson(line))).filter((row): row is Record<string, unknown> => !!row)
        .map((row) => ({ id: String(row.id), provider: String(row.provider), data: safeJson(typeof row.data === 'string' ? row.data : null) })));
    });
  });
}

const kindFor = (tool: StoredLoginTool, key: string): StoredLoginKind | null =>
  (Object.entries(KEYS[tool]) as Array<[StoredLoginKind, string[]]>).find(([, keys]) => keys.includes(key))?.[0] ?? null;
const tokenEmail = (token: string | null): string | null => {
  const claims = token ? jwtClaims(token) : null;
  const email = object(claims?.['https://api.openai.com/profile'])?.email ?? claims?.email;
  return isEmail(email) ? email : null;
};

async function readEntries(tool: StoredLoginTool, dataDir?: string): Promise<StoredEntry[]> {
  if (tool === 'omp') {
    return (await readOmpRows(storedLoginFile(tool, dataDir))).flatMap((row) => {
      const kind = kindFor(tool, row.provider);
      const data = object(row.data);
      if (!kind || !data) return [];
      const token = text(data.access);
      return [{ kind, entryId: row.id, token, accountId: text(data.accountId, 128), expires: typeof data.expires === 'number' ? data.expires : null,
        email: isEmail(data.email) ? data.email : tokenEmail(token) ?? undefined, reloginRequired: false }];
    });
  }
  const store = object(safeJson(await readSmallFile(storedLoginFile(tool, dataDir), 256 * 1024)));
  if (tool === 'hermes') {
    const providers = object(store?.providers);
    return Object.entries(providers ?? {}).flatMap(([key, value]) => {
      const kind = kindFor(tool, key);
      const entry = object(value);
      const tokens = object(entry?.tokens);
      if (!kind || !tokens) return [];
      const token = text(tokens.access_token);
      const exp = token ? jwtClaims(token)?.exp : undefined;
      return [{ kind, token, accountId: text(tokens.account_id, 128), expires: typeof exp === 'number' ? exp * 1000 : null,
        email: tokenEmail(token) ?? undefined, reloginRequired: object(entry?.last_auth_error)?.relogin_required === true }];
    });
  }
  return (Object.entries(KEYS[tool]) as Array<[StoredLoginKind, string[]]>).flatMap(([kind, keys]) => {
    const entry = keys.map((key) => object(store?.[key])).find(Boolean);
    if (!entry) return [];
    const token = text(entry.access) ?? text(entry.key);
    return [{ kind, token, accountId: text(entry.accountId, 128), expires: typeof entry.expires === 'number' ? entry.expires : null,
      email: tokenEmail(token) ?? undefined, reloginRequired: false }];
  });
}

/** Reads a tool's store. A status read passes one memoized reader so each store is read once. */
export type StoredEntriesReader = (tool: StoredLoginTool, dataDir?: string) => Promise<StoredEntry[]>;
export function memoizedStoredLogins(): StoredEntriesReader {
  const memo = new Map<string, Promise<StoredEntry[]>>();
  return (tool, dataDir) => {
    const key = `${tool}\u0000${dataDir ?? ''}`;
    if (!memo.has(key)) memo.set(key, readEntries(tool, dataDir));
    return memo.get(key)!;
  };
}

/** The supported logins a tool's store holds, with emails but never tokens. */
export async function listStoredLogins(tool: StoredLoginTool, dataDir?: string): Promise<StoredLoginOption[]> {
  return (await readEntries(tool, dataDir)).map(({ kind, entryId, email }) => ({ kind, ...(entryId ? { entryId } : {}), ...(email ? { email } : {}) }));
}

function safeJson(value: string | null): unknown {
  try { return value ? JSON.parse(value) : null; } catch { return null; }
}

function windowFrom(limitId: string, label: string, minutes: number, used: number | null, resetsAt: string | null): UsageWindow {
  return {
    limitId, label, kind: 'provider-reported-quota', usedPercent: used, usedKind: 'provider-reported-quota',
    remainingPercent: used === null ? null : Math.round((100 - used) * 10) / 10, remainingKind: 'calculated-estimate', durationMinutes: minutes, resetsAt,
  };
}

export function normalizeChatgptUsage(input: unknown, now: number): { windows: UsageWindow[]; plan: string | null; email: string | null } {
  const root = object(input);
  const rate = object(root?.rate_limit);
  const windows: UsageWindow[] = [];
  for (const [key, id] of [['primary_window', 'primary'], ['secondary_window', 'secondary']] as const) {
    const window = object(rate?.[key]);
    if (!window) continue;
    const seconds = typeof window.limit_window_seconds === 'number' && window.limit_window_seconds > 0 ? window.limit_window_seconds : null;
    const resetAt = typeof window.reset_at === 'number' ? window.reset_at * 1000
      : typeof window.reset_after_seconds === 'number' ? now + window.reset_after_seconds * 1000 : NaN;
    // Same IDs and labels as Codex app-server windows, so merged and fallback reads share history.
    windows.push(windowFrom('codex', `codex · ${id}`, seconds ? Math.round(seconds / 60) : 0, percent(window.used_percent),
      Number.isFinite(resetAt) && resetAt > 0 ? new Date(resetAt).toISOString() : null));
  }
  const plan = text(root?.plan_type, 40);
  const email = root?.email;
  return { windows: windows.map((window) => ({ ...window, durationMinutes: window.durationMinutes || null })), plan, email: isEmail(email) ? email : null };
}

export function normalizeOpencodeGoUsage(input: unknown): UsageWindow[] {
  const usage = object(object(input)?.usage);
  const windows: UsageWindow[] = [];
  for (const [key, label, minutes] of [['rolling', 'five-hour quota', 300], ['weekly', 'weekly quota', 10080], ['monthly', 'monthly quota', 43200]] as const) {
    const entry = object(usage?.[key]);
    const resetsAt = typeof entry?.resetsAt === 'string' && Number.isFinite(Date.parse(entry.resetsAt)) ? new Date(entry.resetsAt).toISOString() : null;
    const used = percent(entry?.percent);
    if (entry && (used !== null || resetsAt)) windows.push(windowFrom(key, label, minutes, used, resetsAt));
  }
  return windows;
}

export async function readStoredLoginProfile(profile: StoredLoginProfile, options: { fetch?: typeof globalThis.fetch; now?: () => number; entries?: StoredEntriesReader } = {}): Promise<UsageAccount> {
  const tool = TOOL_NAME[profile.provider];
  const base: Pick<UsageAccount, 'id' | 'label' | 'provider' | 'plan' | 'observedAt' | 'windows' | 'resetCredits'> = {
    id: profile.id, label: profile.label, provider: profile.provider, plan: null, observedAt: null, windows: [], resetCredits: null,
  };
  const source = `${tool} ${profile.login === 'chatgpt' ? 'ChatGPT' : profile.login === 'claude' ? 'Claude' : 'OpenCode Go'} sign-in`;
  const fail = (code: string, message: string, state: UsageAccount['state'] = 'unavailable'): UsageAccount => ({ ...base, source, state, errors: [{ code, message }] });
  const entry = (await (options.entries ?? readEntries)(profile.provider, profile.dataDir)).find((item) => item.kind === profile.login && (!profile.entryId || item.entryId === profile.entryId)) ?? null;
  if (!entry) return fail('stored_login_missing', `${tool} has no ${profile.login === 'opencode-go' ? 'OpenCode Go key' : `${profile.login === 'chatgpt' ? 'ChatGPT' : 'Claude'} login`} stored. Sign in from ${tool}.`, 'unauthorized');
  const token = entry.token;
  if (!token) return fail('stored_login_unreadable', `${tool}'s stored login could not be read.`);
  if (entry.reloginRequired) return fail('stored_login_relogin', `${tool} needs you to sign in again.`, 'unauthorized');
  const now = options.now?.() ?? Date.now();
  if (entry.expires !== null && entry.expires > 0 && entry.expires <= now) {
    return fail('stored_login_expired', `${tool}'s stored login has expired. Open ${tool} to refresh it.`, 'unauthorized');
  }
  try {
    if (profile.login === 'claude') {
      const result = await fetchClaudeUsage({ id: profile.id, label: profile.label, claudeConfigDir: '' }, token, { fetch: options.fetch, app: tool });
      if (result.kind !== 'ok') return result.kind === 'error' ? { ...fail(result.code, result.message, result.state), retryAfterMs: result.retryAfterMs } as UsageAccount : fail('stored_login_unreadable', 'No Claude login.');
      return { ...result.account, provider: profile.provider, service: 'claude-code', source, email: result.account.email ?? entry.email ?? null };
    }
    if (profile.login === 'chatgpt') {
      const accountId = entry.accountId ?? text(object(jwtClaims(token)?.['https://api.openai.com/auth'])?.chatgpt_account_id, 128);
      const response = await fetchJson('https://chatgpt.com/backend-api/wham/usage', { headers: {
        Authorization: `Bearer ${token}`, Accept: 'application/json', 'User-Agent': 'subset-usage/0.0.0', ...(accountId ? { 'ChatGPT-Account-Id': accountId } : {}),
      } }, { fetch: options.fetch });
      if (response.status === 401 || response.status === 403) return fail('chatgpt_unauthorized', `ChatGPT rejected ${tool}'s login. Open ${tool} to sign in again.`, 'unauthorized');
      if (response.status === 429) return { ...fail('chatgpt_rate_limited', 'ChatGPT is rate-limiting usage checks. Subset will try again in a few minutes.'), retryAfterMs: response.retryAfterMs } as UsageAccount;
      if (response.status !== 200 || !object(response.json)) return fail('chatgpt_request_failed', 'Could not read ChatGPT usage for this login.');
      const usage = normalizeChatgptUsage(response.json, now);
      const claims = jwtClaims(token);
      const email = usage.email ?? (isEmail(object(claims?.['https://api.openai.com/profile'])?.email) ? object(claims?.['https://api.openai.com/profile'])!.email as string : null);
      return { ...base, service: 'codex-chatgpt', source, plan: usage.plan, email: email ?? entry.email ?? null, observedAt: new Date().toISOString(), state: usage.windows.length ? 'ok' : 'partial', windows: usage.windows,
        errors: usage.windows.length ? [] : [{ code: 'missing_limits', message: 'ChatGPT returned no usage windows for this login.' }] };
    }
    const response = await fetchJson('https://opencode.ai/zen/go/v1/usage', { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' } }, { fetch: options.fetch });
    if (response.status === 401 || response.status === 403) return fail('opencode_unauthorized', 'OpenCode rejected the Go key.', 'unauthorized');
    if (response.status !== 200 || !object(response.json)) return fail('opencode_request_failed', 'Could not read OpenCode Go usage.');
    const windows = normalizeOpencodeGoUsage(response.json);
    return { ...base, source, plan: 'Go', observedAt: new Date().toISOString(), state: windows.length ? 'ok' : 'partial', windows,
      errors: windows.length ? [] : [{ code: 'missing_limits', message: 'OpenCode returned no Go usage windows.' }] };
  } catch {
    return fail('stored_login_request_failed', `Could not read usage for ${tool}'s login.`);
  }
}

/**
 * Who a profile's stored login belongs to, read locally without contacting the provider: email,
 * ChatGPT workspace and plan (from the token's claims), and an opaque identity hash that changes
 * whenever the stored login does, for cache keys. Never includes the token.
 */
export async function storedLoginAccount(profile: Pick<StoredLoginProfile, 'provider' | 'login' | 'dataDir' | 'entryId'>, entries: StoredEntriesReader = readEntries): Promise<{ email: string | null; workspace: string | null; plan: string | null; identity: string } | null> {
  const entry = (await entries(profile.provider, profile.dataDir)).find((item) => item.kind === profile.login && (!profile.entryId || item.entryId === profile.entryId));
  if (!entry) return null;
  const auth = object(entry.token ? jwtClaims(entry.token)?.['https://api.openai.com/auth'] : null);
  const workspace = entry.accountId ?? text(auth?.chatgpt_account_id, 128);
  const plan = text(auth?.chatgpt_plan_type, 40);
  const identity = createHash('sha256').update(JSON.stringify([entry.kind, entry.entryId ?? null, workspace, entry.email ?? null, entry.token, entry.reloginRequired])).digest('hex').slice(0, 24);
  return { email: entry.email ?? null, workspace, plan, identity };
}

/** The email a profile's stored login belongs to, read locally without contacting the provider. */
export async function storedLoginEmail(profile: Pick<StoredLoginProfile, 'provider' | 'login' | 'dataDir' | 'entryId'>, entries: StoredEntriesReader = readEntries): Promise<string | null> {
  const entry = (await entries(profile.provider, profile.dataDir)).find((item) => item.kind === profile.login && (!profile.entryId || item.entryId === profile.entryId));
  return entry?.email ?? null;
}
