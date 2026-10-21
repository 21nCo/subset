import assert from 'node:assert/strict';
import test from 'node:test';
import { DurationError, parseDuration, parseUntil } from '../../src/parse-duration.mjs';

test('durations in units and clock forms', () => {
  const cases = [
    ['90s', 90_000],
    ['25m', 1_500_000],
    ['1h30m', 5_400_000],
    ['1h0m30s', 3_630_000],
    ['2h', 7_200_000],
    ['25M', 1_500_000],
    [' 45s ', 45_000],
    ['1:30', 90_000],
    ['0:01', 1_000],
    ['90:00', 5_400_000],
    ['1:02:03', 3_723_000],
    ['0:01:30', 90_000],
    ['24:00:00', 86_400_000],
    ['1s', 1_000],
    ['24h', 86_400_000],
    ['1440m', 86_400_000]
  ];
  for (const [text, ms] of cases) assert.equal(parseDuration(text), ms, text);
});

test('invalid durations are refused with a DurationError', () => {
  const cases = [
    ['', /not a duration/],
    ['90', /Add a unit, for example 90s or 90m/],
    ['0', /Add a unit/],
    ['0s', /from 1 second to 24 hours/],
    ['0:00', /from 1 second to 24 hours/],
    ['24h1s', /from 1 second to 24 hours/],
    ['25:00:00', /from 1 second to 24 hours/],
    ['1h30', /not a duration/],
    ['30m1h', /not a duration/],
    ['1m1m', /not a duration/],
    ['1.5m', /not a duration/],
    ['-5m', /not a duration/],
    ['1:60', /not a duration/],
    ['1:5', /not a duration/],
    ['1:02:60', /not a duration/],
    ['1::30', /not a duration/],
    ['1:60:00', /not a duration/],
    ['1:02:03:04', /not a duration/],
    ['5 m', /not a duration/],
    ['1d', /not a duration/],
    ['tabata', /not a duration/]
  ];
  for (const [text, message] of cases) {
    assert.throws(() => parseDuration(text), (error) => error instanceof DurationError && message.test(error.message), text);
  }
});

test('--until is the next such local time, today or tomorrow', () => {
  const previous = process.env.TZ;
  process.env.TZ = 'UTC';
  try {
    const now = Date.UTC(2026, 9, 19, 9, 0, 0);
    assert.equal(parseUntil('17:30', now), '2026-10-19T17:30:00.000Z');
    assert.equal(parseUntil('9:00:01', now), '2026-10-19T09:00:01.000Z');
    // The current minute and earlier times are tomorrow.
    assert.equal(parseUntil('09:00', now), '2026-10-20T09:00:00.000Z');
    assert.equal(parseUntil('08:15', now), '2026-10-20T08:15:00.000Z');
    // An ISO time with an offset names one moment and is passed on; the daemon checks the range.
    assert.equal(parseUntil('2026-10-19T17:30:00+02:00', now), '2026-10-19T17:30:00+02:00');
    for (const text of ['24:00', '17:60', '17', '5pm', '2026-10-19T17:30:00', '2026-13-45T17:30:00Z', '']) {
      assert.throws(() => parseUntil(text, now), DurationError, text);
    }
  } finally {
    if (previous === undefined) delete process.env.TZ;
    else process.env.TZ = previous;
  }
});
