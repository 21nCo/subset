import assert from 'node:assert/strict';
import { test } from 'node:test';
import { accountBadge, compactDuration, resetText, spanLabel, summarize, usedTone, windowPace, windowTitle } from '../dist/present.js';
import { createUsageStatus } from '../dist/index.js';

const now = Date.parse('2026-10-08T12:00:00Z');
const window = (overrides = {}) => ({ limitId: 'codex', label: 'codex · primary', kind: 'provider-reported-quota', usedPercent: 50, usedKind: 'provider-reported-quota', remainingPercent: 50, remainingKind: 'calculated-estimate', durationMinutes: 300, resetsAt: new Date(now + 150 * 60_000).toISOString(), ...overrides });
const account = (overrides = {}) => ({ id: 'a', label: 'Personal', provider: 'codex-chatgpt', source: 'Codex app-server', plan: 'pro', observedAt: new Date(now).toISOString(), state: 'ok', windows: [window()], resetCredits: null, errors: [], ...overrides });

test('names windows by span and only prefixes non-default Codex buckets', () => {
  assert.equal(spanLabel(300), '5-hour');
  assert.equal(spanLabel(10080), 'Weekly');
  assert.equal(spanLabel(43200), 'Monthly');
  assert.equal(spanLabel(2880), '2-day');
  assert.equal(spanLabel(45), '45-minute');
  assert.equal(windowTitle(account(), window()), '5-hour usage');
  const multi = account({ windows: [window(), window({ limitId: 'gpt_pro', label: 'GPT Pro · secondary', durationMinutes: 10080 })], limitAccess: [{ limitId: 'gpt_pro', label: 'GPT Pro', rateLimitReachedType: null, spendControlReached: null }] });
  assert.equal(windowTitle(multi, multi.windows[1]), 'GPT Pro · Weekly usage');
  assert.equal(windowTitle(account(), window({ durationMinutes: null })), 'Primary usage');
  assert.equal(windowTitle(account({ provider: 'antigravity' }), window({ label: 'gemini', durationMinutes: null })), 'gemini');
});

test('formats compact countdowns', () => {
  assert.equal(compactDuration(5 * 86_400_000 + 18 * 3_600_000 + 5 * 60_000), '5d 18h');
  assert.equal(compactDuration(2 * 3_600_000 + 14 * 60_000), '2h 14m');
  assert.equal(compactDuration(42 * 60_000), '42m');
  assert.equal(compactDuration(10_000), 'under 1m');
  assert.equal(resetText(new Date(now - 1).toISOString(), now), 'Reset due');
  assert.equal(resetText(null, now), 'Reset time unavailable');
});

test('estimates pace from the average rate and stays quiet early in a window', () => {
  // Half the window elapsed with 50% used: on pace for 100% exactly at reset.
  const even = windowPace(window(), now);
  assert.equal(even.projectedPercent, 100);
  assert.equal(even.beforeReset, false);
  const fast = windowPace(window({ usedPercent: 80 }), now);
  assert.equal(fast.beforeReset, true);
  assert.equal(Math.round(fast.exhaustsInMs / 60_000), 38);
  assert.equal(windowPace(window({ resetsAt: new Date(now + 299 * 60_000).toISOString() }), now), null);
  assert.equal(windowPace(window({ durationMinutes: null }), now), null);
  assert.equal(windowPace(window({ usedPercent: 100 }), now).exhaustsInMs, 0);
});

test('maps states to badges and summarizes attention, next reset, and highest usage', () => {
  assert.deepEqual(accountBadge(account(), now), { label: 'Up to date', tone: 'good' });
  assert.equal(accountBadge(account({ observedAt: new Date(now - 10 * 60_000).toISOString() }), now).label, 'Stale');
  assert.equal(accountBadge(account({ provider: 'claude-code', state: 'unavailable', observedAt: null, windows: [], errors: [{ code: 'claude_awaiting_snapshot', message: '' }] }), now).label, 'Waiting for data');
  assert.equal(accountBadge(account({ provider: 'claude-code', observedAt: new Date(now - 3_600_000).toISOString() }), now).label, 'Seen 1h ago');
  assert.equal(accountBadge(account({ state: 'blocked' }), now).tone, 'bad');
  assert.equal(usedTone(59), 'good');
  assert.equal(usedTone(85), 'bad');
  const status = createUsageStatus([
    account(),
    account({ id: 'b', label: 'Work', windows: [window({ usedPercent: 91, resetsAt: new Date(now + 30 * 60_000).toISOString() })] }),
    account({ id: 'c', label: 'Claude', provider: 'claude-code', state: 'unavailable', observedAt: null, windows: [] }),
  ]);
  const summary = summarize(status, now);
  assert.equal(summary.total, 3);
  assert.equal(summary.attention, 2);
  assert.equal(summary.nextReset.account, 'Work');
  assert.deepEqual([summary.highest.account, summary.highest.used], ['Work', 91]);
});

test('labels model-scoped Claude weekly windows and switches between used and remaining', async () => {
  const { displayPercent, resetDetails } = await import('../dist/present.js');
  const claude = account({ provider: 'claude-code' });
  assert.equal(windowTitle(claude, window({ limitId: 'seven_day_fable', label: 'Seven-day Fable quota', durationMinutes: 10080 })), 'Weekly Fable usage');
  assert.equal(windowTitle(claude, window({ limitId: 'seven_day', label: 'Seven-day quota', durationMinutes: 10080 })), 'Weekly usage');
  assert.deepEqual(displayPercent(window({ usedPercent: 30, remainingPercent: 70 }), 'used'), { value: 30, calculated: false, tone: 'good' });
  assert.deepEqual(displayPercent(window({ usedPercent: 30, remainingPercent: 70 }), 'remaining'), { value: 70, calculated: true, tone: 'good' });
  const details = resetDetails(window(), now);
  assert.equal(details.elapsedPercent, 50);
  assert.equal(details.windowStart, new Date(now - 150 * 60_000).toISOString());
  assert.equal(resetDetails(window({ resetsAt: null }), now).remainingMs, null);
});

test('sorts by recent use from history and by soonest reset, and finds resets in history', async () => {
  const { sortAccounts, lastUsedAt, historyResets } = await import('../dist/present.js');
  const { historyWindowKey } = await import('../dist/history.js');
  const key = historyWindowKey(window());
  const a = account({ id: 'a', windows: [window({ resetsAt: new Date(now + 5 * 3_600_000).toISOString() })] });
  const b = account({ id: 'b', windows: [window({ resetsAt: new Date(now + 3_600_000).toISOString() })] });
  const c = account({ id: 'c', windows: [] });
  const history = { schemaVersion: 1, series: { a: { [key]: [[now - 600_000, 10], [now - 300_000, 20]] }, b: { [key]: [[now - 900_000, 10], [now - 800_000, 30], [now - 100_000, 30]] } } };
  assert.equal(lastUsedAt(a, history), now - 300_000);
  assert.deepEqual(sortAccounts([c, b, a], 'recent', history, now).map((item) => item.id), ['a', 'b', 'c']);
  assert.deepEqual(sortAccounts([c, a, b], 'expiring', history, now).map((item) => item.id), ['b', 'a', 'c']);
  assert.deepEqual(sortAccounts([c, a, b], 'default', history, now).map((item) => item.id), ['c', 'a', 'b']);
  assert.deepEqual(historyResets([[1, 50], [2, 60], [3, 2], [4, 3], [5, 1]]), [3]);
});

test('builds a day-part activity grid with top accounts from usage increases', async () => {
  const { activityGrid } = await import('../dist/present.js');
  const { historyWindowKey } = await import('../dist/history.js');
  const key = historyWindowKey(window());
  const base = new Date(now); base.setHours(13, 5, 0, 0);
  const t = base.getTime();
  const history = { schemaVersion: 1, series: { a: { [key]: [[t, 10], [t + 600_000, 15], [t + 1_200_000, 12], [t + 3_600_000, 20]] } } };
  const { cells, max, dayStarts } = activityGrid(history, [account({ id: 'a', label: 'Work' })], t + 3_700_000, 7);
  assert.equal(dayStarts.length, 7);
  assert.equal(cells.length, 4);
  assert.deepEqual(cells[2][6], { value: 13, top: [{ account: 'Work', points: 13 }] });
  assert.equal(cells[1][6].value, 0);
  assert.equal(max, 13);
  assert.equal(activityGrid(history, [], t, 7).max, 0);
});

test('groups Antigravity buckets and Factory limits into tabs and lists exhausted and low windows', async () => {
  const { windowGroups, limitAlerts, windowTitle } = await import('../dist/present.js');
  const { antigravitySpan } = await import('../dist/snapshots.js');
  assert.equal(antigravitySpan('gemini-5h'), 300);
  assert.equal(antigravitySpan('3p-weekly'), 10080);
  assert.equal(antigravitySpan('gemini'), null);
  const w = (limitId, used, durationMinutes) => window({ limitId, label: limitId, usedPercent: used, remainingPercent: 100 - used, durationMinutes });
  const google = account({ id: 'g', label: 'Google', provider: 'antigravity', windows: [w('3p-5h', 0, 300), w('3p-weekly', 100, 10080), w('gemini-5h', 0, 300), w('gemini-weekly', 90, 10080)] });
  assert.deepEqual(windowGroups(google).map((group) => [group.id, group.label, group.windows.length]), [['gemini', 'Gemini', 2], ['3p', 'Third-party', 2]]);
  assert.equal(windowTitle(google, google.windows[1]), 'Weekly usage');
  const factory = account({ id: 'f', provider: 'factory-droid', windows: [w('standard_weekly', 10, 10080), w('core_weekly', 0, 10080)] });
  assert.deepEqual(windowGroups(factory).map((group) => group.label), ['Standard', 'Core']);
  assert.equal(windowGroups(account()), null);
  const { exhausted, low } = limitAlerts([google, factory]);
  assert.deepEqual(exhausted.map((item) => item.window), ['Third-party · Weekly usage']);
  assert.deepEqual(low.map((item) => [item.account, item.window, item.used]), [['Google', 'Gemini · Weekly usage', 90]]);
});

test('orders Gemini before third-party groups and lists the next three resets', async () => {
  const { windowGroups, summarize } = await import('../dist/present.js');
  const { createUsageStatus } = await import('../dist/index.js');
  const w = (limitId, minutes) => window({ limitId, label: limitId, durationMinutes: 300, resetsAt: new Date(now + minutes * 60_000).toISOString() });
  const google = account({ id: 'g', provider: 'antigravity', windows: [w('3p-5h', 10), w('gemini-5h', 20)] });
  assert.deepEqual(windowGroups(google).map((group) => group.id), ['gemini', '3p']);
  const status = createUsageStatus([google, account({ id: 'c', windows: [w('codex', 5), w('other', 600)] })]);
  assert.deepEqual(summarize(status, now).nextResets.map((reset) => [reset.accountId, reset.window]), [['c', '5-hour usage'], ['g', 'Third-party · 5-hour usage'], ['g', 'Gemini · 5-hour usage']]);
});
