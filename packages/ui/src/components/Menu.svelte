<!--
  A disclosure menu: an icon button that opens a small panel of actions. Choosing an enabled item (pointer, Enter
  or Space) or pressing Escape closes it and returns focus to the button, unless the action moved focus elsewhere;
  moving focus to another element, or pressing anywhere outside it, closes it. Put MenuItem buttons in `children`.
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
  onkeydown={(event) => {
    // Focus outside the menu: on the window, so Escape works when a mouse click opened it and left focus on the page
    // (Safari does not focus clicked buttons). Focus returns to the toggle unless it is elsewhere on purpose.
    if (open && event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      close(root?.contains(document.activeElement) || document.activeElement === document.body);
    }
  }}
/>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="ui-menu"
  bind:this={root}
  onkeydown={(event) => {
    // Focus inside the menu: close it here, and keep Escape from also closing a dialog the menu sits in.
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
    <!-- Enter and Space on an item fire click, so this handler covers keyboard activation too. -->
    <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
    <div
      class="panel {placement} {align}"
      {id}
      role="group"
      aria-label={label}
      onclick={(event) => {
        // Choosing an item closes the menu after the item's own handler has run. A disabled item does nothing.
        const item = (event.target as Element).closest('button');
        if (!item || item.disabled || item.getAttribute('aria-disabled') === 'true' || !event.currentTarget.contains(item)) return;
        // Focus returns to the toggle only if the action left it in the menu, or nowhere (Safari does not focus a
        // clicked button), never when the action moved it elsewhere on purpose.
        close(root?.contains(document.activeElement) || document.activeElement === document.body);
      }}
    >
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
