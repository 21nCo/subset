<!-- A small status label. Tones: neutral (default), accent, success, danger. -->
<script lang="ts">
  import type { Snippet } from 'svelte';

  let { tone = 'neutral', children }: { tone?: 'neutral' | 'accent' | 'success' | 'danger'; children: Snippet } = $props();
</script>

<span class="ui-pill {tone}">{@render children()}</span>

<style>
  .ui-pill {
    display: inline-flex;
    align-items: center;
    gap: var(--ui-space-1);
    padding: 0.125rem 0.5rem;
    font-size: var(--ui-font-size-xs);
    font-weight: var(--ui-font-weight-medium);
    line-height: 1.4;
    border-radius: var(--ui-radius-pill);
    color: var(--ui-color-text-secondary);
    background: var(--ui-color-surface-sunken);
    white-space: nowrap;
  }
  .accent { color: var(--ui-color-accent-on-soft); background: var(--ui-color-accent-soft); }
  .success { color: var(--ui-color-success-on-subtle); background: var(--ui-color-success-subtle); }
  .danger { color: var(--ui-color-danger-on-subtle); background: var(--ui-color-danger-subtle); }
</style>
