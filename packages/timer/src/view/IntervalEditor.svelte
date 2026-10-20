<!--
  Edits a custom interval sequence: rounds, an optional prep and cooldown, and up to 100 segments.
  The draft holds the typed text; `intervalSpecFrom` validates it with the operations' own schema.
-->
<script lang="ts">
  import { PHASES, TIMER_LIMITS } from '../model.js';
  import { emptySegment, type DraftErrors, type IntervalDraft } from './view-model.js';

  interface Props {
    draft: IntervalDraft;
    /** Shown only after a submit attempt. */
    errors: DraftErrors;
  }

  let { draft = $bindable(), errors }: Props = $props();
  const uid = $props.id();

  const describedBy = (field: string) => (errors[field] ? `${uid}-${field}-error` : undefined);

  function addSegment() {
    if (draft.segments.length >= TIMER_LIMITS.segments) return;
    const last = draft.segments.at(-1);
    draft.segments.push(emptySegment(last?.phase === 'work' ? 'rest' : 'work'));
  }

  function removeSegment(index: number) {
    draft.segments.splice(index, 1);
  }

  function moveSegment(index: number, offset: -1 | 1) {
    const target = index + offset;
    if (target < 0 || target >= draft.segments.length) return;
    const [segment] = draft.segments.splice(index, 1);
    draft.segments.splice(target, 0, segment);
  }
</script>

{#snippet fieldError(field: string)}
  {#if errors[field]}<span class="error" id="{uid}-{field}-error">{errors[field]}</span>{/if}
{/snippet}

<div class="editor">
  <div class="row">
    <label>
      Rounds
      <input
        type="text"
        inputmode="numeric"
        bind:value={draft.rounds}
        aria-invalid={Boolean(errors.rounds)}
        aria-describedby={describedBy('rounds')}
      />
      {@render fieldError('rounds')}
    </label>
    <label>
      Prep (optional)
      <input type="text" placeholder="0:10" bind:value={draft.prep} aria-invalid={Boolean(errors.prep)} aria-describedby={describedBy('prep')} />
      {@render fieldError('prep')}
    </label>
    <label>
      Cooldown (optional)
      <input
        type="text"
        placeholder="1:00"
        bind:value={draft.cooldown}
        aria-invalid={Boolean(errors.cooldown)}
        aria-describedby={describedBy('cooldown')}
      />
      {@render fieldError('cooldown')}
    </label>
    <label class="check"><input type="checkbox" bind:checked={draft.sound} />Sound</label>
    <label class="check"><input type="checkbox" bind:checked={draft.countdownTicks} />Final 3-second ticks</label>
  </div>

  <fieldset>
    <legend>Segments, repeated each round</legend>
    {@render fieldError('segments')}
    <ol class="segments">
      {#each draft.segments as segment, index (segment)}
        <li class="segment">
          <label>
            Label
            <input
              type="text"
              bind:value={segment.label}
              aria-invalid={Boolean(errors[`segments.${index}.label`])}
              aria-describedby={describedBy(`segments.${index}.label`)}
            />
            {@render fieldError(`segments.${index}.label`)}
          </label>
          <label>
            Phase
            <select bind:value={segment.phase} aria-invalid={Boolean(errors[`segments.${index}.phase`])} aria-describedby={describedBy(`segments.${index}.phase`)}>
              {#each PHASES as phase (phase)}<option value={phase}>{phase}</option>{/each}
            </select>
            {@render fieldError(`segments.${index}.phase`)}
          </label>
          <label>
            Duration
            <input
              type="text"
              placeholder="0:20"
              bind:value={segment.duration}
              aria-invalid={Boolean(errors[`segments.${index}.duration`])}
              aria-describedby={describedBy(`segments.${index}.duration`)}
            />
            {@render fieldError(`segments.${index}.duration`)}
          </label>
          <div class="segment-actions">
            <button type="button" disabled={index === 0} onclick={() => moveSegment(index, -1)} aria-label="Move segment {index + 1} up">↑</button>
            <button type="button" disabled={index === draft.segments.length - 1} onclick={() => moveSegment(index, 1)} aria-label="Move segment {index + 1} down">↓</button>
            <button type="button" disabled={draft.segments.length === 1} onclick={() => removeSegment(index)} aria-label="Remove segment {index + 1}">×</button>
          </div>
        </li>
      {/each}
    </ol>
    <button type="button" disabled={draft.segments.length >= TIMER_LIMITS.segments} onclick={addSegment}>Add segment</button>
  </fieldset>
</div>

<style>
  .editor,
  fieldset {
    display: grid;
    gap: 8px;
  }
  fieldset {
    border: 1px solid var(--timer-border);
    border-radius: 8px;
    padding: 8px;
    margin: 0;
  }
  .row,
  .segment {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: flex-end;
  }
  .segments {
    margin: 0;
    padding-left: 1.4em;
    display: grid;
    gap: 6px;
  }
  .check {
    display: flex;
    align-items: center;
    gap: 4px;
  }
  label:not(.check) {
    display: grid;
    gap: 2px;
    color: var(--timer-muted);
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
  input[type='text'] {
    width: 7em;
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
  button:disabled {
    opacity: 0.5;
  }
  .segment-actions {
    display: flex;
    gap: 4px;
  }
  .error {
    color: var(--timer-danger);
  }
</style>
