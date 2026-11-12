<!-- Every primitive in one place, in the scheme and mode chosen at the top (and every family side by side below). -->
<script lang="ts">
  import ArrowCounterClockwiseIcon from 'phosphor-svelte/lib/ArrowCounterClockwiseIcon';
  import DotsThreeIcon from 'phosphor-svelte/lib/DotsThreeIcon';
  import PauseIcon from 'phosphor-svelte/lib/PauseIcon';
  import PlayIcon from 'phosphor-svelte/lib/PlayIcon';
  import PlusIcon from 'phosphor-svelte/lib/PlusIcon';
  import SkipForwardIcon from 'phosphor-svelte/lib/SkipForwardIcon';
  import TrashIcon from 'phosphor-svelte/lib/TrashIcon';
  import { appearanceAttributes, parseAppearance, serializeAppearance, SCHEME_FAMILIES, type Appearance } from '../src/index.js';
  import AppearancePicker from '../src/components/AppearancePicker.svelte';
  import Button from '../src/components/Button.svelte';
  import Card from '../src/components/Card.svelte';
  import Dialog from '../src/components/Dialog.svelte';
  import IconButton from '../src/components/IconButton.svelte';
  import Menu from '../src/components/Menu.svelte';
  import MenuItem from '../src/components/MenuItem.svelte';
  import Pill from '../src/components/Pill.svelte';
  import SegmentedControl from '../src/components/SegmentedControl.svelte';

  const KEY = 'subset-ui-gallery-appearance';
  let stored: string | null = null;
  try {
    stored = localStorage.getItem(KEY);
  } catch {
    stored = null;
  }
  let appearance = $state<Appearance>(parseAppearance(stored));
  let dialogOpen = $state(false);
  let density = $state<'comfortable' | 'compact'>('comfortable');

  function save(next: Appearance) {
    try {
      localStorage.setItem(KEY, serializeAppearance(next));
    } catch {
      // A private window or blocked storage keeps the choice for this visit only.
    }
  }
</script>

{#snippet sample()}
  <div class="row">
    <Button variant="primary" icon={PlusIcon}>New timer</Button>
    <Button>Secondary</Button>
    <Button variant="ghost">Ghost</Button>
    <Button variant="danger" icon={TrashIcon}>Remove</Button>
    <Button size="sm">Small</Button>
    <Button disabled>Disabled</Button>
  </div>
  <div class="row">
    <IconButton icon={PlayIcon} label="Start" variant="primary" weight="fill" size="lg" />
    <IconButton icon={PauseIcon} label="Pause" weight="fill" />
    <IconButton icon={SkipForwardIcon} label="Skip" weight="fill" />
    <IconButton icon={DotsThreeIcon} label="More" variant="ghost" size="sm" />
    <Pill>Paused</Pill>
    <Pill tone="accent">Work</Pill>
    <Pill tone="success">Rest</Pill>
    <Pill tone="danger">Overdue</Pill>
  </div>
{/snippet}

<div class="ui-root page" {...appearanceAttributes(appearance)}>
  <header class="bar">
    <strong>Subset UI</strong>
    <span class="muted">Twenty One Native · semi-rounded · Phosphor</span>
  </header>

  <main>
    <Card as="section" padding="lg">
      <h2>Appearance</h2>
      <AppearancePicker bind:appearance onchange={save} />
    </Card>

    <Card as="section" padding="lg">
      <h2>Controls</h2>
      {@render sample()}
      <div class="row">
        <SegmentedControl label="Density" options={[{ value: 'comfortable', label: 'Comfortable' }, { value: 'compact', label: 'Compact' }]} bind:value={density} />
        <Menu icon={DotsThreeIcon} label="More actions">
          <MenuItem icon={ArrowCounterClockwiseIcon}>Reset</MenuItem>
          <MenuItem icon={TrashIcon} tone="danger">Remove</MenuItem>
        </Menu>
        <Button onclick={() => (dialogOpen = true)}>Open dialog</Button>
      </div>
      <p class="muted">Text primary, <span class="secondary">secondary</span>, <span class="muted">muted</span>. <span class="tabular">0:27 · 13:27</span></p>
    </Card>

    <section class="families">
      {#each SCHEME_FAMILIES as family (family.id)}
        {#each ['light', 'dark'] as const as mode (mode)}
          <div class="ui-root swatch-card" data-ui-scheme={family.id} data-ui-mode={mode}>
            <div class="swatch-head"><strong>{family.label}</strong><span class="muted">{mode}</span></div>
            {@render sample()}
            <div class="frame">Frame / app chrome</div>
          </div>
        {/each}
      {/each}
    </section>
  </main>

  <Dialog title="New timer" bind:open={dialogOpen}>
    <p>Dialogs use the native element, so focus, Escape and the backdrop behave as the browser defines.</p>
    {#snippet footer()}
      <Button variant="ghost" onclick={() => (dialogOpen = false)}>Cancel</Button>
      <Button variant="primary" onclick={() => (dialogOpen = false)}>Add timer</Button>
    {/snippet}
  </Dialog>
</div>

<style>
  .page { min-height: 100dvh; }
  .bar { display: flex; align-items: baseline; gap: var(--ui-space-3); padding: var(--ui-space-4) var(--ui-space-6); background: var(--ui-color-frame-surface); color: var(--ui-color-frame-text); }
  main { display: grid; gap: var(--ui-space-4); padding: var(--ui-space-6); max-width: 75rem; margin: 0 auto; }
  h2 { margin: 0 0 var(--ui-space-4); font-size: var(--ui-font-size-lg); }
  .row { display: flex; flex-wrap: wrap; align-items: center; gap: var(--ui-space-2); margin-bottom: var(--ui-space-3); }
  .muted { color: var(--ui-color-text-muted); }
  .secondary { color: var(--ui-color-text-secondary); }
  .tabular { font-variant-numeric: tabular-nums; font-weight: var(--ui-font-weight-light); font-size: 1.5rem; color: var(--ui-color-text-primary); }
  .families { display: grid; grid-template-columns: repeat(auto-fill, minmax(26rem, 1fr)); gap: var(--ui-space-4); }
  .swatch-card { padding: var(--ui-space-4); border-radius: var(--ui-radius-panel); border: 1px solid var(--ui-color-border-subtle); }
  .swatch-head { display: flex; justify-content: space-between; margin-bottom: var(--ui-space-3); }
  .frame { margin-top: var(--ui-space-2); padding: var(--ui-space-2) var(--ui-space-3); border-radius: var(--ui-radius-control); background: var(--ui-color-frame-surface); color: var(--ui-color-frame-text); font-size: var(--ui-font-size-sm); }
</style>
