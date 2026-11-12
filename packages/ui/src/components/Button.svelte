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

  let { variant = 'secondary', size = 'md', icon, children, type = 'button', class: className = '', ...rest }: Props = $props();
</script>

<button {type} {...rest} class="ui-button {variant} {size} {className}">
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
  /* Hover keeps the fill (and so the label's contrast) and adds a halo. */
  .primary:not(:disabled):hover { background: var(--ui-color-accent-solid); box-shadow: 0 0 0 3px var(--ui-color-accent-soft); }
  .ghost { background: transparent; border-color: transparent; color: var(--ui-color-text-secondary); }
  .ghost:not(:disabled):hover { color: var(--ui-color-text-primary); }
  .danger { color: var(--ui-color-danger-text); border-color: var(--ui-color-danger-subtle); }
</style>
