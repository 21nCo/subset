import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import type { SnapshotProfile, UsageAccount, UsageWindow } from './index.js';

const MAX_BYTES = 64 * 1024;
const MAX_WINDOWS = 32;
const MAX_SECONDS = 253402300799;
type JsonObject = Record<string, unknown>;
const object = (value: unknown): JsonObject | null => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as JsonObject : null;
// Only own data properties are consumed; inherited values and accessors are not payload data.
const own = (value: JsonObject | null, key: string): unknown => value ? Object.getOwnPropertyDescriptor(value, key)?.value : undefined;
const has = (value: JsonObject | null, key: string): boolean => !!value && Object.hasOwn(value, key);
const boundedNumber = (value: unknown, max: number): number | null => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= max ? value : null;
const safeName = (value: unknown): string | null => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,63}$/.test(value) && !['constructor', 'prototype', '__proto__'].includes(value) ? value : null;
const isoTime = (value: unknown): string | null => {
  if (typeof value !== 'string' || value.length > 35 || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return null;
  const time = Date.parse(value);
  if (!Number.isFinite(time) || time < 0 || time > MAX_SECONDS * 1000) return null;
  // Date.parse rolls impossible calendar dates forward, so check the supplied calendar day.
  const day = value.slice(0, 10);
  const calendar = new Date(`${day}T00:00:00Z`);
  return calendar.toISOString().slice(0, 10) === day ? new Date(time).toISOString() : null;
};
// Documented Claude Code windows, plus model-scoped weekly windows used only if the status line includes them.
const CLAUDE_WINDOWS: ReadonlyArray<readonly [string, string, number]> = [
  ['five_hour', 'Five-hour quota', 300],
  ['seven_day', 'Seven-day quota', 10080],
  ['seven_day_fable', 'Seven-day Fable quota', 10080],
  ['seven_day_opus', 'Seven-day Opus quota', 10080],
  ['seven_day_sonnet', 'Seven-day Sonnet quota', 10080],
  ['seven_day_haiku', 'Seven-day Haiku quota', 10080],
];
const secondsTime = (value: unknown): string | null => {
  const seconds = boundedNumber(value, MAX_SECONDS);
  return seconds === null ? null : new Date(seconds * 1000).toISOString();
};

// Antigravity names buckets `<group>-<span>`, such as `gemini-5h` or `3p-weekly`.
const ANTIGRAVITY_SPANS: Record<string, number> = { '5h': 300, hourly: 60, daily: 1440, '24h': 1440, weekly: 10080, '7d': 10080, monthly: 43200 };
export const antigravitySpan = (key: string): number | null => ANTIGRAVITY_SPANS[key.split('-').pop()?.toLowerCase() ?? ''] ?? null;

export function sanitizeSnapshot(profile: SnapshotProfile, input: unknown): unknown {
  const raw = object(input);
  const result: JsonObject = {};
  if (profile.provider === 'claude-code') {
    if (!has(raw, 'rate_limits')) return result;
    const limits = object(own(raw, 'rate_limits'));
    if (!limits) return { rate_limits: null };
    const clean: JsonObject = {};
    for (const [key] of CLAUDE_WINDOWS) {
      if (!has(limits, key)) continue;
      const window = object(own(limits, key));
      clean[key] = {
        used_percentage: boundedNumber(own(window, 'used_percentage'), 100),
        resets_at: boundedNumber(own(window, 'resets_at'), MAX_SECONDS)
      };
    }
    return { rate_limits: clean };
  }
  if (has(raw, 'plan_tier')) result.plan_tier = safeName(own(raw, 'plan_tier'));
  if (!has(raw, 'quota')) return result;
  const quota = object(own(raw, 'quota'));
  if (!quota) return { ...result, quota: null };
  const clean: JsonObject = {};
  let count = 0;
  for (const key of Object.keys(quota)) {
    if (!safeName(key)) continue;
    if (count++ >= MAX_WINDOWS) break;
    const bucket = object(own(quota, key));
    const item: JsonObject = { remaining_fraction: boundedNumber(own(bucket, 'remaining_fraction'), 1) };
    if (has(bucket, 'reset_time')) item.reset_time = isoTime(own(bucket, 'reset_time'));
    if (has(bucket, 'reset_in_seconds')) item.reset_in_seconds = boundedNumber(own(bucket, 'reset_in_seconds'), MAX_SECONDS);
    clean[key] = item;
  }
  result.quota = clean;
  return result;
}

function emptyAccount(profile: SnapshotProfile): UsageAccount {
  return {
    id: profile.id.slice(0, 64), label: profile.label.replace(/[\x00-\x1f\x7f]/g, '').slice(0, 128), provider: profile.provider,
    source: profile.provider === 'claude-code' ? 'Claude Code status-line snapshot' : 'Antigravity CLI status-line snapshot',
    plan: null, observedAt: null, state: 'unavailable', windows: [], resetCredits: null, errors: []
  };
}

function normalize(profile: SnapshotProfile, input: unknown, observedAt: Date): UsageAccount {
  const account = emptyAccount(profile);
  const time = observedAt.getTime();
  if (!Number.isFinite(time) || time < 0 || time > Date.now() || time > MAX_SECONDS * 1000) {
    account.errors.push({ code: 'invalid_observation', message: 'Snapshot observation time is invalid or in the future.' });
    return account;
  }
  account.observedAt = observedAt.toISOString();
  const data = object(sanitizeSnapshot(profile, input));
  let incomplete = false;
  if (profile.provider === 'claude-code') {
    const limits = object(own(data, 'rate_limits'));
    // Claude Code omits a window it has no data for and drops one once it resets; absence is not a partial read.
    for (const [key, label, duration] of CLAUDE_WINDOWS) {
      if (!has(limits, key)) continue;
      const raw = object(own(limits, key));
      const used = boundedNumber(own(raw, 'used_percentage'), 100);
      const resetsAt = secondsTime(own(raw, 'resets_at'));
      account.windows.push({
        limitId: key, label, kind: 'provider-reported-quota', usedPercent: used, usedKind: 'provider-reported-quota',
        remainingPercent: used === null ? null : 100 - used, remainingKind: 'calculated-estimate', durationMinutes: duration, resetsAt
      });
      if (used === null || resetsAt === null) incomplete = true;
    }
  } else {
    account.plan = safeName(own(data, 'plan_tier'));
    const quota = object(own(data, 'quota'));
    const entries = quota ? Object.entries(quota) : [];
    if (entries.length >= MAX_WINDOWS) incomplete = true;
    for (const [key, value] of entries) {
      const raw = object(value);
      const fraction = boundedNumber(own(raw, 'remaining_fraction'), 1);
      const remaining = fraction === null ? null : Math.round(fraction * 10000) / 100;
      let resetsAt = isoTime(own(raw, 'reset_time'));
      // An explicitly unavailable absolute reset must not be replaced by a countdown.
      if (!has(raw, 'reset_time')) {
        const seconds = boundedNumber(own(raw, 'reset_in_seconds'), MAX_SECONDS);
        if (seconds !== null) resetsAt = secondsTime(time / 1000 + seconds);
      }
      const window: UsageWindow = {
        limitId: key, label: key, kind: 'provider-reported-quota', usedPercent: remaining === null ? null : Math.round((100 - remaining) * 100) / 100,
        usedKind: 'calculated-estimate', remainingPercent: remaining, remainingKind: 'provider-reported-quota', durationMinutes: antigravitySpan(key), resetsAt
      };
      account.windows.push(window);
      if (remaining === null || resetsAt === null) incomplete = true;
    }
  }
  if (!account.windows.some((window) => window.usedPercent !== null || window.remainingPercent !== null)) {
    account.errors.push({ code: 'missing_quota', message: profile.provider === 'claude-code'
      ? 'Claude Code subscription quota is unavailable. Rate limits require Pro or Max and may be absent before the first API response.'
      : 'Antigravity did not supply a readable quota bucket.' });
  } else if (incomplete) {
    account.state = 'partial';
    account.errors.push({ code: 'partial_quota', message: 'Some quota windows or reset times are unavailable; at most 32 windows are retained.' });
  } else account.state = 'ok';
  return account;
}

export function normalizeClaudeSnapshot(profile: SnapshotProfile, input: unknown, observedAt: Date): UsageAccount {
  return normalize({ ...profile, provider: 'claude-code' }, input, observedAt);
}

export function normalizeAntigravitySnapshot(profile: SnapshotProfile, input: unknown, observedAt: Date): UsageAccount {
  return normalize({ ...profile, provider: 'antigravity' }, input, observedAt);
}

export function normalizeSnapshot(profile: SnapshotProfile, input: unknown, observedAt: Date): UsageAccount {
  return profile.provider === 'claude-code' ? normalizeClaudeSnapshot(profile, input, observedAt) : normalizeAntigravitySnapshot(profile, input, observedAt);
}

export async function readSnapshotProfile(profile: SnapshotProfile): Promise<UsageAccount> {
  const unavailable = (code: string, message: string) => {
    const account = emptyAccount(profile);
    account.errors.push({ code, message });
    return account;
  };
  let handle;
  try {
    // Nonblocking open and regular-file validation avoid hanging on special files.
    handle = await open(profile.snapshotFile, constants.O_RDONLY | constants.O_NONBLOCK);
    const info = await handle.stat();
    if (!info.isFile()) return unavailable('invalid_snapshot', 'Snapshot must be a regular JSON file.');
    if (info.size > MAX_BYTES) return unavailable('snapshot_too_large', 'Snapshot exceeds the 64 KiB size limit.');
    const buffer = Buffer.alloc(MAX_BYTES + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
      if (!bytesRead) break;
      length += bytesRead;
    }
    if (length > MAX_BYTES) return unavailable('snapshot_too_large', 'Snapshot exceeds the 64 KiB size limit.');
    let envelope: JsonObject | null;
    try { envelope = object(JSON.parse(buffer.toString('utf8', 0, length))); }
    catch { return unavailable('invalid_snapshot', 'Snapshot is not valid JSON.'); }
    if (!envelope || own(envelope, 'schemaVersion') !== 1 || own(envelope, 'provider') !== profile.provider || own(envelope, 'accountId') !== profile.id || !has(envelope, 'data')) {
      return unavailable('snapshot_mismatch', 'Snapshot version, provider, or account does not match this profile.');
    }
    const timestamp = isoTime(own(envelope, 'observedAt'));
    if (timestamp === null || Date.parse(timestamp) > Date.now()) return unavailable('invalid_observation', 'Snapshot observation time is invalid or in the future.');
    return normalizeSnapshot(profile, own(envelope, 'data'), new Date(timestamp));
  } catch {
    return unavailable('snapshot_read_failed', 'Could not read the configured snapshot file.');
  } finally {
    await handle?.close().catch(() => {});
  }
}
