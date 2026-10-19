// Time text for the board view. The agent text and the view share `formatDuration`, so a timer reads
// the same in a chat reply and on its card.
import { formatDuration } from '../agent.js';
import type { IntervalStep } from '../engine.js';

/** Time left, rounded up: a countdown shows 0:01 until it ends. `m:ss`, or `h:mm:ss` from an hour. */
export const formatRemaining = (ms: number) => formatDuration(ms, 'up');

/** Time elapsed, rounded down. `m:ss`, or `h:mm:ss` from an hour. */
export const formatElapsed = (ms: number) => formatDuration(ms, 'down');

/** A step's name: its label, with the phase in parentheses when they differ, for example `Break (rest)`. */
export function stepTitle(step: Pick<IntervalStep, 'label' | 'phase'>): string {
  return step.label.toLowerCase() === step.phase ? step.label : `${step.label} (${step.phase})`;
}

/** A clock time such as `14:03:12` in the reader's locale, for `observedAt`. */
export function formatClockTime(epochMs: number, locale?: string): string {
  return new Date(epochMs).toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

/**
 * Reads a duration typed into the create form: seconds (`20`, `0.5`), `m:ss` or `h:mm:ss`. Returns
 * whole milliseconds, `undefined` for a blank field, or null when the text is not a duration.
 */
export function parseDurationText(text: string): number | null | undefined {
  const value = text.trim();
  if (!value) return undefined;
  const match = /^(?:(\d{1,3}):)??(?:(\d{1,4}):)?(\d{1,6}(?:\.\d{1,3})?)$/.exec(value);
  if (!match) return null;
  const [, hours, minutes, seconds] = match;
  // Below the leading unit, minutes and seconds stay under 60, as a clock shows them.
  if (minutes !== undefined && Number(seconds) >= 60) return null;
  if (hours !== undefined && Number(minutes) >= 60) return null;
  return Math.round(((Number(hours ?? 0) * 60 + Number(minutes ?? 0)) * 60 + Number(seconds)) * 1_000);
}

/** The text `parseDurationText` reads back as `ms`: `m:ss` or `h:mm:ss`, or seconds when `ms` is not whole seconds. */
export function durationText(ms: number): string {
  return ms % 1_000 === 0 ? formatElapsed(ms) : String(ms / 1_000);
}
