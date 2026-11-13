<!-- A raised panel with the shape's panel radius. -->
<script lang="ts">
  import type { Snippet } from 'svelte';
  import type { HTMLAttributes } from 'svelte/elements';

  interface Props extends HTMLAttributes<HTMLElement> {
    as?: 'article' | 'section' | 'div';
    padding?: 'none' | 'sm' | 'md' | 'lg';
    children: Snippet;
  }

  let { as = 'div', padding = 'md', children, class: className = '', ...rest }: Props = $props();
</script>

<svelte:element this={as} class="ui-card pad-{padding} {className}" {...rest}>
  {@render children()}
</svelte:element>

<style>
  .ui-card {
    background: var(--ui-color-surface-raised);
    border: 1px solid var(--ui-color-border-subtle);
    border-radius: var(--ui-radius-panel);
    box-shadow: var(--ui-shadow-raised);
  }
  .pad-sm { padding: var(--ui-space-3); }
  .pad-md { padding: var(--ui-space-4) var(--ui-space-5); }
  .pad-lg { padding: var(--ui-space-6); }
</style>
