<!--
  One timer on the board. Focusable: Space starts, pauses or resumes it, L takes a lap and S skips,
  and focus returns to the card after each action. Reset and remove run on a second press within 3 s.
-->
<script lang="ts">
  import { tick } from 'svelte';
  import type { TimerSnapshot } from '../agent.js';
  import {
    controlStates, formatElapsed, formatRemaining, isArmed, keyControl, primaryControl, stepTitle,
    type Armed, type ControlName, type TimerBoardCapabilities, type TimerBoardDensity
  } from './view-model.js';

  interface Props {
    /** Already re-projected at `clock`. */
    snapshot: TimerSnapshot;
    capabilities: TimerBoardCapabilities;
    density: TimerBoardDensity;
    armed: Armed;
    clock: number;
    busy: boolean;
    /** The inline error for this timer's last failed action. */
    failure: string | null;
    oncontrol: (control: ControlName) => Promise<void>;
  }

  let { snapshot, capabilities, density, armed, clock, busy, failure, oncontrol }: Props = $props();

  const uid = $props.id();
  let card = $state<HTMLElement>();

  const definition = $derived(snapshot.definition);
  const projection = $derived(snapshot.projection);
  const step = $derived(projection.step);
  const table = $derived(controlStates(definition, projection.status, capabilities, clock));
  const primary = $derived(primaryControl(table));
  const rounds = $derived(definition.kind === 'interval' ? definition.rounds : 1);

  const STATUS_LABELS = { idle: 'Ready', running: 'Running', paused: 'Paused', finished: 'Finished' } as const;
  const PRIMARY_LABELS = { start: 'Start', pause: 'Pause', resume: 'Resume' } as const;

  // Interval cards show the current step; countdowns their time left; stopwatches their time elapsed.
  const time = $derived(
    step ? formatRemaining(step.remainingMs) : projection.remainingMs !== null ? formatRemaining(projection.remainingMs) : formatElapsed(projection.elapsedMs)
  );
  const progress = $derived(
    step ? step.elapsedMs / step.durationMs : projection.totalMs ? projection.elapsedMs / projection.totalMs : projection.finished ? 1 : null
  );
  const phase = $derived(step?.phase ?? (projection.finished && definition.kind === 'interval' ? 'done' : null));
  const RADIUS = 44;
  const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

  const shortcuts = $derived(
    [primary && 'Space', table.lap === 'enabled' && 'L', table.skip === 'enabled' && 'S'].filter(Boolean).join(' ')
  );
  const shortcutHelp = $derived(
    [primary && `Space to ${primary}`, table.lap === 'enabled' && 'L for a lap', table.skip === 'enabled' && 'S to skip'].filter(Boolean).join(', ')
  );
  const laps = $derived(snapshot.runtime.laps.slice(-3).reverse());

  async function act(control: ControlName) {
    if (busy || table[control] !== 'enabled') return;
    await oncontrol(control);
    // A control can disappear or become disabled after its action; keep focus on this card.
    await tick();
    if (card?.isConnected && !card.contains(document.activeElement)) card.focus();
  }

  function onkeydown(event: KeyboardEvent) {
    if (event.altKey || event.ctrlKey || event.metaKey) return;
    // Space on a focused button presses that button. A held key acts once (`keyControl` ignores
    // repeats), but a held Space on the card still must not scroll the page.
    if (event.key === ' ' && event.target !== card) return;
    const control = keyControl(event, table);
    if (event.key === ' ' && event.target === card) event.preventDefault();
    if (!control) return;
    event.preventDefault();
    void act(control);
  }

  const destructiveLabel = (control: 'reset' | 'remove') =>
    isArmed(armed, definition.id, control, clock) ? `Press again to ${control}` : control === 'reset' ? 'Reset' : 'Remove';
</script>

<!-- The card takes focus and its own shortcuts (Space, L, S), as the board's keyboard contract requires. -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
<article
  bind:this={card}
  class="card"
  class:compact={density === 'compact'}
  data-phase={phase}
  tabindex="0"
  aria-labelledby="{uid}-name"
  aria-describedby="{uid}-keys{failure ? ` ${uid}-error` : ''}"
  aria-keyshortcuts={shortcuts || undefined}
  aria-busy={busy}
  {onkeydown}
>
  <header>
    <h3 id="{uid}-name">{definition.name}</h3>
    <span class="status">{STATUS_LABELS[projection.status]}</span>
  </header>

  <div class="body">
    {#if progress !== null}
      <svg class="ring" viewBox="0 0 100 100" aria-hidden="true">
        <circle class="track" cx="50" cy="50" r={RADIUS} />
        <circle
          class="progress"
          cx="50"
          cy="50"
          r={RADIUS}
          stroke-dasharray={CIRCUMFERENCE}
          stroke-dashoffset={CIRCUMFERENCE * (1 - Math.min(1, Math.max(0, progress)))}
        />
      </svg>
    {/if}
    <div class="readout">
      {#if step}
        <p class="phase">
          <span class="swatch" aria-hidden="true"></span>{stepTitle(step)}{#if step.round !== null && rounds > 1}<span class="round"> · Round {step.round}/{rounds}</span>{/if}
        </p>
      {:else if phase === 'done'}
        <p class="phase">Done</p>
      {/if}
      <p class="time" role="timer">{time}</p>
      {#if step}
        <p class="detail">{projection.next ? `Next: ${stepTitle(projection.next)} ${formatRemaining(projection.next.durationMs)}` : 'Last step'}</p>
      {:else if definition.kind === 'countdown' && projection.totalMs !== null}
        <p class="detail">of {formatRemaining(projection.totalMs)}</p>
      {/if}
    </div>
  </div>

  {#if laps.length && density === 'full'}
    <ol class="laps" aria-label="Latest laps">
      {#each laps as lap, index (snapshot.runtime.laps.length - index)}
        <li>Lap {snapshot.runtime.laps.length - index}: {formatElapsed(lap.elapsedMs)}</li>
      {/each}
    </ol>
  {:else if laps.length}
    <p class="detail">{snapshot.runtime.laps.length} lap{snapshot.runtime.laps.length === 1 ? '' : 's'}</p>
  {/if}

  <div class="controls" role="group" aria-label="{definition.name} controls">
    <button type="button" class="primary" disabled={!primary} onclick={() => primary && act(primary)}>
      {primary ? PRIMARY_LABELS[primary] : 'Start'}
    </button>
    {#if table.lap !== 'hidden'}
      <button type="button" disabled={table.lap === 'disabled'} onclick={() => act('lap')}>Lap</button>
    {/if}
    {#if table.skip !== 'hidden'}
      <button type="button" disabled={table.skip === 'disabled'} onclick={() => act('skip')}>Skip</button>
    {/if}
    {#if table.reset !== 'hidden'}
      <button type="button" class="destructive" class:armed={isArmed(armed, definition.id, 'reset', clock)} disabled={table.reset === 'disabled'} onclick={() => act('reset')}>
        {destructiveLabel('reset')}
      </button>
    {/if}
    {#if table.remove !== 'hidden'}
      <button type="button" class="destructive" class:armed={isArmed(armed, definition.id, 'remove', clock)} onclick={() => act('remove')}>
        {destructiveLabel('remove')}
      </button>
    {/if}
  </div>

  <p class="sr-only" id="{uid}-keys">{shortcutHelp ? `Keys: ${shortcutHelp}.` : ''}</p>
  {#if failure}
    <p class="error" id="{uid}-error">{failure}</p>
  {/if}
</article>

<style>
  .card {
    --phase-color: var(--timer-accent);
    background: var(--timer-surface);
    border: 1px solid var(--timer-border);
    border-top: 4px solid var(--phase-color);
    border-radius: 10px;
    padding: 12px;
    display: grid;
    gap: 8px;
  }
  .card[data-phase='prep'] { --phase-color: var(--phase-prep); }
  .card[data-phase='work'] { --phase-color: var(--phase-work); }
  .card[data-phase='rest'] { --phase-color: var(--phase-rest); }
  .card[data-phase='cooldown'] { --phase-color: var(--phase-cooldown); }
  .card[data-phase='done'] { --phase-color: var(--timer-muted); }
  .card:focus-visible {
    outline: 2px solid var(--timer-accent);
    outline-offset: 2px;
  }
  .compact {
    padding: 8px;
    gap: 6px;
  }
  header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 8px;
  }
  h3 {
    margin: 0;
    font-size: 1em;
    overflow-wrap: anywhere;
  }
  .status,
  .detail {
    margin: 0;
    color: var(--timer-muted);
  }
  .body {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .ring {
    width: 72px;
    height: 72px;
    flex: none;
    transform: rotate(-90deg);
  }
  .compact .ring {
    width: 44px;
    height: 44px;
  }
  .ring circle {
    fill: none;
    stroke-width: 8;
  }
  .track {
    stroke: var(--timer-border);
  }
  .progress {
    stroke: var(--phase-color);
    stroke-linecap: round;
    transition: stroke-dashoffset 250ms linear;
  }
  @media (prefers-reduced-motion: reduce) {
    .progress {
      transition: none;
    }
  }
  .readout p {
    margin: 0;
  }
  .phase {
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .swatch {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    background: var(--phase-color);
  }
  .round {
    font-weight: 400;
    color: var(--timer-muted);
  }
  .time {
    font-size: 2em;
    font-variant-numeric: tabular-nums;
    font-weight: 600;
    line-height: 1.1;
  }
  .compact .time {
    font-size: 1.5em;
  }
  .laps {
    margin: 0;
    padding-left: 1.2em;
    color: var(--timer-muted);
    font-variant-numeric: tabular-nums;
  }
  .controls {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  button {
    font: inherit;
    color: var(--timer-text);
    background: var(--timer-bg);
    border: 1px solid var(--timer-border);
    border-radius: 6px;
    padding: 4px 10px;
    cursor: pointer;
  }
  button:disabled {
    opacity: 0.5;
    cursor: default;
  }
  button:focus-visible {
    outline: 2px solid var(--timer-accent);
    outline-offset: 1px;
  }
  .primary {
    background: var(--timer-accent);
    border-color: var(--timer-accent);
    color: var(--timer-bg);
    font-weight: 600;
  }
  .destructive.armed {
    color: var(--timer-danger);
    border-color: var(--timer-danger);
  }
  .error {
    margin: 0;
    color: var(--timer-danger);
  }
  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
</style>
