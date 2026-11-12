import assert from 'node:assert/strict';
import test from 'node:test';
import { TIMER_LIMITS, emptyStore, lineTextIssue, operations } from '../dist/index.js';

const T0 = Date.UTC(2026, 9, 19, 8, 0, 0);

/** Whether the start operation accepts `label` as a segment label. */
function acceptedAsLabel(label) {
  const outcome = operations.start(emptyStore(), { timer: { kind: 'interval', rounds: 1, segments: [{ label, phase: 'work', durationMs: 10_000 }] } }, T0);
  return outcome.ok;
}

test('lineTextIssue agrees with the schemas on segment labels', () => {
  const samples = ['Squats', 'Plank: hold', 'Ü', '🏋️ Lift', 'x'.repeat(40), 'x'.repeat(41), '🏋️'.repeat(41), 'A\tB', 'A\u0007', 'A B',
    'A‮evil', 'A⁧B', '​', ' ', '́', 'A​B'];
  for (const label of samples) {
    const issue = lineTextIssue(label, TIMER_LIMITS.labelLength);
    assert.equal(issue === null, acceptedAsLabel(label), `${JSON.stringify(label)}: ${issue}`);
  }
  assert.match(lineTextIssue('A\tB', 40), /control/);
  assert.match(lineTextIssue('​', 40), /visible/);
  assert.match(lineTextIssue('x'.repeat(41), 40), /at most 40/);
});
