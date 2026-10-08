import { createDecipheriv } from 'node:crypto';
import { join, resolve } from 'node:path';
import { isEmail, type UsageAccount, type UsageWindow } from './index.js';
import { fetchJson, fileExists, jwtClaims, readKeychainSecret, readSmallFile, type SecretReader } from './local-auth.js';

/**
 * Factory Droid rate limits from the endpoint Droid's own /limits view calls. Factory does not
 * document it, so it can change without notice. Two read-only authorization modes:
 * - a Factory API key the user supplies through a named environment variable, or
 * - (opt-in) the Droid sign-in stored under one Factory home, decrypted with its key from the OS
 *   keychain or key file. Tokens are never refreshed or written; an expired one asks the user to run Droid.
 */
export interface FactoryProfile {
  id: string;
  label: string;
  provider: 'factory-droid';
  /** Directory whose `.factory` folder holds this account (FACTORY_HOME_OVERRIDE, or the user's home). */
  factoryHome: string;
  credentialEnv?: string;
}

const API = { global: 'https://api.factory.ai', eu: 'https://api.eu.factory.ai' } as const;
const object = (value: unknown): Record<string, unknown> | null => value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
const text = (value: unknown, max = 256): string | null => typeof value === 'string' && value.length > 0 && value.length <= max ? value : null;
const percent = (value: unknown): number | null => typeof value === 'number' && Number.isFinite(value) ? Math.min(100, Math.max(0, Math.round(value * 10) / 10)) : null;
const isoTime = (value: unknown): string | null => {
  if (typeof value !== 'string' && typeof value !== 'number') return null;
  const time = typeof value === 'number' ? value : Date.parse(value);
  return Number.isFinite(time) && time > 0 && time < 253402300799000 ? new Date(time).toISOString() : null;
};

interface FactoryAuth { token: string; orgId: string | null; region: 'global' | 'eu'; email: string | null; expiresAt: number | null }

/** Factory's v2 store is `base64(iv):base64(tag):base64(ciphertext)`, AES-256-GCM. */
export function decryptFactoryCredential(contents: string, key: Buffer): unknown {
  const parts = contents.trim().split(':');
  if (key.length !== 32 || parts.length !== 3) return null;
  try {
    const [iv, tag, data] = parts.map((part) => Buffer.from(part, 'base64'));
    if (iv.length !== 16 || tag.length !== 16 || !data.length) return null;
    const decipher = createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(tag);
    return JSON.parse(Buffer.concat([decipher.update(data), decipher.final()]).toString('utf8'));
  } catch { return null; }
}

const decodeKey = (value: string | null): Buffer | null => {
  const trimmed = value?.trim() ?? '';
  if (!/^[A-Za-z0-9+/]{43}=$/.test(trimmed)) return null;
  const key = Buffer.from(trimmed, 'base64');
  return key.length === 32 ? key : null;
};

/** Returns the stored sign-in, `null` when none exists, or `'unreadable'` when one exists but cannot be opened. */
export async function readFactoryLocalAuth(factoryHome: string, readSecret: SecretReader = readKeychainSecret): Promise<FactoryAuth | null | 'unreadable'> {
  const directory = join(resolve(factoryHome), '.factory');
  const layouts = [
    ['auth.v2.loginkeychain', 'auth-encryption-key-security-cli'],
    ['auth.v2.keyring', 'auth-encryption-key'],
    ['auth.v2.file', null],
  ] as const;
  for (const [name, keychainAccount] of layouts) {
    const path = join(directory, name);
    if (!(await fileExists(path))) continue;
    // A newer store that exists but cannot be read must not fall back to an older account's file.
    const contents = await readSmallFile(path);
    const key = decodeKey(keychainAccount ? await readSecret('Factory CLI', keychainAccount) : await readSmallFile(join(directory, 'auth.v2.key')));
    if (!contents || !key) return 'unreadable';
    try {
      const record = object(decryptFactoryCredential(contents, key));
      const token = text(record?.access_token, 16_384);
      if (!token) return 'unreadable';
      const claims = jwtClaims(token);
      return {
        token, orgId: text(record?.active_organization_id, 128), region: record?.region === 'eu' ? 'eu' : 'global',
        email: isEmail(claims?.email) ? claims.email : null,
        expiresAt: typeof claims?.exp === 'number' ? claims.exp * 1000 : null,
      };
    } finally { key.fill(0); }
  }
  return null;
}

export function normalizeFactoryLimits(profile: FactoryProfile, input: unknown, observedAt: Date, auth: { email: string | null; source: string }): UsageAccount {
  const root = object(input);
  const limits = object(root?.limits);
  const base: UsageAccount = {
    id: profile.id, label: profile.label, provider: 'factory-droid', source: auth.source, plan: null, email: auth.email,
    observedAt: observedAt.toISOString(), state: 'ok', windows: [], resetCredits: null, errors: [],
  };
  const standard = object(limits?.standard);
  if (root?.usesTokenRateLimitsBilling === false || !standard) {
    return { ...base, state: 'unsupported', errors: [{ code: 'factory_no_rate_limits', message: 'This Factory organization does not report personal rate limits.' }] };
  }
  const windows: UsageWindow[] = [];
  for (const [group, prefix, values] of [['standard', '', standard], ['core', 'Core ', object(limits?.core)]] as const) {
    for (const [key, label, minutes] of [['fiveHour', 'five-hour', 300], ['weekly', 'weekly', 10080], ['monthly', 'monthly', 43200]] as const) {
      const window = object(values?.[key]);
      const used = percent(window?.usedPercent);
      const resetsAt = isoTime(window?.windowEnd);
      if (!window || (used === null && !resetsAt)) continue;
      windows.push({
        limitId: `${group}_${key}`, label: `${prefix}${label} quota`, kind: 'provider-reported-quota', usedPercent: used, usedKind: 'provider-reported-quota',
        remainingPercent: used === null ? null : Math.round((100 - used) * 10) / 10, remainingKind: 'calculated-estimate', durationMinutes: minutes, resetsAt,
      });
    }
  }
  const extra = root?.extraUsageBalanceCents;
  // An unused window has no end yet; that is not missing data.
  const incomplete = windows.some((window) => window.usedPercent === null || (window.resetsAt === null && window.usedPercent > 0));
  return {
    ...base, windows, state: !windows.length || incomplete ? 'partial' : 'ok',
    ...(typeof extra === 'number' && Number.isFinite(extra) && extra >= 0
      ? { balances: [{ kind: 'provider-reported-balance' as const, currency: 'USD' as const, amount: Math.round(extra) / 100, label: 'Extra usage balance' }] }
      : {}),
    errors: windows.length ? [] : [{ code: 'missing_limits', message: 'Factory returned no readable rate-limit windows.' }],
  };
}

export async function readFactoryProfile(profile: FactoryProfile, options: {
  localCredentials: boolean; env?: NodeJS.ProcessEnv; fetch?: typeof globalThis.fetch; readSecret?: SecretReader; now?: () => number;
}): Promise<UsageAccount> {
  const fail = (code: string, message: string, state: UsageAccount['state'] = 'unavailable'): UsageAccount => ({
    id: profile.id, label: profile.label, provider: 'factory-droid', source: 'Factory rate limits', plan: null, observedAt: null, state, windows: [], resetCredits: null,
    errors: [{ code, message }],
  });
  const now = options.now?.() ?? Date.now();
  let auth: FactoryAuth | null = null;
  let source = 'Factory rate limits (API key)';
  let localState: FactoryAuth | null | 'unreadable' = null;
  // A profile with a configured key always reads that key's account; only key-less profiles use the local sign-in.
  if (options.localCredentials && !profile.credentialEnv) {
    localState = await readFactoryLocalAuth(profile.factoryHome, options.readSecret);
    if (localState && localState !== 'unreadable') {
      if (localState.expiresAt !== null && localState.expiresAt <= now) return fail('factory_token_expired', 'The local Droid sign-in has expired. Run droid with this account to refresh it.', 'unauthorized');
      auth = localState; source = 'Factory rate limits (local sign-in)';
    }
  }
  try {
    if (!auth) {
      const env = options.env ?? process.env;
      const key = profile.credentialEnv && Object.hasOwn(env, profile.credentialEnv) ? env[profile.credentialEnv] : undefined;
      if (!key || key.length > 4096 || !/^[\x21-\x7e]+$/.test(key)) {
        if (localState === 'unreadable') return fail('factory_local_unreadable', 'Droid is signed in, but its stored sign-in could not be read. Allow keychain access, or use an API key.');
        return options.localCredentials && !profile.credentialEnv
          ? fail('factory_signed_out', 'No Droid sign-in was found for this Factory home. Sign in with droid, or set an API key variable.', 'unauthorized')
          : fail('factory_missing_key', profile.credentialEnv ? 'The configured Factory API key variable is not set for the usage server.' : 'Add a Factory API key variable, or turn on local sign-ins in Settings.', 'unauthorized');
      }
      const whoami = await fetchJson(`${API.global}/api/cli/whoami`, { headers: { Authorization: `Bearer ${key}`, Accept: 'application/json', 'X-Factory-Whoami-Extended': 'true' } }, { fetch: options.fetch });
      if (whoami.status === 401 || whoami.status === 403) return fail('factory_unauthorized', 'Factory rejected the API key.', 'unauthorized');
      const identity = object(whoami.json);
      const orgId = text(identity?.orgId, 128);
      if (whoami.status !== 200 || !orgId || identity?.isOnPrem === true) return fail('factory_identity_failed', 'Could not identify the Factory account for this API key.');
      auth = { token: key, orgId, region: identity?.region === 'eu' ? 'eu' : 'global', email: isEmail(identity?.email) ? identity.email as string : null, expiresAt: null };
    }
    const response = await fetchJson(`${API[auth.region]}/api/billing/limits`, { headers: {
      Authorization: `Bearer ${auth.token}`, Accept: 'application/json', ...(auth.orgId ? { 'X-Factory-Org-Id': auth.orgId } : {}),
    } }, { fetch: options.fetch });
    if (response.status === 401 || response.status === 403) return fail('factory_unauthorized', 'Factory rejected this sign-in. Run droid to sign in again.', 'unauthorized');
    if (response.status === 429) return fail('factory_rate_limited', 'Factory is rate-limiting usage checks. Try again later.');
    if (response.status !== 200 || !object(response.json)) return fail('factory_request_failed', 'Could not read Factory rate limits.');
    return normalizeFactoryLimits(profile, response.json, new Date(), { email: auth.email, source });
  } catch {
    return fail('factory_request_failed', 'Could not read Factory rate limits.');
  }
}
