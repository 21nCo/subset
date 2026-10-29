<!--
  The Usage dashboard inside an MCP host (SET-105): `UsageDashboard` with the status and history the
  bridge passes and a Refresh that calls usage_status through the host. It is read-only: no write prop
  (redeemReset, manageAccounts, openAccount, togglePin) is passed, so no write control renders. Below it,
  the local sign-ins disclosure AGENTS.md requires wherever those accounts show: the tools it names and
  that their endpoints are undocumented. The setting itself is changed only in the standalone dashboard.
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
  // With no status, a tool error or a failed connection shows in place of the dashboard.
  const failure = $derived(view.toolError ?? (view.status ? null : view.connectError));
</script>

{#snippet notice()}
  <p class="notice" role="status">{view.refreshError ? `Could not refresh: ${view.refreshError}` : view.connectError}</p>
{/snippet}

<main>
  <!-- The bridge holds a tool error or a status, never both: the error, or a failed connection before any
       status, shows in place of the dashboard, with a Refresh that reads usage_status again or, before the
       host has connected the view, asks it to (the R key does the same). -->
  {#if failure}
    <div class="failed">
      <p class="error" role="alert">{failure}</p>
      {#if view.refreshError}{@render notice()}{/if}
      <button type="button" onclick={refresh} disabled={view.busy} aria-keyshortcuts="r">{view.busy ? 'Checking' : 'Refresh'}</button>
    </div>
  {:else}
    <UsageDashboard status={view.status ?? waiting} loading={!view.status} busy={view.busy} refresh={view.status ? refresh : undefined}
      history={view.history} notice={view.refreshError || view.connectError ? notice : undefined} {sortMode} {setSortMode} {showTrends} {setShowTrends} />
  {/if}
  <p class="disclosure">With <strong>Use local sign-ins</strong> on, this view also shows the accounts signed in to Claude Code, Factory Droid, the Cursor app, Devin, Pi, OpenCode, omp, and Hermes on this computer, and the Antigravity account email. Their usage endpoints are undocumented by their makers, so they may change or stop working.</p>
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
  .failed {
    display: grid;
    justify-items: start;
    gap: 12px;
    padding: 12px 20px;
  }
  .error {
    color: light-dark(#b3261e, #ff8a80);
  }
  .failed .notice {
    padding: 0;
  }
  .disclosure {
    padding: 0 20px 12px;
    font-size: 12px;
    color: light-dark(#5c5f63, #a4a5a8);
  }
  button {
    font: 500 13px/1 var(--subset-font);
    padding: 7px 12px;
    border-radius: 6px;
    border: 1px solid light-dark(#d6d4cc, #34343a);
    background: light-dark(#fff, #1f1f22);
    color: inherit;
    cursor: pointer;
  }
  button:disabled {
    cursor: default;
    opacity: 0.6;
  }
  button:focus-visible {
    outline: 2px solid light-dark(#1a73e8, #8ab4f8);
    outline-offset: 2px;
  }
</style>
