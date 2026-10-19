import type { Preset } from './model.js';

const second = 1_000;
const minute = 60 * second;

const presets: Preset[] = [
  {
    id: 'tabata',
    name: 'Tabata',
    builtIn: true,
    timer: {
      kind: 'interval',
      prepMs: 10 * second,
      rounds: 8,
      segments: [
        { label: 'Work', phase: 'work', durationMs: 20 * second },
        { label: 'Rest', phase: 'rest', durationMs: 10 * second }
      ]
    }
  },
  {
    id: 'emom',
    name: 'EMOM',
    builtIn: true,
    timer: { kind: 'interval', rounds: 10, segments: [{ label: 'Work', phase: 'work', durationMs: minute }] }
  },
  {
    id: 'hiit-40-20',
    name: 'HIIT 40/20',
    builtIn: true,
    timer: {
      kind: 'interval',
      rounds: 10,
      segments: [
        { label: 'Work', phase: 'work', durationMs: 40 * second },
        { label: 'Rest', phase: 'rest', durationMs: 20 * second }
      ]
    }
  },
  {
    // Rounds repeat identical segments, so the longer last break makes this one round of eight segments.
    id: 'pomodoro',
    name: 'Pomodoro',
    builtIn: true,
    timer: {
      kind: 'interval',
      rounds: 1,
      segments: [1, 2, 3, 4].flatMap((round) => [
        { label: 'Focus', phase: 'work' as const, durationMs: 25 * minute },
        round === 4
          ? { label: 'Long break', phase: 'rest' as const, durationMs: 15 * minute }
          : { label: 'Break', phase: 'rest' as const, durationMs: 5 * minute }
      ])
    }
  },
  {
    id: 'amrap',
    name: 'AMRAP',
    builtIn: true,
    timer: { kind: 'countdown', durationMs: 20 * minute, lapsEnabled: true }
  }
];

/** Read-only presets every store offers. Their ids are stable slugs. */
export const BUILT_IN_PRESETS: readonly Preset[] = deepFreeze(presets);

export const BUILT_IN_PRESET_IDS = BUILT_IN_PRESETS.map((preset) => preset.id);

function deepFreeze<T>(value: T): T {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) deepFreeze(child);
    Object.freeze(value);
  }
  return value;
}
