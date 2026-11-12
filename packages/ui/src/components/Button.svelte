<!-- A text button, optionally with a leading icon. Variants: primary, secondary (default), ghost, danger. -->
<script lang="ts">
  import type { Component, Snippet } from 'svelte';
  import type { HTMLButtonAttributes } from 'svelte/elements';
  import Icon from './Icon.svelte';

  interface Props extends HTMLButtonAttributes {
    variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
    size?: 'sm' | 'md';
    icon?: Component<Record<string, unknown>>;
    children: Snippet;
  }

  let { variant = 'secondary', size = 'md', icon, children, type = 'button', ...rest }: Props = $props();
</script>

<button {type} class="ui-button {variant} {size}" {...rest}>
  {#if icon}<Icon {icon} size={size === 'sm' ? 16 : 18} />{/if}
  {@render children()}
</button>

<style>
  .ui-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: var(--ui-space-2);
    height: var(--ui-control-height);
    padding: 0 var(--ui-space-4);
    font: inherit;
    font-weight: var(--ui-font-weight-medium);
    color: var(--ui-color-text-primary);
    background: var(--ui-color-surface-raised);
    border: 1px solid var(--ui-color-border-default);
    border-radius: var(--ui-radius-control);
    cursor: pointer;
    white-space: nowrap;
    transition: background 120ms ease, border-color 120ms ease, transform 80ms ease;
  }
  .ui-button:not(:disabled):hover { background: var(--ui-color-surface-hover); }
  .ui-button:not(:disabled):active { transform: translateY(1px); }
  .ui-button:disabled { opacity: 0.45; cursor: default; }
  .sm { height: 1.875rem; padding: 0 var(--ui-space-3); font-size: var(--ui-font-size-sm); }
  .primary { background: var(--ui-color-accent-solid); border-color: var(--ui-color-accent-solid); color: var(--ui-color-accent-contrast); }
  .primary:not(:disabled):hover { background: var(--ui-color-accent-solid); filter: brightness(1.06); }
  .ghost { background: transparent; border-color: transparent; color: var(--ui-color-text-secondary); }
  .danger { color: var(--ui-color-danger-solid); border-color: var(--ui-color-danger-subtle); }
</style>
