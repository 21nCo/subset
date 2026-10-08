import type { UsageStatus, UsageWindow } from './index.js';

/**
 * Local usage history for trend views: observation time and used percentage per account window.
 * It stores no labels, plans, errors, or provider payloads. Hosts own persistence.
 */
export interface UsageHistory {
  schemaVersion: 1;
  /** accountId -> windowKey -> [observedAt epoch ms, used percent] in ascending time. */
  series: Record<string, Record<string, Array<[number, number]>>>;
}

export const HISTORY_MAX_AGE_MS = 8 * 24 * 60 * 60_000;
const MAX_POINTS = 2000;
const MIN_INTERVAL_MS = 4 * 60_000;
const MAX_ACCOUNTS = 50;
const MAX_WINDOWS = 100;

export const historyWindowKey = (window: Pick<UsageWindow, 'limitId' | 'label'>) => `${window.limitId}\u0000${window.label}`;
export const emptyUsageHistory = (): UsageHistory => ({ schemaVersion: 1, series: {} });

export function isUsageHistory(value: unknown): value is UsageHistory {
  const record = (item: unknown): item is Record<string, unknown> => !!item && typeof item === 'object' && !Array.isArray(item);
  if (!record(value) || value.schemaVersion !== 1 || !record(value.series)) return false;
  const accounts = Object.entries(value.series);
  if (accounts.length > MAX_ACCOUNTS) return false;
  return accounts.every(([id, windows]) => /^[a-zA-Z0-9_-]{1,64}$/.test(id) && record(windows) && Object.keys(windows).length <= MAX_WINDOWS
    && Object.entries(windows).every(([key, points]) => key.length <= 400 && Array.isArray(points) && points.length <= MAX_POINTS
      && points.every((point) => Array.isArray(point) && point.length === 2 && Number.isSafeInteger(point[0]) && point[0] >= 0
        && typeof point[1] === 'number' && Number.isFinite(point[1]) && point[1] >= 0 && point[1] <= 100)));
}

/**
 * Adds each account's newest observation. Repeated reads of the same observation are ignored and unchanged values
 * closer than four minutes apart are thinned. Series are kept until their points pass the eight-day retention, so a
 * failed or partial read never erases history; `removeHistoryAccount` drops an account explicitly.
 */
export function recordUsageHistory(history: UsageHistory, status: UsageStatus, now = Date.now()): UsageHistory {
  const cutoff = now - HISTORY_MAX_AGE_MS;
  // Prototype-free maps, so an ID such as `__proto__` is an ordinary key.
  const series: UsageHistory['series'] = Object.create(null);
  // Start from everything already recorded, pruned to the retention window.
  for (const [accountId, windows] of Object.entries(history.series)) {
    const kept: Record<string, Array<[number, number]>> = Object.create(null);
    for (const [key, points] of Object.entries(windows)) {
      const recent = points.filter(([time]) => time >= cutoff && time <= now);
      if (recent.length) kept[key] = recent;
    }
    if (Object.keys(kept).length) series[accountId] = kept;
  }
  for (const account of status.accounts) {
    const observed = account.observedAt ? Date.parse(account.observedAt) : NaN;
    if (!Number.isFinite(observed) || observed < cutoff || observed > now) continue;
    const windows = series[account.id] ?? Object.create(null);
    for (const window of account.windows) {
      if (window.usedPercent === null) continue;
      const key = historyWindowKey(window);
      const points = windows[key] ?? [];
      const last = points.at(-1);
      const used = Math.round(window.usedPercent * 100) / 100;
      if (!last || (observed > last[0] && (used !== last[1] || observed - last[0] >= MIN_INTERVAL_MS))) points.push([observed, used]);
      windows[key] = points.slice(-MAX_POINTS);
    }
    if (Object.keys(windows).length) series[account.id] = windows;
  }
  // Keep the most recently observed accounts when over the cap.
  const latest = (windows: Record<string, Array<[number, number]>>) => Math.max(...Object.values(windows).map((points) => points.at(-1)?.[0] ?? 0));
  const ordered = Object.entries(series).sort((a, b) => latest(b[1]) - latest(a[1])).slice(0, MAX_ACCOUNTS);
  const windowsCapped = ordered.map(([id, windows]) => [id, Object.fromEntries(Object.entries(windows).slice(0, MAX_WINDOWS))] as const);
  return { schemaVersion: 1, series: Object.fromEntries(windowsCapped) };
}

/** Drops one account's history, for example when the account is removed. */
export function removeHistoryAccount(history: UsageHistory, accountId: string): UsageHistory {
  const { [accountId]: _removed, ...series } = history.series;
  return { schemaVersion: 1, series };
}
