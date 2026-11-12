<!-- A single choice among a few options, as a radio group styled as segments. -->
<script lang="ts" generics="T extends string">
  interface Option {
    value: T;
    label: string;
  }

  interface Props {
    /** The group's accessible name; shown above the segments unless `hideLabel`. */
    label: string;
    options: Option[];
    value: T;
    hideLabel?: boolean;
    onchange?: (value: T) => void;
  }

  let { label, options, value = $bindable(), hideLabel = false, onchange }: Props = $props();
  const name = $props.id();
</script>

<fieldset class="ui-segmented">
  <legend class:sr-only={hideLabel}>{label}</legend>
  <div class="segments">
    {#each options as option (option.value)}
      <label class="segment" class:checked={value === option.value}>
        <input
          type="radio"
          {name}
          value={option.value}
          checked={value === option.value}
          onchange={() => {
            value = option.value;
            onchange?.(option.value);
          }}
        />
        {option.label}
      </label>
    {/each}
  </div>
</fieldset>

<style>
  .ui-segmented { border: none; margin: 0; padding: 0; min-width: 0; }
  legend { padding: 0; margin-bottom: var(--ui-space-2); font-size: var(--ui-font-size-sm); color: var(--ui-color-text-secondary); }
  .segments {
    display: flex;
    gap: 2px;
    padding: 3px;
    background: var(--ui-color-surface-sunken);
    border-radius: calc(var(--ui-radius-control) + 3px);
  }
  .segment {
    position: relative;
    flex: 1;
    display: grid;
    place-items: center;
    min-height: 1.875rem;
    padding: 0 var(--ui-space-3);
    font-size: var(--ui-font-size-sm);
    color: var(--ui-color-text-secondary);
    border-radius: var(--ui-radius-control);
    cursor: pointer;
    white-space: nowrap;
  }
  .segment input { position: absolute; inset: 0; margin: 0; opacity: 0; cursor: pointer; }
  .segment.checked { color: var(--ui-color-text-primary); font-weight: var(--ui-font-weight-medium); background: var(--ui-color-surface-raised); box-shadow: var(--ui-shadow-raised); }
  .segment:has(input:focus-visible) { outline: 2px solid transparent; outline-offset: 2px; box-shadow: var(--ui-focus-ring); }
  /* Forced colours drop backgrounds and shadows; outline the chosen segment in the system highlight. */
  @media (forced-colors: active) {
    .segment.checked { outline: 2px solid Highlight; outline-offset: -2px; }
    .segment:has(input:focus-visible) { outline: 2px solid CanvasText; outline-offset: 2px; }
  }
  .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
</style>
