import type { Capture } from './capture.js';
import type { SaveEdits, SaveResult, SaveTargetStatus } from './target.js';

/** The editable fields, as typed. `tags` is a comma-separated list. */
export interface Draft {
  title: string;
  notes: string;
  tags: string;
}

export interface PopupError {
  /** `capture`: reading the page failed. `target`: the target is not connected. `save`: the target refused or failed. */
  stage: 'capture' | 'target' | 'save';
  message: string;
  /** The target reported `needs-setup`. */
  needsSetup?: boolean;
}

export type PopupState =
  | { name: 'idle' }
  | { name: 'capturing' }
  | { name: 'editing'; capture: Capture; draft: Draft }
  | { name: 'saving'; capture: Capture; draft: Draft }
  | { name: 'saved'; capture: Capture; draft: Draft; existing: boolean; openUrl?: string }
  /** A failed save keeps the capture and draft, so the user can retry or go back to the form. */
  | { name: 'error'; error: PopupError; capture?: Capture; draft?: Draft };

export type PopupEvent =
  | { type: 'start' }
  | { type: 'captured'; capture: Capture }
  | { type: 'captureFailed'; message: string }
  | { type: 'targetUnavailable'; status: Exclude<SaveTargetStatus, { state: 'connected' }> }
  | { type: 'edit'; draft: Partial<Draft> }
  | { type: 'save' }
  | { type: 'saved'; result: Extract<SaveResult, { ok: true }> }
  | { type: 'saveFailed'; message: string }
  /** From an error: save again after a save error, capture again after any other. */
  | { type: 'retry' }
  /** From a save error: back to the form. */
  | { type: 'back' };

export const initialPopupState: PopupState = { name: 'idle' };

const NEEDS_SETUP_MESSAGE = 'Connect this extension before saving.';

/**
 * The popup flow `idle → capturing → editing → saving → saved | error`. Pure: an event that does not apply to the
 * current state, such as a second `save` while saving or a late `captured`, returns the same state object.
 */
export function popupTransition(state: PopupState, event: PopupEvent): PopupState {
  switch (state.name) {
    case 'idle':
      return event.type === 'start' ? { name: 'capturing' } : state;
    case 'capturing':
      if (event.type === 'captured') return { name: 'editing', capture: event.capture, draft: draftFrom(event.capture) };
      if (event.type === 'captureFailed') return { name: 'error', error: { stage: 'capture', message: event.message } };
      if (event.type === 'targetUnavailable') return { name: 'error', error: targetError(event.status) };
      return state;
    case 'editing':
      if (event.type === 'edit') return { ...state, draft: { ...state.draft, ...pickDraft(event.draft) } };
      if (event.type === 'save') return { name: 'saving', capture: state.capture, draft: state.draft };
      return state;
    case 'saving':
      if (event.type === 'saved') {
        const openUrl = httpUrl(event.result.openUrl);
        return {
          name: 'saved',
          capture: state.capture,
          draft: state.draft,
          existing: event.result.existing === true,
          ...(openUrl ? { openUrl } : {})
        };
      }
      if (event.type === 'saveFailed') {
        return { name: 'error', error: { stage: 'save', message: event.message }, capture: state.capture, draft: state.draft };
      }
      return state;
    case 'saved':
      return state;
    case 'error':
      if (state.error.stage === 'save' && state.capture && state.draft) {
        if (event.type === 'retry') return { name: 'saving', capture: state.capture, draft: state.draft };
        if (event.type === 'back') return { name: 'editing', capture: state.capture, draft: state.draft };
        return state;
      }
      return event.type === 'retry' ? { name: 'capturing' } : state;
  }
}

/** The edits a draft sends to `SaveTarget.save`: trimmed, empty fields omitted, tags split on commas and deduplicated. */
export function draftEdits(draft: Draft): SaveEdits {
  const title = draft.title.replace(/\s+/g, ' ').trim();
  const notes = draft.notes.trim();
  const tags = parseTags(draft.tags);
  return { ...(title ? { title } : {}), ...(notes ? { notes } : {}), ...(tags.length ? { tags } : {}) };
}

/** Comma-separated tags, trimmed with inner whitespace collapsed; empty ones dropped and repeats (ignoring case) kept once. */
export function parseTags(value: string): string[] {
  const tags: string[] = [];
  const seen = new Set<string>();
  for (const part of value.split(',')) {
    const tag = part.replace(/\s+/g, ' ').trim();
    const key = tag.toLowerCase();
    if (!tag || seen.has(key)) continue;
    seen.add(key);
    tags.push(tag);
  }
  return tags;
}

/** The selected text starts the notes, so a quote is kept unless the user removes it. */
function draftFrom(capture: Capture): Draft {
  return { title: capture.title, notes: capture.selectionText ?? '', tags: '' };
}

function pickDraft(patch: Partial<Draft>): Partial<Draft> {
  const picked: Partial<Draft> = {};
  for (const key of ['title', 'notes', 'tags'] as const) if (typeof patch[key] === 'string') picked[key] = patch[key];
  return picked;
}

function targetError(status: Exclude<SaveTargetStatus, { state: 'connected' }>): PopupError {
  if (status.state === 'needs-setup') return { stage: 'target', message: status.message || NEEDS_SETUP_MESSAGE, needsSetup: true };
  return { stage: 'target', message: status.message };
}

/** A target's `openUrl` becomes a link in the popup, so only http and https are kept. */
function httpUrl(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  try {
    const url = new URL(value);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : undefined;
  } catch {
    return undefined;
  }
}
