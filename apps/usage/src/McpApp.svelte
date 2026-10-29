<!--
  The Usage dashboard inside an MCP host (SET-105): `UsageDashboard` with the status and history the
  bridge passes and a Refresh that calls usage_status through the host. It is read-only: no write prop
  (redeemReset, manageAccounts, openAccount, togglePin) is passed, so no write control renders.
  Sort and trend charts start at the dashboard's defaults (dashboard.html is under the 1.5 MB at which
  trends would start off); a change is kept in local storage when the host's iframe allows it.
-->
<script lang="ts">
  import { untrack } from 'svelte';
  import UsageDashboard from '@subset.dev/usage-core/view';
  import { createUsageStatus } from '@subset.dev/usage-core';
  import type { SortMode } from '@subset.dev/usage-core/present';
  import type { Bridge } from './mcp-bridge.js';

  let { bridge }: { bridge: Bridge } = $props();
  let view = $state.raw(untrack(() => bridge.state()));
  $effect(() => bridge.subscribe((next) => (view = next)));

  const SORT_KEY = 'subset.usage.mcp.sort';
  const TRENDS_KEY = 'subset.usage.mcp.trends';
  /** A stored setting; a sandboxed iframe may forbid storage, and then the default applies. */
  function read(key: string): string | null {
    try { return localStorage.getItem(key); } catch { return null; }
  }
  function save(key: string, value: string) {
    try { localStorage.setItem(key, value); } catch { /* the setting lasts for this view only */ }
  }
  const storedSort = read(SORT_KEY);
  let sortMode = $state<SortMode>(storedSort === 'recent' || storedSort === 'expiring' ? storedSort : 'default');
  let showTrends = $state(read(TRENDS_KEY) !== 'false');
  const setSortMode = (mode: SortMode) => { sortMode = mode; save(SORT_KEY, mode); };
  const setShowTrends = (value: boolean) => { showTrends = value; save(TRENDS_KEY, String(value)); };

  const waiting = createUsageStatus([]);
  const refresh = () => void bridge.refresh();
</script>

{#snippet notice()}
  <p class="notice" role="status">Could not refresh: {view.refreshError}</p>
{/snippet}

<main>
  <!-- The bridge holds a tool error or a status, never both: the error shows in place of the dashboard. -->
  {#if view.toolError}
    <p class="error" role="alert">{view.toolError}</p>
  {:else}
    <UsageDashboard status={view.status ?? waiting} loading={!view.status} busy={view.busy} refresh={view.status ? refresh : undefined}
      history={view.history} notice={view.refreshError ? notice : undefined} {sortMode} {setSortMode} {showTrends} {setShowTrends} />
  {/if}
</main>

<style>
  :global(html) {
    color-scheme: light dark;
    background: light-dark(#f5f4f0, #141414);
    /* The system font stack: the view loads no font files. */
    --subset-font: ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
  }
  :global(body) {
    margin: 0;
  }
  p {
    margin: 0;
    font: 13px/1.4 var(--subset-font);
  }
  /* Inside the dashboard, above the accounts. */
  .notice {
    padding: 0 0 12px;
    color: light-dark(#5c5f63, #a4a5a8);
  }
  .error {
    padding: 12px 20px;
    color: light-dark(#b3261e, #ff8a80);
  }
</style>
