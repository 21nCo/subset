import { TIMER_LIMITS } from '@subset/timer';

const UNIT_MS = { h: 3_600_000, m: 60_000, s: 1_000 };
// Units in descending order, each at most once: 90s, 25m, 1h30m, 1h0m30s.
const UNITS = /^(?:(\d{1,6})h)?(?:(\d{1,6})m)?(?:(\d{1,6})s)?$/i;
// m:ss or h:mm:ss; the later fields have two digits below 60.
const CLOCK = /^(\d{1,6})(?::([0-5]\d))?:([0-5]\d)$/;

export class DurationError extends Error {
  constructor(message) {
    super(message);
    this.name = 'DurationError';
  }
}

/**
 * Milliseconds for `90s`, `25m`, `1h30m`, `1:30` (m:ss) or `1:02:03` (h:mm:ss), from 1 second to
 * 24 hours. Throws `DurationError` for anything else, including a bare number, whose unit would be a guess.
 */
export function parseDuration(text) {
  const value = String(text ?? '').trim();
  let ms = null;
  const units = UNITS.exec(value);
  if (value && units) {
    const [, hours = '0', minutes = '0', seconds = '0'] = units;
    ms = Number(hours) * UNIT_MS.h + Number(minutes) * UNIT_MS.m + Number(seconds) * UNIT_MS.s;
  } else {
    const clock = CLOCK.exec(value);
    if (clock) {
      const [, first, middle, last] = clock;
      ms = middle === undefined
        ? Number(first) * UNIT_MS.m + Number(last) * UNIT_MS.s
        : Number(first) * UNIT_MS.h + Number(middle) * UNIT_MS.m + Number(last) * UNIT_MS.s;
    }
  }
  if (ms === null) {
    const hint = /^\d+$/.test(value) ? ` Add a unit, for example ${value}s or ${value}m.` : '';
    throw new DurationError(`"${value}" is not a duration such as 90s, 25m, 1h30m or 1:30.${hint}`);
  }
  if (ms < TIMER_LIMITS.minDurationMs || ms > TIMER_LIMITS.maxDurationMs) {
    throw new DurationError(`"${value}" must be from 1 second to 24 hours.`);
  }
  return ms;
}

const TIME_OF_DAY = /^([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$/;
// An ISO date and time with an explicit offset, so it names one moment.
const ISO_WITH_OFFSET = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:\d{2})$/i;

/**
 * The ISO time `--until` counts down to: the next `HH:MM` or `HH:MM:SS` local time after `now`
 * (today, else tomorrow), or an ISO time with an offset as given. The daemon checks it is 1 second
 * to 24 hours ahead.
 */
export function parseUntil(text, now) {
  const value = String(text ?? '').trim();
  const time = TIME_OF_DAY.exec(value);
  if (time) {
    const [, hours, minutes, seconds = '0'] = time;
    const at = (dayOffset) => {
      const date = new Date(now);
      date.setDate(date.getDate() + dayOffset);
      date.setHours(Number(hours), Number(minutes), Number(seconds), 0);
      return date;
    };
    const today = at(0);
    return (today.getTime() > now ? today : at(1)).toISOString();
  }
  if (ISO_WITH_OFFSET.test(value) && Number.isFinite(Date.parse(value))) return value;
  throw new DurationError(`"${value}" is not a local time such as 17:30 or an ISO time with an offset.`);
}
