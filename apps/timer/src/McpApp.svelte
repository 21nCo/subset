<!--
  The Timer board inside an MCP host (SET-80). The board is `subset.timer.board@1` with the result the
  bridge passes and its actions; the user acts through the host, which applies its own approval to
  destructive tools, so the board may create timers and run reset and remove.
-->
<script lang="ts">
  import { untrack } from 'svelte';
  import TimerBoard from '@subset.dev/timer-core/view';
  import type { Bridge } from './mcp-bridge.js';

  let { bridge }: { bridge: Bridge } = $props();
  let view = $state.raw(untrack(() => bridge.state()));
  $effect(() => bridge.subscribe((next) => (view = next)));
</script>

<main>
  {#if view.refreshError}
    <p class="status" role="status">Could not refresh the timers: {view.refreshError}</p>
  {/if}
  <!-- The bridge holds a tool error or a board, never both: the error shows in place of the board. -->
  {#if view.toolError}
    <p class="error" role="alert">{view.toolError}</p>
  {:else if view.result}
    <TimerBoard result={view.result} actions={bridge.actions} capabilities={{ create: true, destructive: true }} density="compact" />
  {:else}
    <p class="status" role="status">Waiting for the timers…</p>
  {/if}
</main>

<style>
  :global(body) {
    margin: 0;
  }
  main {
    font: 13px/1.4 system-ui, -apple-system, 'Segoe UI', sans-serif;
    color: light-dark(#16181d, #eceef2);
  }
  p {
    margin: 0;
    padding: 6px 8px;
  }
  .status {
    color: light-dark(#5c6370, #a3aab6);
  }
  .error {
    color: light-dark(#b3261e, #ff8a80);
  }
</style>
