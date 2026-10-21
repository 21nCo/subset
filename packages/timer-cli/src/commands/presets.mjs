import { formatDuration } from '@subset/timer';
import { intervalSpec } from './timers.mjs';
import { call, resolveRef } from './shared.mjs';

const length = (ms) => formatDuration(ms, 'up');
const plural = (count, noun) => `${count} ${noun}${count === 1 ? '' : 's'}`;

function intervalSummary(timer) {
  const segments = timer.segments.length > 4
    ? plural(timer.segments.length, 'segment')
    : timer.segments.map((segment) => `${segment.label.toLowerCase() === segment.phase ? segment.phase : segment.label} ${length(segment.durationMs)}`).join(', ');
  const total = (timer.prepMs ?? 0) + timer.rounds * timer.segments.reduce((sum, segment) => sum + segment.durationMs, 0) + (timer.cooldownMs ?? 0);
  const parts = [`${plural(timer.rounds, 'round')} of ${segments}`];
  if (timer.prepMs) parts.push(`prep ${length(timer.prepMs)}`);
  if (timer.cooldownMs) parts.push(`cooldown ${length(timer.cooldownMs)}`);
  parts.push(`${length(total)} total`);
  return parts.join(' · ');
}

/** One line per preset, for example `Tabata (tabata, built in): 8 rounds of work 0:20, rest 0:10 · prep 0:10 · 4:10 total`. */
export function presetLine(preset) {
  const { timer } = preset;
  const summary = timer.kind === 'interval' ? intervalSummary(timer)
    : timer.kind === 'countdown' ? `countdown ${length(timer.durationMs)}${timer.lapsEnabled ? ' with laps' : ''}`
      : 'stopwatch';
  return `${preset.name} (${preset.id}${preset.builtIn ? ', built in' : ''}): ${summary}`;
}

export const presetCommands = {
  presets: {
    options: {},
    positionals: [0, 0],
    async run({ client }) {
      const result = await call(client.presets());
      return { json: result, text: result.presets.map(presetLine).join('\n') };
    }
  },
  'preset save': {
    options: {
      'no-sound': { type: 'boolean' },
      ...Object.fromEntries(['work', 'rest', 'rounds', 'prep', 'cooldown'].map((flag) => [flag, { type: 'string' }]))
    },
    positionals: [1, 1],
    async run({ client, positionals: [name], values }) {
      const timer = { ...intervalSpec(values), ...(values['no-sound'] ? { sound: false } : {}) };
      const result = await call(client.op('presets.save', { name, timer }));
      return { json: result, text: `Saved preset ${result.preset.name} (${result.preset.id}).` };
    }
  },
  'preset rm': {
    options: {},
    positionals: [1, 1],
    async run({ client, positionals: [ref] }) {
      const { presets } = await call(client.presets());
      const preset = resolveRef(presets, ref, { noun: 'preset', describe: ({ id, name }) => ({ id, name }) });
      // The daemon refuses a built-in preset with invalid_state.
      const result = await call(client.op('presets.remove', { id: preset.id }));
      return { json: result, text: `Removed preset ${preset.name} (${result.removedId}).` };
    }
  }
};
