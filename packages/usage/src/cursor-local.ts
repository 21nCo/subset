import { execFile } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { isEmail, type UsageAccount } from './index.js';
import { fetchJson, jwtClaims, readKeychainSecret, type SecretReader } from './local-auth.js';

/**
 * Personal Cursor usage with the desktop app's own sign-in (opt-in local sign-ins). The access
 * token is read from the macOS keychain item Cursor keeps, or from its state.vscdb through the
 * system sqlite3 in read-only mode. The DashboardService endpoints are the ones Cursor's own
 * settings page calls; Cursor does not document them.
 */
export interface CursorLocalProfile { id: string; label: string; provider: 'cursor-local' }

const API = 'https://api2.cursor.sh/aiserver.v1.DashboardService';
const object = (value: unknown): Record<string, unknown> | null => value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
const number = (value: unknown): number | null => {
  const parsed = typeof value === 'string' && /^-?\d+(\.\d+)?$/.test(value) ? Number(value) : value;
  return typeof parsed === 'number' && Number.isFinite(parsed) ? parsed : null;
};

export function cursorStateDb(): string {
  return process.platform === 'darwin'
    ? join(homedir(), 'Library', 'Application Support', 'Cursor', 'User', 'globalStorage', 'state.vscdb')
    : join(homedir(), '.config', 'Cursor', 'User', 'globalStorage', 'state.vscdb');
}

/** Reads one key from Cursor's state database without writing to it. */
function readStateValue(key: string, file = cursorStateDb()): Promise<string | null> {
  return new Promise((resolve) => {
    execFile('/usr/bin/sqlite3', ['-readonly', file, `select value from ItemTable where key = '${key.replace(/'/g, "''")}' limit 1;`], {
      encoding: 'utf8', timeout: 5000, maxBuffer: 64 * 1024, killSignal: 'SIGKILL', env: { PATH: '/usr/bin:/bin' },
    }, (error, stdout) => resolve(error ? null : stdout.trim() || null));
  });
}

export function normalizeCursorLocalUsage(profile: CursorLocalProfile, usageInput: unknown, creditsInput: unknown, observedAt: Date, extra: { plan: string | null; email: string | null }): UsageAccount {
  const usage = object(usageInput);
  const planUsage = object(usage?.planUsage);
  const spendLimit = object(usage?.spendLimitUsage);
  const cycleEnd = number(usage?.billingCycleEnd);
  const cycleStart = number(usage?.billingCycleStart);
  const resetsAt = cycleEnd !== null && cycleEnd > 0 ? new Date(cycleEnd).toISOString() : null;
  const durationMinutes = cycleStart !== null && cycleEnd !== null && cycleEnd > cycleStart ? Math.round((cycleEnd - cycleStart) / 60_000) : null;
  const windows: UsageAccount['windows'] = [];
  // Cursor splits included usage between Auto (with Composer) and named API models.
  for (const [limitId, label, key] of [['total', 'Total usage', 'totalPercentUsed'], ['auto', 'Auto + Composer', 'autoPercentUsed'], ['api', 'API models', 'apiPercentUsed']] as const) {
    const used = number(planUsage?.[key]);
    if (used === null) continue;
    const clamped = Math.min(100, Math.max(0, Math.round(used * 10) / 10));
    windows.push({ limitId, label, kind: 'provider-reported-quota', usedPercent: clamped, usedKind: 'provider-reported-quota', remainingPercent: Math.round((100 - clamped) * 10) / 10, remainingKind: 'calculated-estimate', durationMinutes, resetsAt });
  }
  const cents = (value: unknown) => { const parsed = number(value); return parsed === null || parsed < 0 ? null : parsed / 100; };
  const included = cents(planUsage?.includedSpend);
  const includedLimit = cents(planUsage?.limit);
  const bonus = cents(planUsage?.bonusSpend);
  const pooled = cents(spendLimit?.pooledUsed);
  const individualLimit = cents(spendLimit?.individualLimit);
  const individualRemaining = cents(spendLimit?.individualRemaining);
  const credits = object(creditsInput);
  const totalCredits = cents(credits?.totalCents);
  const balances: NonNullable<UsageAccount['balances']> = [];
  if (bonus !== null && bonus > 0) balances.push({ kind: 'provider-reported-amount', currency: 'USD', amount: bonus, label: 'Bonus usage', note: 'Beyond included usage, at no charge' });
  if (individualLimit !== null && individualLimit > 0) balances.push({ kind: 'provider-reported-amount', currency: 'USD', amount: individualRemaining !== null ? Math.max(0, individualLimit - individualRemaining) : 0, label: 'On-demand spend', note: `Limit $${individualLimit.toFixed(2)}` });
  if (pooled !== null && pooled > 0 && spendLimit?.limitType === 'team') balances.push({ kind: 'provider-reported-amount', currency: 'USD', amount: pooled, label: 'Team pooled spend', note: 'All members this cycle' });
  if (credits?.hasCreditGrants !== false && totalCredits !== null && totalCredits > 0) {
    balances.push({ kind: 'provider-reported-balance', currency: 'USD', amount: Math.max(0, totalCredits - (cents(credits?.usedCents) ?? 0)), label: 'Credits remaining', note: `of $${totalCredits.toFixed(2)} granted` });
  }
  return {
    id: profile.id, label: profile.label, provider: 'cursor-local', source: 'Cursor dashboard (local sign-in)', plan: extra.plan, email: extra.email,
    observedAt: observedAt.toISOString(), state: windows.length ? 'ok' : 'partial', windows, resetCredits: null,
    ...(included !== null ? { spend: {
      kind: 'provider-reported-spend' as const, currency: 'USD' as const, label: 'Included usage', used: included, limit: includedLimit, includedUsed: null,
      periodStart: cycleStart !== null ? new Date(cycleStart).toISOString() : null, periodEnd: resetsAt,
    } } : {}),
    ...(balances.length ? { balances } : {}),
    errors: windows.length ? [] : [{ code: 'missing_limits', message: 'Cursor returned no plan usage for this sign-in.' }],
  };
}

export async function readCursorLocalProfile(profile: CursorLocalProfile, options: { fetch?: typeof globalThis.fetch; readSecret?: SecretReader; readState?: (key: string) => Promise<string | null> } = {}): Promise<UsageAccount> {
  const fail = (code: string, message: string, state: UsageAccount['state'] = 'unavailable'): UsageAccount => ({
    id: profile.id, label: profile.label, provider: 'cursor-local', source: 'Cursor dashboard (local sign-in)', plan: null, observedAt: null, state, windows: [], resetCredits: null, errors: [{ code, message }],
  });
  const readState = options.readState ?? ((key: string) => readStateValue(key));
  const token = (await (options.readSecret ?? readKeychainSecret)('cursor-access-token')) ?? await readState('cursorAuth/accessToken');
  if (!token || token.length > 16_384) return fail('cursor_signed_out', 'Cursor is not signed in on this computer.', 'unauthorized');
  const claims = jwtClaims(token);
  if (typeof claims?.exp === 'number' && claims.exp * 1000 <= Date.now()) return fail('cursor_token_expired', 'Cursor\'s sign-in has expired. Open Cursor to refresh it.', 'unauthorized');
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json', 'Connect-Protocol-Version': '1' };
  try {
    const usage = await fetchJson(`${API}/GetCurrentPeriodUsage`, { method: 'POST', headers, body: '{}' }, { fetch: options.fetch });
    if (usage.status === 401 || usage.status === 403) return fail('cursor_unauthorized', 'Cursor rejected the local sign-in. Open Cursor to sign in again.', 'unauthorized');
    if (usage.status === 429) return { ...fail('cursor_rate_limited', 'Cursor is rate-limiting usage checks. Subset will try again later.'), retryAfterMs: usage.retryAfterMs } as UsageAccount;
    if (usage.status !== 200 || !object(usage.json)) return fail('cursor_request_failed', 'Could not read Cursor usage.');
    // Credit grants and plan info are optional; failures there do not hide plan usage. They run together.
    const [credits, planInfo, membership, email] = await Promise.all([
      fetchJson(`${API}/GetCreditGrantsBalance`, { method: 'POST', headers, body: '{}' }, { fetch: options.fetch }).catch(() => null),
      fetchJson(`${API}/GetPlanInfo`, { method: 'POST', headers, body: '{}' }, { fetch: options.fetch }).catch(() => null),
      readState('cursorAuth/stripeMembershipType'),
      readState('cursorAuth/cachedEmail'),
    ]);
    const planName = object(object(planInfo?.json)?.planInfo)?.planName;
    const plan = typeof planName === 'string' && planName.length <= 40 ? planName : membership && /^[a-z_]{1,40}$/i.test(membership) ? membership : null;
    return normalizeCursorLocalUsage(profile, usage.json, credits?.status === 200 ? credits.json : null, new Date(), { plan, email: isEmail(email) ? email : null });
  } catch {
    return fail('cursor_request_failed', 'Could not read Cursor usage.');
  }
}
