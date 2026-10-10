import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createUsageStatus, isUsageStatus, usageText, usageFreshness } from '../dist/index.js';
import { normalizeCodexRead } from '../dist/codex.js';

test('validates bounded dashboard status before rendering an external view input', () => {
  const account = normalizeCodexRead({ id: 'work', label: 'Work', codexHome: '/unused' },
    { account: { type: 'chatgpt', planType: 'plus' } },
    { rateLimits: { primary: { usedPercent: 0, resetsAt: 1800000000 } } }, new Date());
  const status = createUsageStatus([account]);
  assert.equal(isUsageStatus(status), true);
  assert.equal(isUsageStatus(createUsageStatus([])), true);
  assert.equal(isUsageStatus({ ...status, accounts: [account, account] }), false);
  assert.equal(isUsageStatus({ ...status, accounts: [{ ...account, observedAt: 'bad date' }] }), false);
  assert.equal(isUsageStatus({ ...status, accounts: [{ ...account, windows: [{ ...account.windows[0], remainingPercent: 101 }] }] }), false);
  assert.equal(isUsageStatus({ ...status, accounts: [{ ...account, errors: [{ code: 'bad', message: {} }] }] }), false);
  assert.equal(isUsageStatus({ ...status, accounts: [{ ...account, provider: 'unregistered' }] }), false);
  assert.equal(isUsageStatus({ ...status, accounts: [{ ...account, provider: ['codex-chatgpt'] }] }), false);
  assert.equal(isUsageStatus({ ...status, accounts: [{ ...account, state: ['ok'] }] }), false);
  assert.equal(isUsageStatus({ ...status, accounts: [{ ...account, windows: [account.windows[0], account.windows[0]] }] }), false);
  assert.equal(isUsageStatus({ ...status, accounts: [{ ...account, windows: [
    { ...account.windows[0], limitId: 'a', label: 'bc' },
    { ...account.windows[0], limitId: 'ab', label: 'c' },
  ] }] }), true, 'Distinct tuple keys must not collide through concatenation');
  assert.equal(isUsageStatus({ ...status, viewId: 'unregistered-view' }), false);
});

test('malformed Codex fields remain a bounded partial account without hiding healthy providers', () => {
  const profile = { id: 'bad', label: 'Malformed Codex', codexHome: '/unused' };
  const accountResult = { account: { type: 'chatgpt', planType: 'x'.repeat(200) } };
  const buckets = Object.fromEntries(Array.from({ length: 80 }, (_, i) => [`bucket${i}`, {
    limitId: i === 0 ? 'x'.repeat(200) : 'duplicate', limitName: 'y'.repeat(200),
    primary: { usedPercent: i === 0 ? 150 : 25, windowDurationMins: -1, resetsAt: 1e20 },
  }]));
  const malformed = normalizeCodexRead(profile, accountResult, { rateLimitsByLimitId: buckets }, new Date());
  assert.equal(malformed.state, 'partial');
  assert.equal(malformed.plan, null);
  assert.equal(malformed.windows[0].durationMinutes, null);
  assert.equal(malformed.windows[0].resetsAt, null);
  assert.ok(malformed.windows.length <= 100);
  const healthy = normalizeCodexRead({ ...profile, id: 'healthy', label: 'Healthy' },
    { account: { type: 'chatgpt', planType: 'plus' } },
    { rateLimits: { primary: { usedPercent: 50, resetsAt: 1800000000 } } }, new Date());
  assert.equal(isUsageStatus(createUsageStatus([malformed, healthy])), true);
});

test('Cursor spending has a usable structured and text fallback without pretending it is quota', () => {
  const account = { id: 'cursor_work', label: 'Work', provider: 'cursor', source: 'Cursor team Admin API',
    plan: null, observedAt: new Date().toISOString(), state: 'ok', windows: [], resetCredits: null, errors: [],
    spend: { kind: 'provider-reported-spend', currency: 'USD', used: 0, limit: 50, includedUsed: 12,
      periodStart: null, periodEnd: null } };
  assert.equal(isUsageStatus(createUsageStatus([account])), true);
  assert.match(usageText(createUsageStatus([account])), /cursor.*USD 0 on-demand spend of 50 limit/);
  assert.equal(isUsageStatus(createUsageStatus([{ ...account, spend: { ...account.spend, used: -1 } }])), false);
});

test('text-only fallback qualifies calculations, sources, stale observations and safe failure details', () => {
  const now = new Date('2026-10-02T04:00:00Z');
  const account = normalizeCodexRead({ id: 'work', label: 'Work', codexHome: '/unused' },
    { account: { type: 'chatgpt', planType: 'plus' } },
    { rateLimits: { primary: { usedPercent: 25, resetsAt: 1800000000 } } }, new Date('2026-10-02T03:54:00Z'));
  account.errors = [{ code: 'safe_failure', message: 'Provider returned incomplete data.' }];
  account.state = 'partial';
  const text = usageText(createUsageStatus([account], now), now);
  assert.match(text, /~75% remaining \(calculated from provider-reported usage\)/);
  assert.match(text, /source Codex app-server/);
  assert.match(text, /observed 2026-10-02T03:54:00.000Z; Stale \(older than 5 minutes\)/);
  assert.match(text, /safe_failure: Provider returned incomplete data/);
  const missing = { ...account, observedAt: null, windows: [], state: 'unauthorized' };
  assert.match(usageText(createUsageStatus([missing], now), now), /No observation/);
  const snapshot = { ...account, provider: 'antigravity', source: 'Antigravity CLI status-line snapshot',
    windows: [{ ...account.windows[0], remainingKind: 'provider-reported-quota', usedKind: 'calculated-estimate' }] };
  const reported = usageText(createUsageStatus([snapshot], now), now);
  assert.match(reported, /75% remaining \(provider-reported quota\)/);
  assert.doesNotMatch(reported, /~75% remaining/);
  assert.match(reported, /last collected CLI snapshot, not a live provider read/);
});

test('freshness is recomputed against the current clock rather than the status generation time', () => {
  const observedAt = '2026-10-02T04:00:00Z';
  assert.equal(usageFreshness(observedAt, Date.parse('2026-10-02T04:05:00Z')), 'Current');
  assert.equal(usageFreshness(observedAt, Date.parse('2026-10-02T04:05:01Z')), 'Stale');
  assert.equal(usageFreshness(null), 'No observation');
  assert.equal(usageFreshness('invalid'), 'No observation');
});

test('validates provider access independently from quota windows', () => {
  const account = { id: 'blocked', label: 'Blocked', provider: 'codex-chatgpt', source: 'Codex app-server',
    observedAt: new Date().toISOString(), plan: null, state: 'blocked', windows: [], resetCredits: null, errors: [],
    ordinaryUsageAllowed: false,
    limitAccess: [{ limitId: 'codex', label: 'Codex', rateLimitReachedType: 'workspace_member_credits_depleted', spendControlReached: null }] };
  assert.equal(isUsageStatus(createUsageStatus([account])), true);
  assert.match(usageText(createUsageStatus([account])), /ordinary included usage blocked by provider/);
  assert.match(usageText(createUsageStatus([account])), /workspace_member_credits_depleted/);
  assert.equal(isUsageStatus(createUsageStatus([{ ...account, ordinaryUsageAllowed: 'false' }])), false);
  assert.equal(isUsageStatus(createUsageStatus([{ ...account, limitAccess: [...account.limitAccess, ...account.limitAccess] }])), false);
  assert.equal(isUsageStatus(createUsageStatus([{ ...account, limitAccess: [{ ...account.limitAccess[0], rateLimitReachedType: 'untrusted_reason' }] }])), false);
  assert.equal(isUsageStatus(createUsageStatus([{ ...account, limitAccess: [{ ...account.limitAccess[0], spendControlReached: 1 }] }])), false);
});
