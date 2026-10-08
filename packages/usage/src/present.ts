import { usageFreshness, type UsageAccount, type UsageProvider, type UsageStatus, type UsageWindow } from './index.js';
import type { UsageHistory } from './history.js';

/** Presentation helpers shared by usage views. They never invent provider data; estimates are labeled by callers. */
export type Tone = 'good' | 'warn' | 'bad' | 'muted';

export const providerMeta: Record<UsageProvider, { name: string; mark: string }> = {
  'codex-chatgpt': { name: 'ChatGPT', mark: 'Cx' },
  'claude-code': { name: 'Claude', mark: 'Cl' },
  antigravity: { name: 'Antigravity', mark: 'Ag' },
  cursor: { name: 'Cursor team', mark: 'Cu' },
  'cursor-local': { name: 'Cursor', mark: 'Cu' },
  'factory-droid': { name: 'Factory Droid', mark: 'Fd' },
  amp: { name: 'Amp', mark: 'Am' },
  devin: { name: 'Devin', mark: 'Dv' },
  pi: { name: 'Pi', mark: 'Pi' },
  opencode: { name: 'OpenCode', mark: 'Oc' },
  omp: { name: 'omp', mark: 'om' },
  hermes: { name: 'Hermes', mark: 'He' },
};

/** The service an account's quota belongs to: harness accounts count under their login's service. */
export const accountService = (account: Pick<UsageAccount, 'provider' | 'service'>): UsageProvider => account.service ?? account.provider;

export const isSnapshotProvider = (provider: UsageProvider) => provider === 'claude-code' || provider === 'antigravity';

export function spanLabel(minutes: number): string {
  if (minutes === 1440) return 'Daily';
  if (minutes === 10080) return 'Weekly';
  if (minutes >= 40320 && minutes <= 44640) return 'Monthly';
  if (minutes % 1440 === 0) return `${minutes / 1440}-day`;
  if (minutes % 60 === 0) return `${minutes / 60}-hour`;
  return `${minutes}-minute`;
}

export function windowTitle(account: UsageAccount, window: UsageWindow): string {
  const span = window.durationMinutes ? `${spanLabel(window.durationMinutes)} usage` : null;
  const model = account.provider === 'claude-code' ? /^seven_day_([a-z]+)$/.exec(window.limitId)?.[1] : undefined;
  if (model) return `Weekly ${model.charAt(0).toUpperCase()}${model.slice(1)} usage`;
  // Cursor's windows all span the billing cycle; their own labels say what they measure.
  if (account.provider === 'cursor-local') return window.label;
  if (account.provider === 'factory-droid' && window.limitId.startsWith('core_')) return `Core ${span ? span.charAt(0).toLowerCase() + span.slice(1) : 'usage'}`;
  if (account.provider !== 'codex-chatgpt') return span ?? window.label;
  const buckets = new Set(account.windows.map((item) => item.limitId)).size;
  const bucket = account.limitAccess?.find((item) => item.limitId === window.limitId)?.label ?? window.limitId;
  const prefix = buckets > 1 && window.limitId !== 'codex' ? `${bucket} · ` : '';
  const slot = window.label.split(' · ').pop() ?? window.label;
  return `${prefix}${span ?? `${slot.charAt(0).toUpperCase()}${slot.slice(1)} usage`}`;
}

/** Compact duration such as "5d 18h", "2h 14m", or "42m". */
export function compactDuration(ms: number): string {
  const minutes = Math.max(0, Math.floor(ms / 60_000));
  if (minutes < 1) return 'under 1m';
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor((minutes % 1440) / 60);
  const rest = minutes % 60;
  if (days) return hours ? `${days}d ${hours}h` : `${days}d`;
  if (hours) return rest ? `${hours}h ${rest}m` : `${hours}h`;
  return `${rest}m`;
}

export function resetText(resetsAt: string | null, now: number): string {
  if (!resetsAt || !Number.isFinite(Date.parse(resetsAt))) return 'Reset time unavailable';
  const remaining = Date.parse(resetsAt) - now;
  return remaining <= 0 ? 'Reset due' : `Resets in ${compactDuration(remaining)}`;
}

export function agoText(observedAt: string | null, now: number): string {
  if (!observedAt || !Number.isFinite(Date.parse(observedAt))) return 'never';
  const elapsed = now - Date.parse(observedAt);
  return elapsed < 60_000 ? 'just now' : `${compactDuration(elapsed)} ago`;
}

export function usedTone(used: number | null): Tone {
  if (used === null) return 'muted';
  return used < 60 ? 'good' : used < 85 ? 'warn' : 'bad';
}

export interface Pace {
  /** Calculated usage at reset if the observed average rate continues. */
  projectedPercent: number;
  /** Calculated time until 100% at the observed average rate. */
  exhaustsInMs: number;
  beforeReset: boolean;
}

/** Linear pace estimate from the average rate since the window started. Returns null when it would be noise. */
export function windowPace(window: UsageWindow, now: number): Pace | null {
  if (window.usedPercent === null || !window.durationMinutes || !window.resetsAt) return null;
  const windowMs = window.durationMinutes * 60_000;
  const remaining = Date.parse(window.resetsAt) - now;
  if (!Number.isFinite(remaining) || remaining <= 0 || remaining > windowMs) return null;
  const elapsed = windowMs - remaining;
  if (elapsed < windowMs * 0.05) return null;
  const used = window.usedPercent;
  if (used >= 100) return { projectedPercent: 100, exhaustsInMs: 0, beforeReset: true };
  if (used <= 0) return { projectedPercent: 0, exhaustsInMs: Infinity, beforeReset: false };
  const exhaustsInMs = (100 - used) * elapsed / used;
  return { projectedPercent: Math.round(used * windowMs / elapsed), exhaustsInMs, beforeReset: exhaustsInMs < remaining };
}

export function accountBadge(account: UsageAccount, now: number): { label: string; tone: Tone } {
  const stale = usageFreshness(account.observedAt, now) === 'Stale';
  switch (account.state) {
    case 'blocked': return { label: 'Limited', tone: 'bad' };
    case 'unauthorized': return { label: 'Signed out', tone: 'bad' };
    case 'unsupported': return { label: 'Unsupported', tone: 'muted' };
    case 'unavailable':
      return account.errors.some((error) => error.code === 'claude_awaiting_snapshot') || (isSnapshotProvider(account.provider) && account.observedAt === null)
        ? { label: 'Waiting for data', tone: 'warn' } : { label: 'Unavailable', tone: 'warn' };
    case 'partial': return { label: 'Partial data', tone: 'warn' };
    default:
      if (isSnapshotProvider(account.provider)) return stale ? { label: `Seen ${agoText(account.observedAt, now)}`, tone: 'muted' } : { label: 'Up to date', tone: 'good' };
      return stale ? { label: 'Stale', tone: 'warn' } : { label: 'Up to date', tone: 'good' };
  }
}

export function needsAttention(account: UsageAccount, now: number): boolean {
  const tone = accountBadge(account, now).tone;
  return tone === 'bad' || tone === 'warn' || account.windows.some((window) => usedTone(window.usedPercent) === 'bad');
}

export interface UsageSummary {
  total: number;
  attention: number;
  nextReset: { account: string; provider: string; window: string; at: string } | null;
  /** The soonest upcoming resets, at most three. */
  nextResets: Array<{ accountId: string; account: string; provider: string; window: string; at: string }>;
  highest: { account: string; provider: string; window: string; used: number; calculated: boolean } | null;
}

export function summarize(status: UsageStatus, now: number): UsageSummary {
  let nextReset: UsageSummary['nextReset'] = null;
  let highest: UsageSummary['highest'] = null;
  for (const account of status.accounts) {
    for (const window of account.windows) {
      const reset = window.resetsAt ? Date.parse(window.resetsAt) : NaN;
      if (Number.isFinite(reset) && reset > now && (!nextReset || reset < Date.parse(nextReset.at))) {
        nextReset = { account: accountName(account), provider: providerMeta[account.provider].name, window: windowTitle(account, window), at: window.resetsAt! };
      }
      if (window.usedPercent !== null && (!highest || window.usedPercent > highest.used)) {
        highest = { account: accountName(account), provider: providerMeta[account.provider].name, window: windowTitle(account, window), used: window.usedPercent, calculated: window.usedKind === 'calculated-estimate' };
      }
    }
  }
  const upcoming = status.accounts.flatMap((account) => {
    const groups = windowGroups(account);
    return account.windows.filter((window) => window.resetsAt && Date.parse(window.resetsAt) > now).map((window) => {
      const group = groups?.find((item) => item.windows.includes(window));
      return { accountId: account.id, account: accountName(account), provider: providerMeta[account.provider].name,
        window: group ? `${group.label} · ${windowTitle(account, window)}` : windowTitle(account, window), at: window.resetsAt! };
    });
  }).sort((a, b) => Date.parse(a.at) - Date.parse(b.at)).slice(0, 3);
  return { total: status.accounts.length, attention: status.accounts.filter((account) => needsAttention(account, now)).length, nextReset, nextResets: upcoming, highest };
}

export type PercentMode = 'used' | 'remaining';

/** The percentage to show for a window in the chosen mode, and whether that value is calculated rather than reported. */
export function displayPercent(window: UsageWindow, mode: PercentMode): { value: number | null; calculated: boolean; tone: Tone } {
  const value = mode === 'used' ? window.usedPercent : window.remainingPercent;
  const calculated = mode === 'used' ? window.usedKind === 'calculated-estimate' : window.remainingKind === 'calculated-estimate';
  return { value, calculated, tone: usedTone(window.usedPercent) };
}

export interface ResetDetails {
  resetsAt: string | null;
  remainingMs: number | null;
  windowStart: string | null;
  elapsedPercent: number | null;
}

/** Window timing derived from the reported reset time and window length. */
export function resetDetails(window: UsageWindow, now: number): ResetDetails {
  const reset = window.resetsAt ? Date.parse(window.resetsAt) : NaN;
  if (!Number.isFinite(reset)) return { resetsAt: null, remainingMs: null, windowStart: null, elapsedPercent: null };
  const remainingMs = Math.max(0, reset - now);
  if (!window.durationMinutes) return { resetsAt: window.resetsAt, remainingMs, windowStart: null, elapsedPercent: null };
  const windowMs = window.durationMinutes * 60_000;
  const start = reset - windowMs;
  const elapsedPercent = Math.min(100, Math.max(0, Math.round((now - start) / windowMs * 1000) / 10));
  return { resetsAt: window.resetsAt, remainingMs, windowStart: new Date(start).toISOString(), elapsedPercent };
}

/** Display name: the account's own name, else its email, else the provider. */
export function accountName(account: Pick<UsageAccount, 'label' | 'email' | 'provider'>): string {
  return account.label.trim() || account.email || `${providerMeta[account.provider].name} account`;
}

// Provider plan codes that do not read well when title-cased.
const PLAN_NAMES: Record<string, string> = {
  prolite: 'Pro Lite', promax: 'Pro Max', self_serve_business_prolite: 'Business Pro Lite', self_serve_business_usage_based: 'Business (usage-based)',
  ent26: 'Enterprise', enterprise_cbp_automation: 'Enterprise', enterprise_cbp_usage_based: 'Enterprise (usage-based)', edu_plus: 'Edu Plus', edu_pro: 'Edu Pro',
};

/** Readable plan name, keeping tiers such as "Max 20x" intact. */
export function planName(plan: string): string {
  const known = PLAN_NAMES[plan.toLowerCase()];
  if (known) return known;
  return plan.split(/[_\s-]+/).filter(Boolean).map((word) => /^\d+x$/i.test(word) ? word.toLowerCase() : `${word.charAt(0).toUpperCase()}${word.slice(1)}`).join(' ');
}

/** Reset label that distinguishes a window that has not started from a missing reset time. */
export function windowResetText(window: UsageWindow, now: number): string {
  if (!window.resetsAt && window.usedPercent === 0) return 'Starts on first use';
  return resetText(window.resetsAt, now);
}

export type SortMode = 'default' | 'recent' | 'expiring';

/** Latest time any window's usage went up, from local history; null when none recorded. */
export function lastUsedAt(account: UsageAccount, history: UsageHistory | undefined): number | null {
  let latest: number | null = null;
  for (const points of Object.values(history?.series[account.id] ?? {})) {
    for (let index = 1; index < points.length; index++) {
      if (points[index][1] > points[index - 1][1] && (latest === null || points[index][0] > latest)) latest = points[index][0];
    }
  }
  return latest;
}

/** Soonest upcoming reset across an account's windows. */
export function soonestReset(account: UsageAccount, now: number): number | null {
  const times = account.windows.map((window) => window.resetsAt ? Date.parse(window.resetsAt) : NaN).filter((time) => Number.isFinite(time) && time > now);
  return times.length ? Math.min(...times) : null;
}

/** Orders accounts for display; ties and missing values keep the configured order. */
export function sortAccounts(accounts: UsageAccount[], mode: SortMode, history: UsageHistory | undefined, now: number): UsageAccount[] {
  if (mode === 'default') return accounts;
  const key = (account: UsageAccount) => mode === 'recent' ? -(lastUsedAt(account, history) ?? -Infinity) : soonestReset(account, now) ?? Infinity;
  return accounts.map((account, index) => ({ account, index, value: key(account) }))
    .sort((a, b) => (a.value === b.value ? 0 : a.value < b.value ? -1 : 1) || a.index - b.index)
    .map((item) => item.account);
}

/** Reset times visible in history: points where a window's usage dropped sharply. */
export function historyResets(points: Array<[number, number]>, minimumDrop = 3): number[] {
  const resets: number[] = [];
  for (let index = 1; index < points.length; index++) {
    if (points[index - 1][1] - points[index][1] >= minimumDrop) resets.push(points[index][0]);
  }
  return resets;
}

/** Parts of the day the activity heatmap groups usage into, in local time. */
export const DAY_PARTS = [
  { label: 'Night', from: 0, to: 6 }, { label: 'Morning', from: 6, to: 12 },
  { label: 'Afternoon', from: 12, to: 18 }, { label: 'Evening', from: 18, to: 24 },
] as const;

export interface ActivityCell {
  /** Sum of usage increases, in percentage points, across all windows in this period. */
  value: number;
  /** Largest contributors, by account name, highest first. */
  top: Array<{ account: string; points: number }>;
}

/**
 * Activity for the last `days` days from local history: for each day (column) and part of the
 * day (row), the sum of usage increases across the given accounts' windows.
 */
export function activityGrid(history: UsageHistory | undefined, accounts: UsageAccount[], now: number, days = 7): { cells: ActivityCell[][]; max: number; dayStarts: number[] } {
  const today = new Date(now);
  today.setHours(0, 0, 0, 0);
  const dayStarts = Array.from({ length: days }, (_, index) => today.getTime() - (days - 1 - index) * 86_400_000);
  const totals = DAY_PARTS.map(() => dayStarts.map(() => new Map<string, number>()));
  for (const account of accounts) {
    const name = accountName(account);
    for (const points of Object.values(history?.series[account.id] ?? {})) {
      for (let index = 1; index < points.length; index++) {
        const increase = points[index][1] - points[index - 1][1];
        if (increase <= 0) continue;
        const time = points[index][0];
        const day = dayStarts.findIndex((start) => time >= start && time < start + 86_400_000);
        const hour = new Date(time).getHours();
        const part = DAY_PARTS.findIndex((item) => hour >= item.from && hour < item.to);
        if (day < 0 || part < 0) continue;
        totals[part][day].set(name, (totals[part][day].get(name) ?? 0) + increase);
      }
    }
  }
  const cells = totals.map((row) => row.map((byAccount) => ({
    value: Math.round([...byAccount.values()].reduce((sum, value) => sum + value, 0) * 10) / 10,
    top: [...byAccount].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([account, points]) => ({ account, points: Math.round(points * 10) / 10 })),
  })));
  return { cells, max: Math.max(0, ...cells.flat().map((cell) => cell.value)), dayStarts };
}

export interface WindowGroup { id: string; label: string; windows: UsageWindow[] }
const GROUP_LABELS: Record<string, string> = { gemini: 'Gemini', '3p': 'Third-party', standard: 'Standard', core: 'Core' };

/**
 * Limit groups an account reports side by side: Factory's standard and Core limits, or
 * Antigravity's `<group>-<span>` buckets. Null when the account has a single group.
 */
export function windowGroups(account: UsageAccount): WindowGroup[] | null {
  const groupOf = (window: UsageWindow): string | null => {
    if (account.provider === 'factory-droid') return window.limitId.startsWith('core_') ? 'core' : 'standard';
    if (account.provider === 'antigravity' && window.limitId.includes('-')) return window.limitId.split('-')[0].toLowerCase();
    return null;
  };
  const groups = new Map<string, UsageWindow[]>();
  for (const window of account.windows) {
    const id = groupOf(window);
    if (id === null) return null;
    groups.set(id, [...(groups.get(id) ?? []), window]);
  }
  if (groups.size < 2) return null;
  // Primary groups lead: Gemini before third-party models, standard before Core.
  const order = ['gemini', 'standard'];
  return [...groups].sort((a, b) => (order.includes(b[0]) ? 1 : 0) - (order.includes(a[0]) ? 1 : 0)).map(([id, windows]) => ({ id, label: GROUP_LABELS[id] ?? `${id.charAt(0).toUpperCase()}${id.slice(1)}`, windows }));
}

export interface LimitItem { accountId: string; account: string; provider: string; window: string; used: number; resetsAt: string | null }

/** Windows with no quota left, and windows at 85% or more, across the given accounts. */
export function limitAlerts(accounts: UsageAccount[]): { exhausted: LimitItem[]; low: LimitItem[] } {
  const exhausted: LimitItem[] = [];
  const low: LimitItem[] = [];
  for (const account of accounts) {
    const groups = windowGroups(account);
    for (const window of account.windows) {
      const used = window.usedPercent ?? (window.remainingPercent === null ? null : 100 - window.remainingPercent);
      if (used === null) continue;
      const group = groups?.find((item) => item.windows.includes(window));
      const item = { accountId: account.id, account: accountName(account), provider: providerMeta[account.provider].name,
        window: group ? `${group.label} · ${windowTitle(account, window)}` : windowTitle(account, window), used, resetsAt: window.resetsAt };
      if (used >= 100) exhausted.push(item); else if (used >= 85) low.push(item);
    }
  }
  const byReset = (a: LimitItem, b: LimitItem) => (a.resetsAt ? Date.parse(a.resetsAt) : Infinity) - (b.resetsAt ? Date.parse(b.resetsAt) : Infinity);
  return { exhausted: exhausted.sort(byReset), low: low.sort((a, b) => b.used - a.used) };
}
