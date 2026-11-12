<!--
  A modal dialog on the native <dialog> element (focus trap, Escape and the top layer come from the browser).
  `open` is bindable; closing by Escape, the close button or a backdrop click sets it false.
-->
<script lang="ts">
  import type { Snippet } from 'svelte';
  import XIcon from 'phosphor-svelte/lib/XIcon';
  import IconButton from './IconButton.svelte';

  interface Props {
    title: string;
    open?: boolean;
    width?: string;
    children: Snippet;
    footer?: Snippet;
  }

  let { title, open = $bindable(false), width = '32rem', children, footer }: Props = $props();
  const titleId = $props.id();
  let dialog = $state<HTMLDialogElement>();

  $effect(() => {
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    else if (!open && dialog.open) dialog.close();
  });
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
<dialog
  bind:this={dialog}
  class="ui-dialog"
  style:--ui-dialog-width={width}
  aria-labelledby={titleId}
  onclose={() => (open = false)}
  onclick={(event) => {
    if (event.target === dialog) open = false;
  }}
>
  <div class="panel">
    <header>
      <h2 id={titleId}>{title}</h2>
      <IconButton icon={XIcon} label="Close" variant="ghost" size="sm" onclick={() => (open = false)} />
    </header>
    <div class="body">{@render children()}</div>
    {#if footer}<footer>{@render footer()}</footer>{/if}
  </div>
</dialog>

<style>
  .ui-dialog {
    width: min(var(--ui-dialog-width), calc(100vw - 2rem));
    max-height: calc(100dvh - 3rem);
    padding: 0;
    color: var(--ui-color-text-primary);
    background: var(--ui-color-surface-overlay);
    border: 1px solid var(--ui-color-border-subtle);
    border-radius: var(--ui-radius-panel);
    box-shadow: var(--ui-shadow-overlay);
    font: inherit;
  }
  .ui-dialog::backdrop { background: rgb(0 0 0 / 40%); }
  .panel { display: grid; gap: var(--ui-space-4); padding: var(--ui-space-5); }
  header { display: flex; align-items: center; justify-content: space-between; gap: var(--ui-space-3); }
  h2 { margin: 0; font-size: var(--ui-font-size-lg); font-weight: var(--ui-font-weight-bold); }
  footer { display: flex; justify-content: flex-end; gap: var(--ui-space-2); }
</style>
