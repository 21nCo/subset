<!--
  One action in a Menu. `tone="danger"` for destructive actions. An item marked `aria-disabled="true"` stays focusable
  but, like a `disabled` one, runs no `onclick` (pointer, Enter or Space, on the button or its icon) and keeps the menu open.
-->
<script lang="ts">
  import type { Component, Snippet } from 'svelte';
  import type { HTMLButtonAttributes } from 'svelte/elements';
  import Icon from './Icon.svelte';

  interface Props extends HTMLButtonAttributes {
    icon?: Component<Record<string, unknown>>;
    tone?: 'neutral' | 'danger';
    children: Snippet;
  }

  let { icon, tone = 'neutral', children, type = 'button', class: className = '', onclick, ...rest }: Props = $props();
  const inert = $derived(rest['aria-disabled'] === true || rest['aria-disabled'] === 'true');
</script>

<button
  {type}
  {...rest}
  class="ui-menu-item {tone} {className}"
  onclick={(event) => {
    // Stopping the click here, before the consumer's handler, also keeps the Menu from closing.
    if (inert) {
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    onclick?.(event);
  }}
>
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
  .ui-menu-item:not(:disabled, [aria-disabled='true']):hover { background: var(--ui-color-surface-hover); }
  .ui-menu-item:is(:disabled, [aria-disabled='true']) { opacity: 0.45; cursor: default; }
  .danger { color: var(--ui-color-danger-text); }
</style>
