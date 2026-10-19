// What the board's one polite live region says. Only changes a listener needs are announced: a new
// interval step, pause, resume and finish. The state compared holds no time, so the passing seconds
// never produce an announcement.
import type { TimerProjection } from '../engine.js';
import type { TimerDefinition, TimerStatus } from '../model.js';
import { formatRemaining, stepTitle } from './format.js';

export interface AnnouncedState {
  status: TimerStatus;
  /** The interval step index; null for other kinds and once finished. */
  stepIndex: number | null;
}
/** The last state announced for each timer, by id. */
export type AnnouncedStates = Record<string, AnnouncedState>;

export interface AnnounceInput {
  definition: Pick<TimerDefinition, 'id' | 'name' | 'kind'> & { rounds?: number };
  projection: Pick<TimerProjection, 'status' | 'step'>;
}

function stepMessage(timer: AnnounceInput): string | null {
  const step = timer.projection.step;
  if (!step) return null;
  const rounds = timer.definition.rounds ?? 1;
  const round = step.round !== null && rounds > 1 ? `, round ${step.round} of ${rounds}` : '';
  return `${timer.definition.name}: ${stepTitle(step)}${round}, ${formatRemaining(step.durationMs)}.`;
}

/**
 * Compares each timer with what was last announced and returns the messages to speak, in board
 * order, with the states to remember. Timers seen for the first time (including every timer when
 * `previous` is null, as on mount) and timers that became idle or were removed say nothing.
 */
export function pickAnnouncements(previous: AnnouncedStates | null, timers: readonly AnnounceInput[]): { messages: string[]; states: AnnouncedStates } {
  const states: AnnouncedStates = {};
  const messages: string[] = [];
  for (const timer of timers) {
    const { status, step } = timer.projection;
    const current: AnnouncedState = { status, stepIndex: step?.index ?? null };
    states[timer.definition.id] = current;
    const before = previous?.[timer.definition.id];
    if (!before) continue;
    const name = timer.definition.name;
    if (status !== before.status) {
      if (status === 'finished') messages.push(`${name} finished.`);
      else if (status === 'paused' && before.status === 'running') messages.push(`${name} paused.`);
      else if (status === 'running' && before.status === 'paused') messages.push(`${name} resumed.`);
    }
    // A step change while the timer is under way, for example the next segment or a skip. Starting
    // from idle is the user's own action and is not announced.
    const underWay = (value: TimerStatus) => value === 'running' || value === 'paused';
    if (underWay(status) && underWay(before.status) && current.stepIndex !== before.stepIndex) {
      const message = stepMessage(timer);
      if (message) messages.push(message);
    }
  }
  return { messages, states };
}
