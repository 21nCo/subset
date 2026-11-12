<!--
  A disclosure menu: an icon button that opens a small panel of actions. Escape closes it and returns focus to
  the button; moving focus to another element, or pressing anywhere outside it, closes it. Put MenuItem buttons in `children`.
-->
<script lang="ts">
  import type { Component, Snippet } from 'svelte';
  import IconButton from './IconButton.svelte';

  interface Props {
    icon: Component<Record<string, unknown>>;
    label: string;
    open?: boolean;
    placement?: 'above' | 'below';
    align?: 'start' | 'end';
    size?: 'sm' | 'md';
    children: Snippet;
  }

  let { icon, label, open = $bindable(false), placement = 'below', align = 'end', size = 'md', children }: Props = $props();
  const id = $props.id();
  let root = $state<HTMLElement>();

  function close(returnFocus: boolean) {
    open = false;
    if (returnFocus) root?.querySelector<HTMLButtonElement>('button')?.focus();
  }
</script>

<svelte:window
  onpointerdown={(event) => {
    if (open && root && !root.contains(event.target as Node)) close(false);
  }}
/>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="ui-menu"
  bind:this={root}
  onkeydown={(event) => {
    if (event.key === 'Escape' && open) {
      event.preventDefault();
      event.stopPropagation();
      close(true);
    }
  }}
  onfocusout={(event) => {
    // Focus moving to another element outside closes the menu. Focus lost to nothing (Safari clears it on a
    // mouse press, before the item's click) does not: an outside press is handled by the window listener.
    const next = event.relatedTarget as Node | null;
    if (open && next && !root?.contains(next)) open = false;
  }}
>
  <IconButton {icon} {label} {size} variant="ghost" aria-expanded={open} aria-controls={id} onclick={() => (open = !open)} />
  {#if open}
    <div class="panel {placement} {align}" {id} role="group" aria-label={label}>
      {@render children()}
    </div>
  {/if}
</div>

<style>
  .ui-menu { position: relative; display: inline-block; }
  .panel {
    position: absolute;
    z-index: 20;
    min-width: 12rem;
    display: grid;
    padding: var(--ui-space-1);
    background: var(--ui-color-surface-overlay);
    border: 1px solid var(--ui-color-border-subtle);
    border-radius: var(--ui-radius-panel);
    box-shadow: var(--ui-shadow-overlay);
  }
  .below { top: calc(100% + 6px); }
  .above { bottom: calc(100% + 6px); }
  .end { right: 0; }
  .start { left: 0; }
</style>
