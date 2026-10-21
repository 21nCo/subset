<!--
  The Timer board, view ID `subset.timer.board@1`. It renders the timers in `result`, re-projects them
  from their timestamps every 250 ms and runs every change through `actions.invoke`. It never fetches:
  each host supplies its own transport. After each change it reads the board through `list`; the pure
  reconciler in `view-model.ts` (`actionIssued`, `replySettled`, `readIssued`, `readSettled`,
  `hostArrived`, `boardView`, `nextRead`) owns what the replies, those reads and the host's `result` show,
  and when the board reads again.
-->
<script lang="ts">
  import { onMount, tick, untrack } from 'svelte';
  import type { Preset } from '../model.js';
  import type { OperationName } from '../operations.js';
  import CreateTimer from './CreateTimer.svelte';
  import TimerCard from './TimerCard.svelte';
  import {
    REFRESH_MS, actionIssued, boardView, cancelsRepeat, emptyBoardState, failureText, focusDisplaced, formatClockTime, hostArrived,
    nextRead, pickAnnouncements, pressDestructive, readBoardResult, readIssued, readPresets, readSettled, readsAfter, replySettled, reproject,
    type ActionFailure, type AnnouncedStates, type Armed, type ControlName, type TimerBoardProps
  } from './view-model.js';

  let { result, actions, now = Date.now, capabilities, density }: TimerBoardProps = $props();
  const uid = $props.id();
  const titleId = `${uid}-title`;

  const read = $derived(readBoardResult(result));
  // The board's own reads and the changes they have not yet confirmed; see `boardView`.
  let known = $state.raw(emptyBoardState());
  const board = $derived(read.ok ? boardView(read.result, known) : null);
  let clock = $state(untrack(() => now()));
  const projected = $derived(board ? board.timers.map((timer) => reproject(timer, clock)) : []);

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

  /** What `invoke` gave back; a thrown or rejected call becomes its error. */
  async function invoke(operation: OperationName, input: Record<string, unknown>): Promise<unknown> {
    try {
      return await actions.invoke(operation, input);
    } catch (error) {
      return error instanceof Error ? error : new Error(String(error));
    }
  }

  function fail(next: ActionFailure) {
    failure = next;
    announce(failureText(next));
  }

  /** Runs one operation; resolves to its result, or null when it failed, which shows inline and is announced. */
  async function run(operation: OperationName, input: Record<string, unknown>, timerId: string | null): Promise<Record<string, unknown> | null> {
    const key = timerId ?? operation;
    if (busy[key]) return null;
    busy[key] = true;
    const issue = actionIssued(known);
    known = issue.state;
    const outcome = await invoke(operation, input);
    busy[key] = false;
    const settled = replySettled(known, operation, timerId, outcome, issue.issued);
    known = settled.state;
    if (readsAfter(operation, outcome)) void refresh();
    else drain();
    if (!settled.outcome.ok) {
      fail(settled.outcome.failure);
      return null;
    }
    if (failure && (failure.timerId === timerId || failure.timerId === null)) failure = null;
    return settled.outcome.result;
  }

  // Each new host result is recorded, so later actions and reads come after it.
  $effect(() => {
    const host = read;
    untrack(() => {
      if (!host.ok) return;
      known = hostArrived(known, host.result);
      drain();
    });
  });

  /** Issues the one read the reconciler asks for, if any (see `nextRead`); called after every event. */
  function drain() {
    if (read.ok && nextRead(read.result, known)) void refresh();
  }

  /** Reads the host's board, which retires the changes the base then comes after. */
  async function refresh(): Promise<void> {
    const issue = readIssued(known);
    known = issue.state;
    const outcome = await invoke('list', {});
    const settled = readSettled(known, issue.issued, outcome);
    known = settled.state;
    // An ignored read (a later-issued one already succeeded) neither fails nor clears a List failure.
    if (settled.failure) {
      // It does not replace an action's failure still shown, such as the refused change it followed.
      if (failure?.operation === 'list' || !failure) fail(settled.failure);
    } else if (settled.taken && failure?.operation === 'list') {
      failure = null;
    }
    drain();
  }

  async function control(timerId: string, name: ControlName): Promise<void> {
    // Where focus was when the action started, if on this timer's card.
    const origin = listElement?.contains(document.activeElement) ? document.activeElement : null;
    if (name === 'reset' || name === 'remove') {
      const at = now();
      // The label follows `clock`; move it to the press so "Press again" shows at once.
      clock = at;
      const press = pressDestructive(armed, timerId, name, at);
      armed = press.armed;
      if (!press.run) return;
    } else {
      armed = null;
    }
    const removed = (await run(name, { id: timerId }, timerId)) !== null && name === 'remove';
    if (removed) {
      // The card is gone; keep focus inside the board, unless the user has moved it elsewhere.
      await tick();
      if (focusDisplaced(origin, document.activeElement, document.body)) listElement?.focus();
    }
  }

  async function loadPresets(): Promise<Preset[] | null> {
    const listed = await run('presets.list', {}, null);
    return listed && readPresets(listed);
  }

  const boardFailure = $derived(failure && !projected.some((timer) => timer.definition.id === failure?.timerId) ? failure : null);
</script>

<!-- Cancels a held Enter's repeated clicks and submits on every control (`cancelsRepeat`). -->
<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<section
  class="board"
  class:compact={density === 'compact'}
  aria-labelledby={titleId}
  onkeydown={(event) => {
    if (cancelsRepeat(event)) event.preventDefault();
  }}
>
  <header class="board-header">
    <h2 id={titleId}>Timers</h2>
    {#if board}
      <p class="observed">Observed <time datetime={new Date(board.observedAt).toISOString()}>{formatClockTime(board.observedAt)}</time></p>
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
  /* The system's dark scheme, unless the host sets data-theme="light" on the page's root element. */
  @media (prefers-color-scheme: dark) {
    :global(:root:not([data-theme='light'])) .board {
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
  /* A host that sets data-theme="dark" (the MCP App, from the host's theme) gets it whatever the system's. */
  :global(:root[data-theme='dark']) .board {
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
