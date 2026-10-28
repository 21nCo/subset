<!--
  The standalone Timer page served by `subset-timer serve`. It mounts the board (`subset.timer.board@1`)
  with the HTTP transport in transport.ts and shows the daemon's state as it changes. The person at the
  keyboard is the user, so the board may create timers and run reset and remove.
-->
<script lang="ts">
  import { onMount } from 'svelte';
  import type { TimerBoardResult } from '@subset.dev/timer-core';
  import TimerBoard from '@subset.dev/timer-core/view';
  import { actions, followState, type Connection } from './transport.js';

  let result = $state.raw<TimerBoardResult | null>(null);
  let connection = $state<Connection>('connecting');

  onMount(() =>
    followState({
      onState: (next) => (result = next),
      onConnection: (next) => (connection = next)
    })
  );
</script>

<main>
  <h1>Timer</h1>
  <p class="status" class:unavailable={connection === 'unavailable'} role="status">
    {#if connection === 'unavailable'}Daemon unavailable — retrying…{:else if connection === 'connecting'}Connecting to the Timer daemon…{/if}
  </p>
  {#if result}
    <TimerBoard {result} {actions} capabilities={{ create: true, destructive: true }} density="full" />
  {/if}
</main>

<style>
  :global(body) {
    margin: 0;
    background: #ffffff;
  }
  @media (prefers-color-scheme: dark) {
    :global(body) {
      background: #121418;
      color: #eceef2;
    }
  }
  main {
    max-width: 1100px;
    margin: 0 auto;
    padding: 16px;
    font: 14px/1.4 system-ui, -apple-system, 'Segoe UI', sans-serif;
  }
  h1 {
    margin: 0 16px;
    font-size: 1.5em;
  }
  .status {
    margin: 4px 16px 0;
    min-height: 1.4em;
    color: #5c6370;
  }
  .unavailable {
    color: #b3261e;
  }
  @media (prefers-color-scheme: dark) {
    .status {
      color: #a3aab6;
    }
    .unavailable {
      color: #ff8a80;
    }
  }
</style>
