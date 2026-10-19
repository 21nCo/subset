<!--
  The Timer board, view ID `subset.timer.board@1`. It renders the timers in `result`, re-projects them
  from their timestamps every 250 ms and runs every change through `actions.invoke`. It never fetches:
  each host supplies its own transport, and a new `result` from the host replaces the board's timers.
-->
<script lang="ts">
  import { onMount, tick, untrack } from 'svelte';
  import type { TimerSnapshot } from '../agent.js';
  import type { Preset } from '../model.js';
  import type { OperationName } from '../operations.js';
  import CreateTimer from './CreateTimer.svelte';
  import TimerCard from './TimerCard.svelte';
  import {
    REFRESH_MS, applyResult, failureText, formatClockTime, pickAnnouncements, pressDestructive, readBoardResult, readOutcome, readPresets, reproject,
    type ActionFailure, type AnnouncedStates, type Armed, type ControlName, type TimerBoardProps
  } from './view-model.js';

  let { result, actions, now = Date.now, capabilities, density }: TimerBoardProps = $props();
  const uid = $props.id();
  const titleId = `${uid}-title`;

  const read = $derived(readBoardResult(result));
  // A successful action updates the board until the host passes its next `result`, which wins.
  let timers = $derived<TimerSnapshot[]>(read.ok ? read.result.timers : []);
  let clock = $state(untrack(() => now()));
  const projected = $derived(timers.map((timer) => reproject(timer, clock)));

  let failure = $state<ActionFailure | null>(null);
  let busy = $state<Record<string, boolean>>({});
  let armed = $state<Armed>(null);
  let listElement = $state<HTMLElement>();

  onMount(() => {
    const interval = setInterval(() => (clock = now()), REFRESH_MS);
    return () => clearInterval(interval);
  });

  // One polite live region. Its text changes only on a step change, pause, resume, finish or a failed
  // action; re-keying it lets a repeated message ("Tabata paused.") be spoken again.
  let announced: AnnouncedStates | null = null;
  let sequence = 0;
  let announcement = $state({ text: '', sequence });
  const announce = (text: string) => (announcement = { text, sequence: ++sequence });
  $effect(() => {
    const { messages, states } = pickAnnouncements(announced, projected);
    announced = states;
    if (messages.length) announce(messages.join(' '));
  });

  /** Runs one operation; resolves to its result, or null when it failed, which shows inline and is announced. */
  async function run(operation: OperationName, input: Record<string, unknown>, timerId: string | null): Promise<Record<string, unknown> | null> {
    const key = timerId ?? operation;
    if (busy[key]) return null;
    busy[key] = true;
    let outcome: unknown;
    try {
      outcome = await actions.invoke(operation, input);
    } catch (error) {
      outcome = error instanceof Error ? error : new Error(String(error));
    } finally {
      busy[key] = false;
    }
    const readBack = readOutcome(operation, timerId, outcome);
    if (!readBack.ok) {
      failure = readBack.failure;
      announce(failureText(readBack.failure));
      return null;
    }
    if (failure && (failure.timerId === timerId || failure.timerId === null)) failure = null;
    timers = applyResult(timers, readBack.result);
    return readBack.result;
  }

  async function control(timerId: string, name: ControlName): Promise<void> {
    if (name === 'reset' || name === 'remove') {
      const press = pressDestructive(armed, timerId, name, now());
      armed = press.armed;
      if (!press.run) return;
    } else {
      armed = null;
    }
    const removed = (await run(name, { id: timerId }, timerId)) !== null && name === 'remove';
    if (removed) {
      // The card is gone; keep focus inside the board.
      await tick();
      listElement?.focus();
    }
  }

  async function loadPresets(): Promise<Preset[] | null> {
    const listed = await run('presets.list', {}, null);
    return listed && readPresets(listed);
  }

  const boardFailure = $derived(failure && !projected.some((timer) => timer.definition.id === failure?.timerId) ? failure : null);
</script>

<section class="board" class:compact={density === 'compact'} aria-labelledby={titleId}>
  <header class="board-header">
    <h2 id={titleId}>Timers</h2>
    {#if read.ok}
      <p class="observed">Observed <time datetime={new Date(read.result.observedAt).toISOString()}>{formatClockTime(read.result.observedAt)}</time></p>
    {/if}
  </header>

  <div class="sr-only" aria-live="polite" aria-atomic="true">
    {#key announcement.sequence}<p>{announcement.text}</p>{/key}
  </div>

  {#if !read.ok}
    <p class="error">This timer data could not be read ({read.message}).</p>
  {:else}
    {#if boardFailure}
      <p class="error">{failureText(boardFailure)}</p>
    {/if}

    <div class="list" bind:this={listElement} tabindex="-1">
      {#each projected as snapshot (snapshot.definition.id)}
        <TimerCard
          {snapshot}
          {capabilities}
          {density}
          {armed}
          {clock}
          busy={busy[snapshot.definition.id] ?? false}
          failure={failure?.timerId === snapshot.definition.id ? failureText(failure) : null}
          oncontrol={(name) => control(snapshot.definition.id, name)}
        />
      {:else}
        <p class="empty">No timers yet.</p>
      {/each}
    </div>

    {#if capabilities.create}
      <CreateTimer
        {density}
        busy={busy.create ?? false}
        {loadPresets}
        oncreate={async (input) => (await run('create', input, null)) !== null}
      />
    {/if}
  {/if}
</section>

<style>
  .board {
    --timer-bg: #ffffff;
    --timer-surface: #f5f6f8;
    --timer-border: #d9dce1;
    --timer-text: #16181d;
    --timer-muted: #5c6370;
    --timer-accent: #2459d6;
    --timer-danger: #b3261e;
    --phase-prep: #8a5a00;
    --phase-work: #c2410c;
    --phase-rest: #15803d;
    --phase-cooldown: #1d4ed8;
    color: var(--timer-text);
    background: var(--timer-bg);
    font: 14px/1.4 system-ui, -apple-system, 'Segoe UI', sans-serif;
    padding: 16px;
    display: grid;
    gap: 12px;
  }
  @media (prefers-color-scheme: dark) {
    .board {
      --timer-bg: #121418;
      --timer-surface: #1c1f25;
      --timer-border: #343943;
      --timer-text: #eceef2;
      --timer-muted: #a3aab6;
      --timer-accent: #7aa2ff;
      --timer-danger: #ff8a80;
      --phase-prep: #f2c14e;
      --phase-work: #fb923c;
      --phase-rest: #4ade80;
      --phase-cooldown: #93c5fd;
    }
  }
  .compact {
    padding: 8px;
    gap: 8px;
    font-size: 13px;
  }
  .board-header {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
  }
  h2 {
    margin: 0;
    font-size: 1.15em;
  }
  .observed,
  .empty {
    margin: 0;
    color: var(--timer-muted);
  }
  .list {
    display: grid;
    gap: 8px;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  }
  .compact .list {
    grid-template-columns: 1fr;
  }
  .list:focus-visible {
    outline: 2px solid var(--timer-accent);
    outline-offset: 2px;
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
