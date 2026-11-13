<!-- Chooses the colour scheme family and light, dark or system. Typeface and shape are fixed in Subset. -->
<script lang="ts">
  import { MODES, type Appearance, type Mode } from '../appearance.js';
  import { SCHEME_FAMILIES } from '../schemes.js';
  import SegmentedControl from './SegmentedControl.svelte';

  let { appearance = $bindable(), onchange }: { appearance: Appearance; onchange?: (next: Appearance) => void } = $props();
  const name = $props.id();
  const MODE_LABELS: Record<Mode, string> = { system: 'System', light: 'Light', dark: 'Dark' };

  function update(next: Partial<Appearance>) {
    appearance = { ...appearance, ...next };
    onchange?.(appearance);
  }
</script>

<div class="ui-appearance">
  <SegmentedControl label="Mode" options={MODES.map((mode) => ({ value: mode, label: MODE_LABELS[mode] }))} value={appearance.mode} onchange={(mode) => update({ mode })} />
  <fieldset>
    <legend>Colour scheme</legend>
    <div class="families">
      {#each SCHEME_FAMILIES as family (family.id)}
        <label class="family" class:checked={appearance.family === family.id}>
          <input type="radio" {name} value={family.id} checked={appearance.family === family.id} onchange={() => update({ family: family.id })} />
          <span class="swatch" aria-hidden="true">
            <span style:background={family.light.colors['surface-canvas']}><i style:background={family.light.colors['accent-solid']}></i></span>
            <span style:background={family.dark.colors['surface-canvas']}><i style:background={family.dark.colors['accent-solid']}></i></span>
          </span>
          {family.label}
        </label>
      {/each}
    </div>
  </fieldset>
</div>

<style>
  .ui-appearance { display: grid; gap: var(--ui-space-4); }
  fieldset { border: none; margin: 0; padding: 0; min-width: 0; }
  legend { padding: 0; margin-bottom: var(--ui-space-2); font-size: var(--ui-font-size-sm); color: var(--ui-color-text-secondary); }
  .families { display: grid; grid-template-columns: repeat(auto-fill, minmax(7rem, 1fr)); gap: var(--ui-space-2); }
  .family {
    position: relative;
    display: grid;
    gap: var(--ui-space-2);
    padding: var(--ui-space-2);
    font-size: var(--ui-font-size-sm);
    border: 1px solid var(--ui-color-border-subtle);
    border-radius: var(--ui-radius-control);
    cursor: pointer;
  }
  .family input { position: absolute; inset: 0; margin: 0; opacity: 0; cursor: pointer; }
  .family.checked { border-color: var(--ui-color-accent-solid); box-shadow: inset 0 0 0 1px var(--ui-color-accent-solid); }
  .family:has(input:focus-visible) { outline: 2px solid transparent; outline-offset: 2px; box-shadow: var(--ui-focus-ring); }
  @media (forced-colors: active) {
    .family.checked { outline: 2px solid Highlight; outline-offset: -2px; }
    .family:has(input:focus-visible) { outline: 2px solid CanvasText; outline-offset: 2px; }
  }
  .swatch { display: grid; grid-template-columns: 1fr 1fr; height: 2rem; border-radius: calc(var(--ui-radius-control) - 2px); overflow: hidden; border: 1px solid var(--ui-color-border-subtle); }
  .swatch > span { display: grid; place-items: center; }
  .swatch i { width: 0.75rem; height: 0.75rem; border-radius: 50%; }
</style>
