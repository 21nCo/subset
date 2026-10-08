import { homedir } from 'node:os';
import { join } from 'node:path';
import { isEmail, type UsageAccount, type UsageWindow } from './index.js';
import { fetchJson, readSmallFile } from './local-auth.js';

/**
 * Devin quota from the Windsurf seat-status endpoint the Devin CLI uses (undocumented). The key
 * comes from `devin auth login`'s credentials.toml (opt-in local sign-ins) or a named environment
 * variable. Only https servers on codeium.com, windsurf.com, or devin.ai are contacted.
 */
export interface DevinProfile { id: string; label: string; provider: 'devin'; credentialEnv?: string }

const DEFAULT_SERVER = 'https://server.codeium.com';
const STATUS_PATH = '/exa.seat_management_pb.SeatManagementService/GetUserStatus';
const object = (value: unknown): Record<string, unknown> | null => value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
const pick = (record: Record<string, unknown> | null, ...keys: string[]): unknown => keys.map((key) => record?.[key]).find((value) => value !== undefined && value !== null);
const number = (value: unknown): number | null => {
  const parsed = typeof value === 'string' && /^\d+(\.\d+)?$/.test(value) ? Number(value) : value;
  return typeof parsed === 'number' && Number.isFinite(parsed) ? parsed : null;
};

export function devinCredentialsFile(env: NodeJS.ProcessEnv = process.env): string {
  return join(env.XDG_DATA_HOME || join(homedir(), '.local', 'share'), 'devin', 'credentials.toml');
}

/** Reads `key = "value"` pairs from Devin's flat credentials file. */
export function parseDevinCredentials(text: string | null): { apiKey: string | null; server: string } {
  const values = new Map<string, string>();
  for (const line of (text ?? '').split('\n').slice(0, 200)) {
    const match = /^\s*([a-z_]+)\s*=\s*"([^"\n]{1,4096})"\s*$/.exec(line);
    if (match) values.set(match[1], match[2]);
  }
  return { apiKey: values.get('windsurf_api_key') ?? null, server: values.get('api_server_url') ?? DEFAULT_SERVER };
}

export function allowedDevinServer(value: string): string | null {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    return url.protocol === 'https:' && !url.username && !url.password && ['codeium.com', 'windsurf.com', 'devin.ai'].some((domain) => host === domain || host.endsWith(`.${domain}`)) ? url.origin : null;
  } catch { return null; }
}

export function normalizeDevinStatus(profile: DevinProfile, input: unknown, observedAt: Date): UsageAccount {
  const root = object(input);
  const user = object(pick(root, 'userStatus', 'user_status')) ?? root;
  const plan = object(pick(user, 'planStatus', 'plan_status'));
  const info = object(pick(plan, 'planInfo', 'plan_info')) ?? object(pick(user, 'planInfo', 'plan_info'));
  const windows: UsageWindow[] = [];
  for (const [id, label, minutes, remainingKeys, resetKeys] of [
    ['daily', 'Daily quota', 1440, ['dailyQuotaRemainingPercent', 'daily_quota_remaining_percent'], ['dailyQuotaResetAtUnix', 'daily_quota_reset_at_unix']],
    ['weekly', 'Weekly quota', 10080, ['weeklyQuotaRemainingPercent', 'weekly_quota_remaining_percent'], ['weeklyQuotaResetAtUnix', 'weekly_quota_reset_at_unix']],
  ] as const) {
    const remaining = number(pick(plan, ...remainingKeys));
    if (remaining === null || remaining < 0 || remaining > 100) continue;
    if (id === 'daily' && (info?.hideDailyQuota === true || info?.hide_daily_quota === true)) continue;
    const reset = number(pick(plan, ...resetKeys));
    windows.push({
      limitId: id, label, kind: 'provider-reported-quota', usedPercent: Math.round((100 - remaining) * 10) / 10, usedKind: 'calculated-estimate',
      remainingPercent: remaining, remainingKind: 'provider-reported-quota', durationMinutes: minutes,
      resetsAt: reset !== null && reset > 0 && reset < 253402300799 ? new Date(reset * 1000).toISOString() : null,
    });
  }
  const planName = pick(info, 'planName', 'plan_name');
  const email = pick(user, 'email');
  return {
    id: profile.id, label: profile.label, provider: 'devin', source: 'Devin seat status', plan: typeof planName === 'string' && planName.length <= 60 ? planName : null,
    email: isEmail(email) ? email : null, observedAt: observedAt.toISOString(), state: windows.length ? 'ok' : 'partial', windows, resetCredits: null,
    errors: windows.length ? [] : [{ code: 'devin_no_quota', message: 'Devin did not report daily or weekly quota for this plan.' }],
  };
}

export async function readDevinProfile(profile: DevinProfile, options: {
  localCredentials: boolean; env?: NodeJS.ProcessEnv; fetch?: typeof globalThis.fetch; credentialsFile?: string;
}): Promise<UsageAccount> {
  const fail = (code: string, message: string, state: UsageAccount['state'] = 'unavailable'): UsageAccount => ({
    id: profile.id, label: profile.label, provider: 'devin', source: 'Devin seat status', plan: null, observedAt: null, state, windows: [], resetCredits: null, errors: [{ code, message }],
  });
  const env = options.env ?? process.env;
  let apiKey = profile.credentialEnv && Object.hasOwn(env, profile.credentialEnv) ? env[profile.credentialEnv] ?? null : null;
  let server = DEFAULT_SERVER;
  // A profile with a configured key never falls back to the default local sign-in, which may be another account.
  if (profile.credentialEnv && !apiKey) return fail('devin_missing_key', 'The configured Devin API key variable is not set for the usage server.', 'unauthorized');
  if (!apiKey && options.localCredentials) {
    const stored = parseDevinCredentials(await readSmallFile(options.credentialsFile ?? devinCredentialsFile(env)));
    apiKey = stored.apiKey;
    const allowed = allowedDevinServer(stored.server);
    if (!allowed) return fail('devin_server_rejected', 'Devin is configured for a server this dashboard does not contact.');
    server = allowed;
  }
  if (!apiKey || apiKey.length > 4096) {
    return fail('devin_signed_out', options.localCredentials ? 'Devin is not signed in. Run devin auth login.' : 'Add a Devin API key variable, or turn on local sign-ins in Settings.', 'unauthorized');
  }
  try {
    const response = await fetchJson(`${server}${STATUS_PATH}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, Accept: 'application/json', 'Content-Type': 'application/json', 'Connect-Protocol-Version': '1' },
      body: JSON.stringify({ metadata: { apiKey, ideName: 'devin', ideVersion: '0.0.0', extensionName: 'devin', extensionVersion: '0.0.0', locale: 'en' } }),
    }, { fetch: options.fetch });
    if (response.status === 401 || response.status === 403) return fail('devin_unauthorized', 'Devin rejected this sign-in. Run devin auth login.', 'unauthorized');
    if (response.status === 429) return { ...fail('devin_rate_limited', 'Devin is rate-limiting usage checks. Try again later.'), retryAfterMs: response.retryAfterMs } as UsageAccount;
    if (response.status !== 200 || !object(response.json)) return fail('devin_request_failed', 'Could not read Devin usage.');
    return normalizeDevinStatus(profile, response.json, new Date());
  } catch {
    return fail('devin_request_failed', 'Could not read Devin usage.');
  }
}
