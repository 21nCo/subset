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

  let { icon, label, variant = 'secondary', size = 'md', weight = 'regular', hint, type = 'button', ...rest }: Props = $props();
  const iconSize = $derived(size === 'sm' ? 16 : size === 'lg' ? 24 : 18);
</script>

<button {type} class="ui-icon-button {variant} {size}" aria-label={label} title={hint ?? label} {...rest}>
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
  .primary:not(:disabled):hover { background: var(--ui-color-accent-solid); filter: brightness(1.06); }
  .ghost { background: transparent; border-color: transparent; color: var(--ui-color-text-secondary); }
</style>
