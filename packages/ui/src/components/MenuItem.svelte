<!-- One action in a Menu. `tone="danger"` for destructive actions. -->
<script lang="ts">
  import type { Component, Snippet } from 'svelte';
  import type { HTMLButtonAttributes } from 'svelte/elements';
  import Icon from './Icon.svelte';

  interface Props extends HTMLButtonAttributes {
    icon?: Component<Record<string, unknown>>;
    tone?: 'neutral' | 'danger';
    children: Snippet;
  }

  let { icon, tone = 'neutral', children, type = 'button', ...rest }: Props = $props();
</script>

<button {type} class="ui-menu-item {tone}" {...rest}>
  {#if icon}<Icon {icon} size={16} />{/if}
  {@render children()}
</button>

<style>
  .ui-menu-item {
    display: flex;
    align-items: center;
    gap: var(--ui-space-2);
    padding: var(--ui-space-2) var(--ui-space-3);
    font: inherit;
    color: var(--ui-color-text-primary);
    text-align: left;
    white-space: nowrap;
    background: transparent;
    border: none;
    border-radius: var(--ui-radius-control);
    cursor: pointer;
  }
  .ui-menu-item:not(:disabled):hover { background: var(--ui-color-surface-hover); }
  .ui-menu-item:disabled { opacity: 0.45; cursor: default; }
  .danger { color: var(--ui-color-danger-solid); }
</style>
