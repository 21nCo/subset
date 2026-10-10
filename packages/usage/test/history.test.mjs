import assert from 'node:assert/strict';
import { test } from 'node:test';
import { emptyUsageHistory, historyWindowKey, isUsageHistory, recordUsageHistory, removeHistoryAccount } from '../dist/history.js';
import { createUsageStatus } from '../dist/index.js';

const now = Date.parse('2026-10-08T12:00:00Z');
const window = { limitId: 'codex', label: 'codex · primary', kind: 'provider-reported-quota', usedPercent: 40, usedKind: 'provider-reported-quota', remainingPercent: 60, remainingKind: 'calculated-estimate', durationMinutes: 300, resetsAt: null };
const status = (observedAt, used = 40, id = 'a') => createUsageStatus([{ id, label: 'Private label', provider: 'codex-chatgpt', source: 'Codex app-server', plan: 'pro', observedAt: new Date(observedAt).toISOString(), state: 'ok', windows: [{ ...window, usedPercent: used }], resetCredits: null, errors: [{ code: 'x', message: 'private error' }] }]);
const key = historyWindowKey(window);

test('records only times and percentages, deduplicating and thinning observations', () => {
  let history = recordUsageHistory(emptyUsageHistory(), status(now - 60 * 60_000), now);
  history = recordUsageHistory(history, status(now - 60 * 60_000), now);
  assert.deepEqual(history.series.a[key], [[now - 60 * 60_000, 40]]);
  history = recordUsageHistory(history, status(now - 58 * 60_000), now);
  assert.equal(history.series.a[key].length, 1, 'unchanged value within four minutes is thinned');
  history = recordUsageHistory(history, status(now - 57 * 60_000, 41), now);
  history = recordUsageHistory(history, status(now - 50 * 60_000, 41), now);
  assert.deepEqual(history.series.a[key].map((point) => point[1]), [40, 41, 41]);
  assert.doesNotMatch(JSON.stringify(history), /Private label|private error|pro/);
  assert.equal(isUsageHistory(history), true);
});

test('drops old points and invalid shapes, and keeps series a read did not return', () => {
  const old = { schemaVersion: 1, series: { a: { [key]: [[now - 9 * 86_400_000, 10], [now - 86_400_000, 20]], other: [[now - 1000, 7]] }, missing: { [key]: [[now - 1000, 5]] } } };
  const next = recordUsageHistory(old, status(now, 30), now);
  assert.deepEqual(next.series.a[key], [[now - 86_400_000, 20], [now, 30]]);
  // A failed or partial read (an account or window absent this time) does not erase history.
  assert.deepEqual(next.series.a.other, [[now - 1000, 7]]);
  assert.deepEqual(next.series.missing[key], [[now - 1000, 5]]);
  const failed = recordUsageHistory(next, { ...status(now + 60_000, 30), accounts: [] }, now + 60_000);
  assert.deepEqual(failed.series, next.series);
  assert.equal(removeHistoryAccount(next, 'missing').series.missing, undefined);
  assert.equal(recordUsageHistory(old, status(now, 30), now + 9 * 86_400_000).series.missing, undefined);
  assert.equal(isUsageHistory({ schemaVersion: 1, series: { a: { [key]: [[now, 101]] } } }), false);
  assert.equal(isUsageHistory({ schemaVersion: 1, series: { '../x': {} } }), false);
  assert.equal(isUsageHistory({ schemaVersion: 2, series: {} }), false);
});
