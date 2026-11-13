<!-- An icon-only button; `label` is its accessible name and tooltip. -->
<script lang="ts">
  import type { Component } from 'svelte';
  import type { HTMLButtonAttributes } from 'svelte/elements';
  import Icon from './Icon.svelte';

  interface Props extends HTMLButtonAttributes {
    icon: Component<Record<string, unknown>>;
    label: string;
    variant?: 'primary' | 'secondary' | 'ghost';
    size?: 'sm' | 'md' | 'lg';
    weight?: 'regular' | 'bold' | 'fill';
    /** A tooltip other than the label, such as one naming the key shortcut. */
    hint?: string;
  }

  let { icon, label, variant = 'secondary', size = 'md', weight = 'regular', hint, type = 'button', class: className = '', ...rest }: Props = $props();
  const iconSize = $derived(size === 'sm' ? 16 : size === 'lg' ? 24 : 18);
</script>

<button {type} {...rest} class="ui-icon-button {variant} {size} {className}" aria-label={label} title={hint ?? label}>
  <Icon {icon} size={iconSize} {weight} />
</button>

<style>
  .ui-icon-button {
    display: inline-grid;
    place-items: center;
    width: var(--ui-control-height);
    height: var(--ui-control-height);
    padding: 0;
    color: var(--ui-color-text-primary);
    background: var(--ui-color-surface-raised);
    border: 1px solid var(--ui-color-border-default);
    border-radius: var(--ui-radius-control);
    cursor: pointer;
    transition: background 120ms ease, transform 80ms ease;
  }
  .ui-icon-button:not(:disabled):hover { background: var(--ui-color-surface-hover); }
  .ui-icon-button:not(:disabled):active { transform: scale(0.95); }
  .ui-icon-button:disabled { opacity: 0.45; cursor: default; }
  .sm { width: 1.875rem; height: 1.875rem; }
  .lg { width: 3rem; height: 3rem; border-radius: var(--ui-radius-panel); }
  .primary { background: var(--ui-color-accent-solid); border-color: var(--ui-color-accent-solid); color: var(--ui-color-accent-contrast); }
  /* Hover keeps the fill (and so the label's contrast) and adds a halo, never in place of the focus ring. */
  .primary:not(:disabled):hover { background: var(--ui-color-accent-solid); }
  .primary:not(:disabled):hover:not(:focus-visible) { box-shadow: 0 0 0 3px var(--ui-color-accent-soft); }
  .ghost { background: transparent; border-color: transparent; color: var(--ui-color-text-secondary); }
  .ghost:not(:disabled):hover { color: var(--ui-color-text-primary); }
</style>
