import { createHash } from 'node:crypto';
import { userInfo } from 'node:os';
import { join, resolve } from 'node:path';
import type { UsageAccount, UsageWindow } from './index.js';
import { fetchJson, readKeychainSecret, readSmallFile, type SecretReader } from './local-auth.js';

/**
 * Live Claude subscription usage from the Claude Code sign-in stored for one config directory.
 * Opt-in only. It reads the stored OAuth access token, never the refresh token's endpoint:
 * Anthropic rotates refresh tokens, so refreshing here would sign the CLI out. Freshness is
 * left to `claude auth status`, which the host runs first. The usage endpoint is the one
 * Claude Code itself calls; it is not a documented public API and can change.
 */
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const KEYCHAIN_SERVICE = 'Claude Code-credentials';

export interface ClaudeOAuthProfile { id: string; label: string; claudeConfigDir: string }

interface StoredClaude { accessToken: string; expiresAt: number | null; subscriptionType: string | null; rateLimitTier: string | null }

const object = (value: unknown): Record<string, unknown> | null => value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
const percent = (value: unknown): number | null => typeof value === 'number' && Number.isFinite(value) ? Math.min(100, Math.max(0, Math.round(value * 10) / 10)) : null;
const isoTime = (value: unknown): string | null => {
  if (typeof value !== 'string' || value.length > 40) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? new Date(time).toISOString() : null;
};

function parseStored(text: string | null): StoredClaude | null {
  if (!text) return null;
  let raw = text.trim();
  // Some keychain entries are stored hex-encoded.
  if (!raw.startsWith('{') && /^[0-9a-f]+$/i.test(raw) && raw.length % 2 === 0) raw = Buffer.from(raw, 'hex').toString('utf8');
  try {
    const oauth = object(object(JSON.parse(raw))?.claudeAiOauth);
    const accessToken = typeof oauth?.accessToken === 'string' && oauth.accessToken.length < 8192 ? oauth.accessToken : null;
    if (!accessToken) return null;
    return {
      accessToken,
      expiresAt: typeof oauth?.expiresAt === 'number' && Number.isFinite(oauth.expiresAt) ? oauth.expiresAt : null,
      subscriptionType: typeof oauth?.subscriptionType === 'string' && /^[a-z0-9_-]{1,40}$/i.test(oauth.subscriptionType) ? oauth.subscriptionType : null,
      rateLimitTier: typeof oauth?.rateLimitTier === 'string' && oauth.rateLimitTier.length <= 80 ? oauth.rateLimitTier : null,
    };
  } catch { return null; }
}

/** Turns a stored tier such as `default_claude_max_20x` into `Max 20x`. */
export function claudeTierName(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 80) return null;
  const match = /claude_(max|pro|team|enterprise)(?:_(\d+x))?/i.exec(value);
  if (!match) return null;
  const plan = `${match[1].charAt(0).toUpperCase()}${match[1].slice(1).toLowerCase()}`;
  return match[2] ? `${plan} ${match[2].toLowerCase()}` : plan;
}

/**
 * Plan label from the stored subscription type and rate-limit tier. The tier carries the usage
 * multiple (for example `default_claude_max_5x`) even for Team seats, so the subscription type
 * decides the plan: a Team seat with a multiple is a Premium seat.
 */
export function claudePlanName(subscriptionType: string | null, rateLimitTier: string | null): string | null {
  const multiple = rateLimitTier ? /_(\d+x)\b/i.exec(rateLimitTier)?.[1]?.toLowerCase() : undefined;
  const type = subscriptionType?.toLowerCase();
  if (type === 'team') return multiple ? `Team Premium ${multiple}` : 'Team';
  if (type === 'enterprise') return multiple ? `Enterprise ${multiple}` : 'Enterprise';
  if (type === 'max') return multiple ? `Max ${multiple}` : 'Max';
  if (type === 'pro') return 'Pro';
  return claudeTierName(rateLimitTier) ?? subscriptionType;
}

/** Claude Code names the keychain item for a custom config directory by the first 8 hex of its SHA-256. */
export function claudeKeychainService(configDir: string, isDefault: boolean): string {
  return isDefault ? KEYCHAIN_SERVICE : `${KEYCHAIN_SERVICE}-${createHash('sha256').update(configDir.normalize('NFC')).digest('hex').slice(0, 8)}`;
}

async function readStored(configDir: string, isDefault: boolean, readSecret: SecretReader): Promise<StoredClaude | null> {
  let account: string | undefined;
  try { account = userInfo().username; } catch { account = undefined; }
  // Try the spellings a user may have exported as CLAUDE_CONFIG_DIR.
  const spellings = isDefault ? [configDir] : [...new Set([configDir, `${configDir}/`, resolve(configDir)])];
  for (const spelling of spellings) {
    const service = claudeKeychainService(spelling, isDefault);
    const stored = parseStored(await readSecret(service, account)) ?? parseStored(account ? await readSecret(service) : null);
    if (stored) return stored;
  }
  return parseStored(await readSmallFile(join(configDir, '.credentials.json')));
}

export function normalizeClaudeOAuthUsage(profile: ClaudeOAuthProfile, input: unknown, observedAt: Date, plan: string | null = null): UsageAccount {
  const root = object(input);
  const windows: UsageWindow[] = [];
  const seen = new Set<string>();
  const push = (limitId: string, label: string, used: number | null, resetsAt: string | null, durationMinutes: number) => {
    if ((used === null && !resetsAt) || seen.has(limitId) || windows.length >= 20) return;
    seen.add(limitId);
    windows.push({
      limitId, label, kind: 'provider-reported-quota', usedPercent: used, usedKind: 'provider-reported-quota',
      remainingPercent: used === null ? null : Math.round((100 - used) * 10) / 10, remainingKind: 'calculated-estimate', durationMinutes, resetsAt,
    });
  };
  for (const [key, label, minutes] of [['five_hour', 'Five-hour quota', 300], ['seven_day', 'Seven-day quota', 10080]] as const) {
    const window = object(root?.[key]);
    if (window) push(key, label, percent(window.utilization), isoTime(window.resets_at), minutes);
  }
  // Per-model weekly limits arrive as weekly_scoped entries; older responses used seven_day_<model>.
  for (const entry of Array.isArray(root?.limits) ? root.limits.slice(0, 20) : []) {
    const scoped = object(entry);
    const name = object(object(scoped?.scope)?.model)?.display_name;
    if (scoped?.kind !== 'weekly_scoped' || typeof name !== 'string') continue;
    const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '');
    if (!slug || slug.length > 24) continue;
    push(`seven_day_${slug}`, `Seven-day ${name.slice(0, 24)} quota`, percent(scoped.percent), isoTime(scoped.resets_at), 10080);
  }
  for (const model of ['fable', 'opus', 'sonnet', 'haiku']) {
    const window = object(root?.[`seven_day_${model}`]);
    // Same label as the status-line snapshot, so history keys match across sources.
    if (window) push(`seven_day_${model}`, `Seven-day ${model.charAt(0).toUpperCase()}${model.slice(1)} quota`, percent(window.utilization), isoTime(window.resets_at), 10080);
  }
  const incomplete = windows.some((window) => window.usedPercent === null || window.resetsAt === null);
  return {
    id: profile.id, label: profile.label, provider: 'claude-code', source: 'Claude usage (local sign-in)', plan,
    observedAt: observedAt.toISOString(), state: windows.length ? (incomplete ? 'partial' : 'ok') : 'partial', windows, resetCredits: null,
    errors: windows.length ? [] : [{ code: 'missing_quota', message: 'Claude returned no subscription usage windows for this sign-in.' }],
  };
}

export type ClaudeOAuthResult =
  | { kind: 'ok'; account: UsageAccount }
  | { kind: 'no-credential' }
  | { kind: 'error'; code: string; message: string; state: UsageAccount['state']; retryAfterMs?: number | null };

export async function readClaudeOAuthUsage(profile: ClaudeOAuthProfile, options: {
  isDefault: boolean; fetch?: typeof globalThis.fetch; readSecret?: SecretReader; now?: () => number;
}): Promise<ClaudeOAuthResult> {
  const stored = await readStored(resolve(profile.claudeConfigDir), options.isDefault, options.readSecret ?? readKeychainSecret);
  if (!stored) return { kind: 'no-credential' };
  const now = options.now?.() ?? Date.now();
  if (stored.expiresAt !== null && stored.expiresAt <= now) {
    return { kind: 'error', code: 'claude_token_expired', state: 'unauthorized', message: 'The local Claude Code sign-in has expired. Open Claude Code with this account to refresh it.' };
  }
  return fetchClaudeUsage(profile, stored.accessToken, { plan: claudePlanName(stored.subscriptionType, stored.rateLimitTier), fetch: options.fetch });
}

/** Reads Claude subscription usage with an access token another local tool already holds. */
export async function fetchClaudeUsage(profile: ClaudeOAuthProfile, accessToken: string, options: { plan?: string | null; fetch?: typeof globalThis.fetch; app?: string } = {}): Promise<ClaudeOAuthResult> {
  const app = options.app ?? 'Claude Code';
  try {
    const response = await fetchJson(USAGE_URL, { headers: {
      Authorization: `Bearer ${accessToken}`, Accept: 'application/json', 'anthropic-beta': 'oauth-2025-04-20', 'User-Agent': 'subset-usage/0.0.0',
    } }, { fetch: options.fetch });
    if (response.status === 401 || response.status === 403) return { kind: 'error', code: 'claude_unauthorized', state: 'unauthorized', message: `Claude rejected the local sign-in. Open ${app} with this account to sign in again.` };
    if (response.status === 429) return { kind: 'error', code: 'claude_rate_limited', state: 'unavailable', message: 'Claude is rate-limiting usage checks. Subset will try again in a few minutes.', retryAfterMs: response.retryAfterMs };
    if (response.status < 200 || response.status >= 300 || !object(response.json)) return { kind: 'error', code: 'claude_request_failed', state: 'unavailable', message: 'Could not read Claude usage for this sign-in.' };
    const account = normalizeClaudeOAuthUsage(profile, response.json, new Date(), options.plan ?? null);
    // Extra usage is paid usage beyond the plan, reported in cents.
    const extra = object(object(response.json)?.extra_usage);
    const usedCents = typeof extra?.used_credits === 'number' && Number.isFinite(extra.used_credits) && extra.used_credits >= 0 ? extra.used_credits : null;
    const limitCents = typeof extra?.monthly_limit === 'number' && Number.isFinite(extra.monthly_limit) && extra.monthly_limit > 0 ? extra.monthly_limit : null;
    if (extra && extra.is_enabled !== false && usedCents !== null) {
      account.spend = { kind: 'provider-reported-spend', currency: 'USD', label: 'Extra usage', used: usedCents / 100, limit: limitCents === null ? null : limitCents / 100, includedUsed: null, periodStart: null, periodEnd: null };
    }
    return { kind: 'ok', account };
  } catch {
    return { kind: 'error', code: 'claude_request_failed', state: 'unavailable', message: 'Could not read Claude usage for this sign-in.' };
  }
}
