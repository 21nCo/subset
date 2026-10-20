<!--
  Creates a timer from a preset, a duration, as a stopwatch, or from a custom interval sequence. Each
  form is validated with the operations' own schema before `create` runs.
-->
<script lang="ts">
  import { untrack } from 'svelte';
  import type { Preset } from '../model.js';
  import { BUILT_IN_PRESETS } from '../presets.js';
  import IntervalEditor from './IntervalEditor.svelte';
  import {
    createInputFrom, emptyCountdownDraft, emptyIntervalDraft, presetSummary,
    type CreateMode, type DraftErrors, type TimerBoardDensity
  } from './view-model.js';

  interface Props {
    density: TimerBoardDensity;
    busy: boolean;
    /** Built-in and saved presets, or null when the host could not list them and the built-ins stay. */
    loadPresets: () => Promise<Preset[] | null>;
    /** Runs `create`; resolves to whether it succeeded. */
    oncreate: (input: Record<string, unknown>) => Promise<boolean>;
  }

  let { density, busy, loadPresets, oncreate }: Props = $props();
  const uid = $props.id();

  const MODES: { id: CreateMode; label: string }[] = [
    { id: 'preset', label: 'Preset' },
    { id: 'countdown', label: 'Duration' },
    { id: 'stopwatch', label: 'Stopwatch' },
    { id: 'interval', label: 'Intervals' }
  ];

  // Compact boards, such as an inline chat card, start with the form closed.
  let open = $state(untrack(() => density === 'full'));
  let mode = $state<CreateMode>('preset');
  let name = $state('');
  // The built-ins show at once; the host's list, with any saved presets, replaces them once it loads.
  let presets = $state<Preset[]>([...BUILT_IN_PRESETS]);
  let presetId = $state(BUILT_IN_PRESETS[0].id);
  let presetsRequested = false;
  let countdown = $state(emptyCountdownDraft());
  let interval = $state(emptyIntervalDraft());
  let errors = $state<DraftErrors>({});
  let submitted = $state(false);

  $effect(() => {
    if (!open || presetsRequested) return;
    presetsRequested = true;
    void loadPresets().then((loaded) => {
      if (!loaded?.length) return;
      presets = loaded;
      if (!loaded.some((preset) => preset.id === presetId)) presetId = loaded[0]?.id ?? '';
    });
  });

  // Errors appear after the first submit and then follow the typing.
  $effect(() => {
    if (submitted) errors = validate().errors;
  });

  function validate(): { input: Record<string, unknown> | null; errors: DraftErrors } {
    const outcome = createInputFrom({ mode, name, presetId, countdown, interval });
    return outcome.ok ? { input: outcome.spec, errors: {} } : { input: null, errors: outcome.errors };
  }

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    submitted = true;
    const checked = validate();
    errors = checked.errors;
    if (!checked.input || busy) return;
    if (await oncreate(checked.input)) {
      submitted = false;
      errors = {};
      name = '';
    }
  }

</script>

<section class="create" aria-labelledby="{uid}-title">
  <h3 id="{uid}-title">
    <button type="button" class="toggle" aria-expanded={open} aria-controls={open ? `${uid}-form` : undefined} onclick={() => (open = !open)}>New timer</button>
  </h3>
  {#if open}
    <form id="{uid}-form" onsubmit={submit} novalidate>
      <fieldset class="modes">
        <legend>Create from</legend>
        {#each MODES as option (option.id)}
          <label class="mode"><input type="radio" name="{uid}-mode" value={option.id} bind:group={mode} />{option.label}</label>
        {/each}
      </fieldset>

      <label class="field">
        Name (optional)
        <input type="text" bind:value={name} aria-invalid={Boolean(errors.name)} aria-describedby={errors.name ? `${uid}-name-error` : undefined} />
        {#if errors.name}<span class="error" id="{uid}-name-error">{errors.name}</span>{/if}
      </label>

      {#if mode === 'preset'}
        <label class="field">
          Preset
          <select bind:value={presetId} aria-invalid={Boolean(errors.preset)} aria-describedby={errors.preset ? `${uid}-preset-error` : undefined}>
            {#each presets as preset (preset.id)}
              <option value={preset.id}>{preset.name} · {presetSummary(preset.timer)}</option>
            {/each}
          </select>
          {#if errors.preset}<span class="error" id="{uid}-preset-error">{errors.preset}</span>{/if}
        </label>
      {:else if mode === 'countdown'}
        <div class="row">
          <label class="field">
            Duration
            <input
              type="text"
              placeholder="5:00"
              bind:value={countdown.duration}
              aria-invalid={Boolean(errors.duration)}
              aria-describedby={errors.duration ? `${uid}-duration-error` : undefined}
            />
            {#if errors.duration}<span class="error" id="{uid}-duration-error">{errors.duration}</span>{/if}
          </label>
          <label class="check"><input type="checkbox" bind:checked={countdown.lapsEnabled} />Laps</label>
          <label class="check"><input type="checkbox" bind:checked={countdown.sound} />Sound</label>
        </div>
      {:else if mode === 'interval'}
        <IntervalEditor bind:draft={interval} {errors} />
      {/if}

      <button type="submit" class="submit" disabled={busy}>Add timer</button>
    </form>
  {/if}
</section>

<style>
  .create {
    border-top: 1px solid var(--timer-border);
    padding-top: 8px;
  }
  h3 {
    margin: 0;
    font-size: 1em;
  }
  form {
    display: grid;
    gap: 10px;
    margin-top: 8px;
  }
  fieldset {
    border: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
  }
  legend {
    color: var(--timer-muted);
    margin-bottom: 4px;
  }
  .mode,
  .check {
    display: flex;
    align-items: center;
    gap: 4px;
  }
  .field {
    display: grid;
    gap: 2px;
    color: var(--timer-muted);
  }
  .row {
    display: flex;
    gap: 12px;
    align-items: flex-end;
  }
  input[type='text'],
  select,
  button {
    font: inherit;
    color: var(--timer-text);
    background: var(--timer-bg);
    border: 1px solid var(--timer-border);
    border-radius: 6px;
    padding: 4px 8px;
  }
  input[aria-invalid='true'],
  select[aria-invalid='true'] {
    border-color: var(--timer-danger);
  }
  input:focus-visible,
  select:focus-visible,
  button:focus-visible {
    outline: 2px solid var(--timer-accent);
    outline-offset: 1px;
  }
  .toggle {
    font-weight: 600;
  }
  .submit {
    justify-self: start;
    background: var(--timer-accent);
    border-color: var(--timer-accent);
    color: var(--timer-bg);
    font-weight: 600;
  }
  .submit:disabled {
    opacity: 0.5;
  }
  .error {
    color: var(--timer-danger);
  }
</style>
