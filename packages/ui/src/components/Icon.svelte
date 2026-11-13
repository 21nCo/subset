<!-- A Phosphor icon (phosphor-svelte) at a token size. Decorative unless `label` is given. -->
<script lang="ts">
  import type { Component } from 'svelte';

  interface Props {
    icon: Component<Record<string, unknown>>;
    size?: number;
    weight?: 'thin' | 'light' | 'regular' | 'bold' | 'fill' | 'duotone';
    /** Names the icon for assistive technology; without it the icon is hidden from them. */
    label?: string;
  }

  let { icon: IconComponent, size = 20, weight = 'regular', label }: Props = $props();
</script>

<IconComponent {size} {weight} color="currentColor" aria-hidden={label ? undefined : 'true'} aria-label={label} role={label ? 'img' : undefined} focusable="false" />
