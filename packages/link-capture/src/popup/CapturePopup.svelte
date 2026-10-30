<!--
  The capture popup: reads the page, lets the user edit the title, notes and tags, and saves to the target.
  The flow is `createCapturePopupController`; this view only renders its state and forwards the user's actions.
-->
<script lang="ts">
  import { onMount, untrack } from 'svelte';
  // The package's own entry, so the host and the popup share one copy of the capture code.
  import { createCapturePopupController, type Capture, type PopupState, type SaveTarget } from '@subset.dev/link-capture';

  interface Props {
    target: SaveTarget;
    /** Reads what to save, for example `() => captureActiveTab(getRuntime().browser)`. */
    capture: () => Promise<Capture>;
    /** Opens the target's setup, for example the options page; shown when the target needs setup. */
    onsetup?: () => void;
  }

  let { target, capture, onsetup }: Props = $props();
  const uid = $props.id();

  // The target and capture function are fixed for the popup's life.
  const controller = untrack(() => createCapturePopupController({ target, capture }));
  let view = $state<PopupState>(controller.state);
  let suggestions = $state<string[]>([]);
  let suggestionRequest = 0;

  onMount(() => {
    const unsubscribe = controller.subscribe((next) => (view = next));
    void controller.start();
    return unsubscribe;
  });

  function submit(event: SubmitEvent) {
    event.preventDefault();
    void controller.save();
  }

  /** Suggestions for the tag being typed, the text after the last comma. A slower, older answer is dropped. */
  async function suggest(tags: string) {
    const request = ++suggestionRequest;
    const prefix = tags.slice(tags.lastIndexOf(',') + 1).trim();
    const found = prefix ? await controller.suggestTags(prefix) : [];
    if (request === suggestionRequest) suggestions = found.slice(0, 8);
  }

  function addTag(tag: string) {
    if (view.name !== 'editing') return;
    const tags = view.draft.tags;
    const kept = tags.slice(0, tags.lastIndexOf(',') + 1);
    controller.edit({ tags: `${kept}${kept ? ' ' : ''}${tag}, ` });
    suggestions = [];
    document.getElementById(`${uid}-tags`)?.focus();
  }
</script>

<main class="capture" aria-busy={view.name === 'capturing' || view.name === 'saving'}>
  <h1>{target.label}</h1>

  {#if view.name === 'idle' || view.name === 'capturing'}
    <p role="status">Reading the page…</p>
  {:else if view.name === 'editing' || view.name === 'saving'}
    {@const draft = view.draft}
    {@const busy = view.name === 'saving'}
    <form onsubmit={submit}>
      <p class="url" title={view.capture.url}>{view.capture.url}</p>
      <label for="{uid}-title">Title</label>
      <input id="{uid}-title" value={draft.title} disabled={busy}
        oninput={(event) => controller.edit({ title: event.currentTarget.value })} />

      <label for="{uid}-notes">Notes</label>
      <textarea id="{uid}-notes" rows="4" value={draft.notes} disabled={busy}
        oninput={(event) => controller.edit({ notes: event.currentTarget.value })}></textarea>

      <label for="{uid}-tags">Tags</label>
      <input id="{uid}-tags" value={draft.tags} disabled={busy} autocomplete="off" aria-describedby="{uid}-tags-hint"
        oninput={(event) => {
          controller.edit({ tags: event.currentTarget.value });
          void suggest(event.currentTarget.value);
        }} />
      <p id="{uid}-tags-hint" class="hint">Separate tags with commas.</p>
      {#if suggestions.length && !busy}
        <ul class="suggestions" aria-label="Suggested tags">
          {#each suggestions as tag (tag)}
            <li><button type="button" onclick={() => addTag(tag)}>{tag}</button></li>
          {/each}
        </ul>
      {/if}

      <button type="submit" disabled={busy}>{busy ? 'Saving…' : 'Save'}</button>
      {#if busy}<p role="status" class="hint">Saving to {target.label}…</p>{/if}
    </form>
  {:else if view.name === 'saved'}
    <p role="status">{view.existing ? `Already in ${target.label}.` : `Saved to ${target.label}.`}</p>
    {#if view.openUrl}
      <a href={view.openUrl} target="_blank" rel="noopener noreferrer">Open in {target.label}</a>
    {/if}
  {:else if view.name === 'error'}
    <p role="alert">{view.error.message}</p>
    <div class="actions">
      {#if view.error.needsSetup && onsetup}
        <button type="button" onclick={() => onsetup()}>Set up {target.label}</button>
      {/if}
      <button type="button" onclick={() => void controller.retry()}>Try again</button>
      {#if view.error.stage === 'save'}
        <button type="button" onclick={() => controller.back()}>Edit</button>
      {/if}
    </div>
  {/if}
</main>

<style>
  .capture {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    width: 22rem;
    padding: 0.75rem;
    font: 14px/1.4 system-ui, sans-serif;
  }
  h1 {
    margin: 0;
    font-size: 1rem;
  }
  form {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }
  p {
    margin: 0;
  }
  .url {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: GrayText;
  }
  .hint {
    font-size: 0.85em;
    color: GrayText;
  }
  input,
  textarea {
    font: inherit;
  }
  label {
    margin-top: 0.25rem;
    font-weight: 600;
  }
  .suggestions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.25rem;
    margin: 0;
    padding: 0;
    list-style: none;
  }
  button[type='submit'] {
    margin-top: 0.5rem;
  }
  .actions {
    display: flex;
    gap: 0.5rem;
  }
</style>
